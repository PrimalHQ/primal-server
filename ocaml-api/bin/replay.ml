(* primalctl replay: parity measurement over a request corpus (ocaml-plan.md §12, the gate of
   cutover A). Every line of the corpus is a request-log record {t, funcall, kwargs, ws, subid}
   (the ws-connector --log-request / primal-api request_log format). Each selected request is sent
   to server A (the production ws-connector) and server B (the shadow) and the two answers are
   compared as multisets of canonical messages: JSON with sorted keys, strings that are themselves
   JSON canonicalised too (the content of synthetic kinds), integral floats as integers — the same
   rule as the scratch wscompare.py harness, so numbers are comparable.

   Only read-only funcalls are replayed; by default only the natively answered ones (the gate),
   --all adds the proxied ones. Writers (set_*, update_*, import_*, reset_*, broadcast_events, ...)
   are never replayed. *)

open Eio.Std

type opts = {
  corpus : string;
  url_a : string;
  url_b : string;
  only : string list; (* funcall names; [] = all selected *)
  all : bool;
  per_funcall : int;
  workers : int;
  timeout : float;
  report : string option;
}

let default_opts =
  {
    corpus = ""; url_a = "ws://127.0.0.1:9001"; url_b = "ws://127.0.0.1:9006"; only = []; all = false;
    per_funcall = 200; workers = 4; timeout = 30.0; report = None;
  }

(* funcalls with side effects, never replayed *)
let is_writer (f : string) : bool =
  let starts p = String.length f >= String.length p && String.sub f 0 (String.length p) = p in
  starts "set_" || starts "update_" || starts "import_" || starts "reset_" || starts "upload"
  || List.mem f
       [
         "broadcast_events"; "membership_media_management_delete"; "membership_recover_contact_list";
         "membership_content_rebroadcast_start"; "membership_content_rebroadcast_cancel";
         "membership_content_backup"; "report_user"; "report_note"; "mark_as_read";
       ]

(* {1 Canonical form} *)

let rec canon (j : Yojson.Safe.t) : Yojson.Safe.t =
  match j with
  | `Assoc f -> `Assoc (List.sort (fun (a, _) (b, _) -> compare a b) (List.map (fun (k, v) -> (k, canon v)) f))
  | `List l -> `List (List.map canon l)
  | `Float x when Float.is_integer x && Float.abs x < 4.6e18 -> `Int (int_of_float x)
  | `String s -> (
      let t = String.trim s in
      if String.length t > 0 && (t.[0] = '{' || t.[0] = '[') then
        match Yojson.Safe.from_string t with v -> canon v | exception _ -> j
      else j)
  | v -> v

let canon_text (s : string) : string =
  match Yojson.Safe.from_string s with v -> Yojson.Safe.to_string (canon v) | exception _ -> s

(* {1 One side} *)

type side = {
  name : string;
  tls : bool;
  host : string;
  port : int;
  path : string;
  mutable ws : Ws_client.t option;
}

let side_of_url name url =
  match Relay_broadcast.parse_relay_url url with
  | Some (tls, host, port, path) -> { name; tls; host; port; path; ws = None }
  | None -> failwith ("not a ws url: " ^ url)

type answer = { msgs : string list; notices : string list; ms : float; status : [ `Ok | `Timeout | `Closed ] }

let ensure ~sw ~net ~clock (s : side) : Ws_client.t =
  match s.ws with
  | Some ws -> ws
  | None ->
      let ws = Ws_client.connect ~tls:s.tls ~sw ~net ~clock ~host:s.host ~port:s.port ~path:s.path () in
      s.ws <- Some ws;
      ws

let drop (s : side) =
  (match s.ws with Some ws -> ( try Ws_client.close ws with _ -> ()) | None -> ());
  s.ws <- None

