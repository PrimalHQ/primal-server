(* primalctl: operator CLI for primal-api. Subcommands:

     primalctl req <ws-url> <funcall> [kwargs-json] [--zlib]   one cache-API request, frames printed
     primalctl status [admin-url]                               GET /status of a primal-api
     primalctl drain  [admin-url]                               POST /drain
     primalctl metrics [admin-url]                              GET /metrics
     primalctl replay <corpus.jsonl> [--a ws://..] [--b ws://..] [--only f1,f2] [--all]
                      [--per-funcall N] [--workers K] [--timeout S] [--report mismatches.jsonl]
                                                                parity of B against A over a request corpus
     primalctl advsearch-sql <user-pubkey-hex> <query> <since> <until> [kinds]
     primalctl sign <nsec-file> <kind> <content> [tags-json]

   Default admin url: the admin port of selfhost/config/primal-api.json (selfhost/primal.sh);
   pass the url of any other deployment's admin_host:admin_port. *)

open Eio.Std

let default_admin = "http://127.0.0.1:8811"

let usage () =
  prerr_endline
    "usage: primalctl req <ws-url> <funcall> [kwargs-json] [--zlib]\n\
    \       primalctl status|drain|metrics [admin-url]\n\
    \       primalctl replay <corpus.jsonl> [--a ws-url] [--b ws-url] [--only f1,f2] [--all] [--per-funcall N] [--workers K] [--timeout S] [--report file]\n\
    \       primalctl advsearch-sql <user-pubkey-hex> <query> <since> <until> [kinds]   (one window's SQL, params inlined, for EXPLAIN)\n\
    \       primalctl sign <nsec-file> <kind> <content> [tags-json]   (a signed event as JSON, for event_from_user corpora)";
  exit 2

let parse_http_url (u : string) : string * int * string =
  match Http.parse_url u with
  | Some { Http.host; port; path; _ } -> (host, port, path)
  | None -> failwith ("not an http url: " ^ u)

let admin ~net ~clock ~meth ~path (url : string) : unit =
  let host, port, _ = parse_http_url url in
  let status, body = Http.plain_request ~net ~clock ~meth ~host ~port ~path () in
  Printf.printf "%d\n%s\n%!" status body;
  if status >= 400 then exit 1

(* Send one REQ and print every frame until EOSE (binary frames are zlib-inflated). *)
let req ~net ~clock ~url ~funcall ~kwargs ~zlib : unit =
  match Relay_broadcast.parse_relay_url url with
  | None -> failwith ("not a ws url: " ^ url)
  | Some (tls, host, port, path) ->
      Switch.run @@ fun sw ->
      let ws = Ws_client.connect ~tls ~sw ~net ~clock ~host ~port ~path () in
      let send_req subid filter =
        Ws_client.send_text ws
          (Yojson.Safe.to_string (`List [ `String "REQ"; `String subid; filter ]))
      in
      let wait_eose subid =
        let rec loop () =
          match Ws_client.recv_frame ws with
          | `Closed -> prerr_endline "connection closed"; exit 1
          | `Text t ->
              print_endline t;
              if t = Primal_api.Protocol.eose subid then () else loop ()
          | `Binary b ->
              (try print_endline (Zlib_util.uncompress b) with _ -> Printf.printf "<binary %d bytes>\n" (String.length b));
              loop ()
        in
        loop ()
      in
      if zlib then begin
        send_req "proto" (`Assoc [ ("cache", `List [ `String "set_primal_protocol"; `Assoc [ ("compression", `String "zlib") ] ]) ]);
        wait_eose "proto"
      end;
      let t0 = Unix.gettimeofday () in
      send_req "primalctl" (`Assoc [ ("cache", `List [ `String funcall; kwargs ]) ]);
      wait_eose "primalctl";
      Printf.eprintf "(%.0f ms)\n%!" ((Unix.gettimeofday () -. t0) *. 1000.);
      Ws_client.close ws

let replay_opts (corpus : string) (rest : string list) : Replay.opts =
  let rec go (o : Replay.opts) = function
    | "--a" :: v :: r -> go { o with url_a = v } r
    | "--b" :: v :: r -> go { o with url_b = v } r
    | "--only" :: v :: r -> go { o with only = String.split_on_char ',' v } r
    | "--all" :: r -> go { o with all = true } r
    | "--per-funcall" :: v :: r -> go { o with per_funcall = int_of_string v } r
    | "--workers" :: v :: r -> go { o with workers = int_of_string v } r
    | "--timeout" :: v :: r -> go { o with timeout = float_of_string v } r
    | "--report" :: v :: r -> go { o with report = Some v } r
    | [] -> o
    | a :: _ -> prerr_endline ("unknown replay option: " ^ a); usage ()
  in
  go { Replay.default_opts with corpus } rest

let () =
  let args = Array.to_list Sys.argv |> List.tl in
  (match args with
  | "sign" :: nsec_file :: kind :: content :: rest ->
      Mirage_crypto_rng_unix.use_default ();
      let ic = open_in nsec_file in
      let nsec = Fun.protect ~finally:(fun () -> close_in ic) (fun () -> String.trim (input_line ic)) in
      let seckey =
        match Bech32.decode ~hrp:"nsec" nsec with
        | Some data when String.length data = 32 -> data
        | _ -> ( match Hex_util.decode_opt nsec with Some k when String.length k = 32 -> k | _ -> failwith "nsec file: bech32 nsec or 64 hex expected")
      in
      let tags : Nostr.tag list =
        match rest with
        | t :: _ -> ( match Yojson.Safe.from_string t with `List l -> List.map (function `List x -> x | v -> [ v ]) l | _ -> [])
        | [] -> []
      in
      let e = Nostr.create ~seckey ~created_at:(int_of_float (Unix.gettimeofday ())) ~kind:(int_of_string kind) ~tags ~content in
      print_endline (Yojson.Safe.to_string (Nostr.to_json e));
      exit 0
  | "advsearch-sql" :: user :: query :: since :: until :: rest ->
      let user_pubkey = Option.get (Hex_util.decode_opt user) in
      let kinds = match rest with k :: _ -> List.map int_of_string (String.split_on_char ',' k) | [] -> [] in
      let now = int_of_float (Unix.gettimeofday ()) in
      let expr, _ = Primal_api.Advsearch.prepare ~now (Primal_api.Advsearch.quote_urls query) in
      (* PRIMAL_LEAN=1: the SQL of the config's "lean" paths *)
      let lean = Sys.getenv_opt "PRIMAL_LEAN" = Some "1" in
      let sql = Primal_api.Advsearch.to_sql ~lean ~user_pubkey expr ~since:(int_of_string since) ~until:(int_of_string until) ~kinds in
      (* inline $n: bytea params as '\x..'::bytea, numbers bare, the rest quoted *)
      let params = Array.of_list sql.params in
      let buf = Buffer.create 4096 in
      let n = String.length sql.text in
      let i = ref 0 in
      while !i < n do
        if sql.text.[!i] = '$' then begin
          let j = ref (!i + 1) in
          while !j < n && sql.text.[!j] >= '0' && sql.text.[!j] <= '9' do incr j done;
          let k = int_of_string (String.sub sql.text (!i + 1) (!j - !i - 1)) in
          (match params.(k - 1) with
          | Some v when String.length v > 2 && String.sub v 0 2 = "\\x" -> Buffer.add_string buf (Printf.sprintf "'%s'::bytea" v)
          | Some v when int_of_string_opt v <> None || float_of_string_opt v <> None -> Buffer.add_string buf v
          | Some v -> Buffer.add_string buf (Printf.sprintf "'%s'" (String.concat "''" (String.split_on_char '\'' v)))
          | None -> Buffer.add_string buf "NULL");
          i := !j
        end
        else (Buffer.add_char buf sql.text.[!i]; incr i)
      done;
      print_endline (Buffer.contents buf);
      exit 0
  | "replay" :: corpus :: rest ->
      Mirage_crypto_rng_unix.use_default ();
      Replay.run (replay_opts corpus rest) ~native:(Primal_api.Funcall.native_names ());
      exit 0
  | _ -> ());
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  match args with
  | "req" :: url :: funcall :: rest ->
      let zlib = List.mem "--zlib" rest in
      let rest = List.filter (fun a -> a <> "--zlib") rest in
      let kwargs = match rest with k :: _ -> Yojson.Safe.from_string k | [] -> `Assoc [] in
      req ~net ~clock ~url ~funcall ~kwargs ~zlib
  | [ "status" ] -> admin ~net ~clock ~meth:"GET" ~path:"/status" default_admin
  | [ "status"; u ] -> admin ~net ~clock ~meth:"GET" ~path:"/status" u
  | [ "metrics" ] -> admin ~net ~clock ~meth:"GET" ~path:"/metrics" default_admin
  | [ "metrics"; u ] -> admin ~net ~clock ~meth:"GET" ~path:"/metrics" u
  | [ "drain" ] -> admin ~net ~clock ~meth:"POST" ~path:"/drain" default_admin
  | [ "drain"; u ] -> admin ~net ~clock ~meth:"POST" ~path:"/drain" u
  | _ -> usage ()
