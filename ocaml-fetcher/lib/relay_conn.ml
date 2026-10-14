(* One relay = one fiber running the loop of Julia's fetching.jl nostr_fetch_events: connect
   (timeout_s), send the two REQs ({since} and {since, authors 00..ff}), read until the connection
   ends or goes quiet for timeout_s, then back off (base_delay_s, doubling to max_delay_s, or
   dead_relay_max_delay_s for relays that never delivered; base_delay_s again after a connection
   that produced messages). Every step emits the envelope
   [time, {func, runid, relay_url, timeout, proxy, event, ...}, m] to the processor (the line
   format the Julia fetcher wrote, which the importer and archive readers parse).
   since = min(now, max(since, created_at - 1)) and is persisted at most every 5 s (Resume). *)

open Eio.Std

type t = {
  url : string;
  parsed : (bool * string * int * string) option; (* tls, host, port, path *)
  use_proxy : bool;
  mutable since : int;
  mutable saved_since : int;
  mutable last_save : float;
  mutable delay : float;
  mutable waiting_delay : bool;
  mutable connected : bool;
  mutable message_count : int;
  mutable exception_count : int;
  mutable last_exception : string;
  mutable last_connected_at : float;
  host : string; (* Relay_url.host_key: host[:port] *)
  root : bool; (* the relay's root url (no path) *)
  mutable filtered : bool; (* the REQs carry cfg.req_kinds; cleared on a CLOSED (fallback to unfiltered) *)
  mutable firsts : int; (* events this relay delivered before any other (set by the processor) *)
}

type item = { line : string; ev : Yojson.Safe.t option; (* the EVENT's event object, for the dedup/archive path *) relay : t }

let create ~(cfg : Config.t) ~(since : int) (url : string) : t =
  let host, root = Relay_url.host_key url in
  let filtered = cfg.req_kinds <> None && not (List.mem host cfg.req_kinds_exempt_hosts) in
  { url; parsed = Relay_broadcast.parse_relay_url url; use_proxy = not (List.mem url cfg.no_proxy_relays); since; saved_since = since; last_save = 0.0; delay = cfg.base_delay_s; waiting_delay = false; connected = false;
    message_count = 0; exception_count = 0; last_exception = ""; last_connected_at = 0.0; host; root; filtered; firsts = 0 }

let subid_chars = "abcdefghijklmnopqrstuvwxyz0123456789"
let randsubid () = String.init 30 (fun _ -> subid_chars.[Random.int 36])

let uuid4 () =
  let b = Bytes.init 16 (fun _ -> Char.chr (Random.int 256)) in
  Bytes.set b 6 (Char.chr (0x40 lor (Char.code (Bytes.get b 6) land 0x0f)));
  Bytes.set b 8 (Char.chr (0x80 lor (Char.code (Bytes.get b 8) land 0x3f)));
  let h = Hex_util.encode (Bytes.to_string b) in
  Printf.sprintf "%s-%s-%s-%s-%s" (String.sub h 0 8) (String.sub h 8 4) (String.sub h 12 4) (String.sub h 16 4) (String.sub h 20 12)

let authors = List.init 256 (fun i -> `String (Printf.sprintf "%02x" i))

exception Read_timeout
exception Connect_timeout

(* Julia extract_event_id: the 64 hex chars after the only id key in the message (an EVENT message
   has exactly one; one inside content/tags is escaped). Plus created_at the same way.
   With these, a duplicate (seen within the dedup window) is recognised without parsing the JSON
   — 90 % of the stream once every relay is connected. *)
let find_sub (s : string) (pat : string) (from : int) : int option =
  let n = String.length s and m = String.length pat in
  let c0 = pat.[0] in
  let rec matches i j = j >= m || (String.unsafe_get s (i + j) = String.unsafe_get pat j && matches i (j + 1)) in
  let rec go i = if i + m > n then None else if String.unsafe_get s i = c0 && matches i 1 then Some i else go (i + 1) in
  go from

let is_hex c = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')

let extract_event_id (s : string) : string option =
  match find_sub s "\"id\":\"" 0 with
  | Some i -> (
      match find_sub s "\"id\":\"" (i + 6) with
      | Some _ -> None
      | None ->
          let st = i + 6 in
          if st + 64 <= String.length s && String.length s > st + 64 && s.[st + 64] = '"' then
            let id = String.sub s st 64 in
            if String.for_all is_hex id then Some id else None
          else None)
  | None -> None

let extract_created_at (s : string) : int option =
  match find_sub s "\"created_at\":" 0 with
  | Some i ->
      let st = i + 13 in
      let j = ref st in
      while !j < String.length s && s.[!j] >= '0' && s.[!j] <= '9' do incr j done;
      if !j > st && !j - st < 12 then int_of_string_opt (String.sub s st (!j - st)) else None
  | None -> None

let run ~(cfg : Config.t) ~(stats : Stats.t) ~(dedup : Dedup.t) ~net ~clock ~(stop : unit Promise.t) ~(connect_sem : Eio.Semaphore.t) ~(emit : item -> unit) ~(active : unit -> bool) (t : t) : unit =
  let runid = uuid4 () in
  let base = [ ("func", `String "nostr_fetch_events"); ("runid", `String runid); ("relay_url", `String t.url); ("timeout", `Int (int_of_float cfg.timeout_s)); ("proxy", match (t.use_proxy, cfg.proxy_url) with true, Some p -> `String p | _ -> `Null) ] in
  let produce ?(m = `Null) ?(ev = None) (extra : (string * Yojson.Safe.t) list) =
    let line = Julia_json.envelope ~now:(Unix.gettimeofday ()) (`Assoc (base @ extra)) m in
    emit { line; ev; relay = t }
  in
  let err exn subfunc =
    t.exception_count <- t.exception_count + 1;
    Stats.incr stats.exception_count;
    let s = Printexc.to_string exn in
    t.last_exception <- s;
    produce ~m:(`String s) [ ("event", `String "exception"); ("subfunc", `String subfunc); ("printout", `String "disabled to see performance without print_exceptions") ]
  in
  let save_since ~force =
    let now = Unix.gettimeofday () in
    if t.since <> t.saved_since && (force || now -. t.last_save >= 5.0) then begin
      Resume.save ~state_dir:cfg.state_dir t.url t.since;
      t.saved_since <- t.since;
      t.last_save <- now
    end
  in
  produce [ ("event", `String "started") ];
  t.delay <- cfg.base_delay_s;
  let alive () = active () && not (Promise.is_resolved stop) in
  while alive () do
    let msg_cnt = ref 0 in
    (try
       match t.parsed with
       | None -> failwith ("invalid relay url: " ^ t.url)
       | Some (tls, host, port, path) ->
           Switch.run (fun sw ->
               let proxy = if t.use_proxy then cfg.proxy else None in
               (* relays that have delivered before reconnect without queueing behind the dead ones *)
               let limited = t.message_count = 0 in
               let ws =
                 if limited then Eio.Semaphore.acquire connect_sem;
                 Stats.incr stats.connecting;
                 Fun.protect ~finally:(fun () -> Stats.decr stats.connecting; if limited then Eio.Semaphore.release connect_sem) (fun () ->
                     match Eio.Time.with_timeout clock cfg.timeout_s (fun () -> Ok (Ws_client.connect ~tls ?proxy ~sw ~net ~clock ~host ~port ~path ())) with
                     | Ok ws -> ws
                     | Error `Timeout -> raise Connect_timeout)
               in
               t.connected <- true;
               t.last_connected_at <- Unix.gettimeofday ();
               Stats.incr stats.relays_connected;
               Fun.protect
                 ~finally:(fun () ->
                   t.connected <- false;
                   Stats.decr stats.relays_connected;
                   try Ws_client.close ws with _ -> ())
                 (fun () ->
                   produce ~m:(`Assoc [ ("since", `Int t.since) ]) [ ("event", `String "connected") ];
                   (* the two REQs; with cfg.req_kinds (and the relay not exempt) both carry the kinds filter.
                      [subs] remembers each live subscription (subid -> its params and whether it was filtered)
                      so a CLOSED can be matched to the REQ it refuses. *)
                   let subs = ref [] in
                   let send_req ~filtered (qparams : (string * Yojson.Safe.t) list) =
                     let kinds =
                       if filtered then (match cfg.req_kinds with Some ks -> [ ("kinds", `List (List.map (fun k -> `Int k) ks)) ] | None -> []) else []
                     in
                     let sid = randsubid () in
                     let q = `List [ `String "REQ"; `String sid; `Assoc ((("since", `Int t.since) :: kinds) @ qparams) ] in
                     subs := (sid, (qparams, filtered && kinds <> [])) :: !subs;
                     produce ~m:(`Assoc [ ("query", q) ]) [ ("event", `String "request") ];
                     let msg = Yojson.Safe.to_string q in
                     Stats.add stats.chars_sent (String.length msg);
                     Ws_client.send_text ws msg
                   in
                   List.iter (send_req ~filtered:t.filtered) [ []; [ ("authors", `List authors) ] ];
                   let rec read_loop () =
                     match Ws_client.recv_timeout ws ~timeout:cfg.timeout_s with
                     | `Closed -> ()
                     | `Timeout -> raise Read_timeout
                     | `Msg s ->
                         incr msg_cnt;
                         Stats.add stats.chars_received (String.length s);
                         if t.message_count = 0 then Stats.incr stats.relays_providing;
                         t.message_count <- t.message_count + 1;
                         Stats.incr stats.message_count;
                         if String.length s > 9 && String.sub s 0 9 = "[\"CLOSED\"" then begin
                           Stats.incr stats.closed_msgs;
                           (* a CLOSED for one of our kinds-filtered REQs: re-send that REQ unfiltered, once. Only the plain
                              REQ's refusal can be about the kinds (the authors REQ is refused by relays that dropped prefix
                              matching, filter or not), so only that one marks the relay unfiltered for its next connections. *)
                           (match Yojson.Safe.from_string s with
                           | `List (_ :: `String sid :: _) -> (
                               match List.assoc_opt sid !subs with
                               | Some (qparams, true) ->
                                   subs := List.remove_assoc sid !subs;
                                   if qparams = [] then begin
                                     t.filtered <- false;
                                     Stats.incr stats.kinds_fallbacks;
                                     produce ~m:(`String s) [ ("event", `String "kinds_fallback") ]
                                   end;
                                   send_req ~filtered:false qparams
                               | _ -> ())
                           | _ | exception _ -> ())
                         end;
                         let advance c =
                           t.since <- min (Utils.current_time ()) (max t.since (c - 1));
                           save_since ~force:false
                         in
                         let dup = (not cfg.firehose_forward_raw) && (match extract_event_id s with Some id -> Dedup.mem dedup id | None -> false) in
                         if dup then begin
                           Stats.incr stats.seenearly;
                           (match extract_created_at s with Some c -> advance c | None -> ())
                         end
                         else begin
                           let d = try Yojson.Safe.from_string s with exn -> err exn "parsing"; raise exn in
                           let ev = match d with `List (`String "EVENT" :: _ :: (`Assoc _ as e) :: _) -> Some e | _ -> None in
                           (try produce ~m:d ~ev [ ("event", `String "event") ] with Eio.Cancel.Cancelled _ as e -> raise e | exn -> err exn "downstream");
                           match ev with
                           | Some (`Assoc f) -> ( match List.assoc_opt "created_at" f with Some (`Int c) -> advance c | _ -> ())
                           | _ -> ()
                         end;
                         read_loop ()
                   in
                   Fiber.first read_loop (fun () -> Promise.await stop)))
     with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> err exn "websocket");
    if alive () then begin
      let cap = if t.message_count = 0 then cfg.dead_relay_max_delay_s else cfg.max_delay_s in
      t.delay <- (if !msg_cnt > 0 then cfg.base_delay_s else Float.min (t.delay *. 2.0) cap);
      produce [ ("event", `String "sleep"); ("delay", `Int (int_of_float t.delay)); ("msg_cnt", `Int !msg_cnt) ];
      t.waiting_delay <- true;
      Stats.incr stats.relays_waiting;
      (match Fiber.first (fun () -> Promise.await stop; `Stop) (fun () -> Eio.Time.sleep clock t.delay; `Tick) with _ -> ());
      Stats.decr stats.relays_waiting;
      t.waiting_delay <- false
    end
  done;
  save_since ~force:true