let ask ~sw ~net ~clock ~timeout (s : side) ~(subid : string) ~(funcall : string) ~(kwargs : Yojson.Safe.t) : answer =
  let t0 = Unix.gettimeofday () in
  let msgs = ref [] and notices = ref [] in
  let run () =
    let ws = ensure ~sw ~net ~clock s in
    Ws_client.send_text ws (Yojson.Safe.to_string (`List [ `String "REQ"; `String subid; `Assoc [ ("cache", `List [ `String funcall; kwargs ]) ] ]));
    let rec loop () =
      match Ws_client.recv_frame ws with
      | `Closed -> `Closed
      | `Binary _ -> loop ()
      | `Text t -> (
          match Yojson.Safe.from_string t with
          | `List [ `String "EVENT"; `String sid; m ] when sid = subid ->
              msgs := Yojson.Safe.to_string (canon m) :: !msgs;
              loop ()
          | `List [ `String "NOTICE"; `String sid; `String n ] when sid = subid ->
              notices := n :: !notices;
              loop ()
          | `List [ `String "EOSE"; `String sid ] when sid = subid ->
              (* like a client: release the subscription (Julia caps open subscriptions per connection) *)
              Ws_client.send_text ws (Yojson.Safe.to_string (`List [ `String "CLOSE"; `String subid ]));
              `Ok
          | _ -> loop ()
          | exception _ -> loop ())
    in
    loop ()
  in
  let status =
    match Eio.Time.with_timeout clock timeout (fun () -> Ok (run ())) with
    | Ok s -> s
    | Error `Timeout -> `Timeout
    | exception (Eio.Cancel.Cancelled _ as e) -> raise e
    | exception _ -> `Closed
  in
  if status <> `Ok then drop s;
  { msgs = List.sort compare !msgs; notices = List.sort compare !notices; ms = (Unix.gettimeofday () -. t0) *. 1000.; status }

(* {1 Corpus} *)

type req = { funcall : string; kwargs : Yojson.Safe.t }

let load (o : opts) ~(native : string list) : req list =
  let counts = Hashtbl.create 64 in
  let selected f =
    (not (is_writer f))
    && (match o.only with [] -> o.all || List.mem f native | l -> List.mem f l)
    && Hashtbl.find_opt counts f |> Option.value ~default:0 < o.per_funcall
  in
  let acc = ref [] in
  In_channel.with_open_text o.corpus (fun ic ->
      let rec go () =
        match In_channel.input_line ic with
        | None -> ()
        | Some line ->
            (match Yojson.Safe.from_string line with
            | `Assoc f -> (
                match (List.assoc_opt "funcall" f, List.assoc_opt "kwargs" f) with
                | Some (`String funcall), Some (`Assoc _ as kwargs) when selected funcall ->
                    Hashtbl.replace counts funcall (1 + Option.value (Hashtbl.find_opt counts funcall) ~default:0);
                    acc := { funcall; kwargs } :: !acc
                | _ -> ())
            | _ -> ()
            | exception _ -> ());
            go ()
      in
      go ());
  List.rev !acc

(* {1 Results} *)

type stat = {
  mutable total : int;
  mutable identical : int;
  mutable timeouts_a : int;
  mutable timeouts_b : int;
  mutable ms_a : float list;
  mutable ms_b : float list;
}

let median l =
  match List.sort compare l with
  | [] -> 0.
  | s ->
      let n = List.length s in
      List.nth s (n / 2)

let run (o : opts) ~(native : string list) : unit =
  let reqs = load o ~native in
  Printf.printf "replaying %d requests (%s vs %s, %d workers, timeout %.0fs)\n%!" (List.length reqs) o.url_a o.url_b o.workers o.timeout;
  let stats : (string, stat) Hashtbl.t = Hashtbl.create 64 in
  let stat f =
    match Hashtbl.find_opt stats f with
    | Some s -> s
    | None ->
        let s = { total = 0; identical = 0; timeouts_a = 0; timeouts_b = 0; ms_a = []; ms_b = [] } in
        Hashtbl.replace stats f s;
        s
  in
  let report = Option.map (fun p -> open_out p) o.report in
  let queue = Eio.Stream.create max_int in
  List.iteri (fun i r -> Eio.Stream.add queue (Some (i, r))) reqs;
  for _ = 1 to o.workers do Eio.Stream.add queue None done;
  let done_n = ref 0 in
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  Switch.run @@ fun sw ->
  let worker w =
    let a = side_of_url "A" o.url_a and b = side_of_url "B" o.url_b in
    let rec loop () =
      match Eio.Stream.take queue with
      | None -> drop a; drop b
      | Some (i, r) ->
          let subid = Printf.sprintf "replay-%d-%d" w i in
          let ra = ask ~sw ~net ~clock ~timeout:o.timeout a ~subid ~funcall:r.funcall ~kwargs:r.kwargs in
          let rb = ask ~sw ~net ~clock ~timeout:o.timeout b ~subid ~funcall:r.funcall ~kwargs:r.kwargs in
          let s = stat r.funcall in
          s.total <- s.total + 1;
          if ra.status = `Timeout then s.timeouts_a <- s.timeouts_a + 1;
          if rb.status = `Timeout then s.timeouts_b <- s.timeouts_b + 1;
          s.ms_a <- ra.ms :: s.ms_a;
          s.ms_b <- rb.ms :: s.ms_b;
          (* both timing out is the same behaviour (counted in the tmo columns) *)
          let same =
            (ra.status = `Timeout && rb.status = `Timeout)
            || (ra.status = `Ok && rb.status = `Ok && ra.msgs = rb.msgs && ra.notices = rb.notices)
          in
          if same then s.identical <- s.identical + 1
          else
            Option.iter
              (fun oc ->
                let only l1 l2 = List.filter (fun m -> not (List.mem m l2)) l1 in
                let st = function `Ok -> "ok" | `Timeout -> "timeout" | `Closed -> "closed" in
                output_string oc
                  (Yojson.Safe.to_string
                     (`Assoc
                       [
                         ("funcall", `String r.funcall);
                         ("kwargs", r.kwargs);
                         ("status", `List [ `String (st ra.status); `String (st rb.status) ]);
                         ("counts", `List [ `Int (List.length ra.msgs); `Int (List.length rb.msgs) ]);
                         ("notices", `List [ `List (List.map (fun n -> `String n) ra.notices); `List (List.map (fun n -> `String n) rb.notices) ]);
                         ("only_a", `List (List.filteri (fun i _ -> i < 3) (only ra.msgs rb.msgs) |> List.map (fun m -> `String m)));
                         ("only_b", `List (List.filteri (fun i _ -> i < 3) (only rb.msgs ra.msgs) |> List.map (fun m -> `String m)));
                       ]));
                output_char oc '\n';
                flush oc)
              report;
          incr done_n;
          if !done_n mod 200 = 0 then Printf.printf "  %d/%d\n%!" !done_n (List.length reqs);
          loop ()
    in
    loop ()
  in
  Fiber.all (List.init o.workers (fun w () -> worker w));
  Option.iter close_out report;
  let rows = Hashtbl.fold (fun f s acc -> (f, s) :: acc) stats [] |> List.sort compare in
  Printf.printf "\n%-36s %6s %6s %7s %6s %6s %9s %9s\n" "funcall" "total" "same" "pct" "tmo_a" "tmo_b" "med_ms_a" "med_ms_b";
  let tt = ref 0 and ti = ref 0 in
  List.iter
    (fun (f, s) ->
      tt := !tt + s.total;
      ti := !ti + s.identical;
      Printf.printf "%-36s %6d %6d %6.1f%% %6d %6d %9.0f %9.0f\n" f s.total s.identical
        (100. *. float_of_int s.identical /. float_of_int (max 1 s.total))
        s.timeouts_a s.timeouts_b (median s.ms_a) (median s.ms_b))
    rows;
  Printf.printf "%-36s %6d %6d %6.1f%%\n%!" "TOTAL" !tt !ti (100. *. float_of_int !ti /. float_of_int (max 1 !tt))
