(* HTTP/1.1 + WebSocket server kernel on httpun-eio / gluten / httpun-ws, ported from the tsunami
   kernel's api/core/httpd.ml and trimmed to what Primal needs (no bearer auth, no cache policy —
   those were news-kernel concerns). Additions for a public Nostr-facing server: request body cap,
   WebSocket inbound message cap, binary frames, and a BOUNDED per-connection outbound queue with a
   writer fiber that waits for the wire flush, so a slow reader applies backpressure to the sender
   and a wedged socket is closed after [ws_send_stall_s] (replacing Julia's WSConnUnblocker).

   Handlers return a [resp] value; writing it is the kernel's job. A [Ws] response hands the
   upgraded connection to a session function that owns its lifetime. The listening socket is
   created by the caller (Listen), so one bound port can be served from several domains. *)

open Eio.Std

type meth = [ `GET | `POST | `PUT | `PATCH | `DELETE ]

type req = {
  meth : meth;
  raw_meth : string; (* the method as sent: HEAD is routed as `GET, handlers that care read this *)
  path : string; (* without query string *)
  params : (string * string) list; (* named path params *)
  query : (string * string) list;
  headers : (string * string) list; (* lowercased names *)
  body : string;
  peer : string; (* client address, for logs *)
}

let param (r : req) (name : string) : string =
  match List.assoc_opt name r.params with
  | Some v -> v
  | None -> failwith ("http_server: missing path param " ^ name)

let query_param (r : req) (name : string) : string option = List.assoc_opt name r.query
let req_header (r : req) (name : string) : string option =
  List.assoc_opt (String.lowercase_ascii name) r.headers

let body_json (r : req) : Yojson.Safe.t option =
  try Some (Yojson.Safe.from_string r.body) with _ -> None

(* {1 WebSocket sessions} *)

type ws_frame = [ `Text of string | `Binary of string | `Closed ]

type ws_session = {
  ws_send_text : string -> unit; (* enqueue; blocks while the outbound queue is full, at most send_stall_s *)
  ws_send_binary : string -> unit;
  ws_try_send_text : string -> unit;
      (* enqueue only if the queue has room, else drop the frame; never blocks. For loops that
         push to many connections (broadcasts, live events): one client that stops reading must
         not hold up the others. *)
  ws_recv : unit -> ws_frame; (* blocking *)
  ws_close : ?code:int -> unit -> unit; (* send a close frame *)
  ws_is_closed : unit -> bool;
  ws_peer : string;
}

type ws_limits = {
  max_message_bytes : int; (* inbound text/binary message cap; larger -> close 1009 *)
  outbound_queue : int; (* frames queued before the sender blocks *)
  send_stall_s : float; (* a write not flushed within this -> close the socket *)
}

let default_ws_limits = { max_message_bytes = 1 lsl 20; outbound_queue = 256; send_stall_s = 15.0 }

type resp =
  | Json of int * Yojson.Safe.t
  | Text of int * string
  | Blob of int * string * string (* content_type, body *)
  | Redirect of int * string (* status (301/302/307/308), location *)
  | Empty of int
  | Raw of int * (string * string) list * string (* status, headers (content-type incl.), body *)
  | Ws of string option * (ws_session -> unit) (* subprotocol echo, session; `GET only *)

(* Rest must be the final segment: matches ONE OR MORE remaining path segments joined with '/'. *)
type seg = Lit of string | P of string | Rest of string

type route = { meth : meth; pattern : seg list; handler : req -> resp }

let pattern_string (p : seg list) : string =
  "/"
  ^ String.concat "/"
      (List.map (function Lit s -> s | P n -> "{" ^ n ^ "}" | Rest n -> "{" ^ n ^ ":path}") p)

let split_path (path : string) : string list =
  List.filter (fun s -> s <> "") (String.split_on_char '/' path)

let match_pattern (pattern : seg list) (segments : string list) : (string * string) list option =
  let rec go pat segs acc =
    match (pat, segs) with
    | [], [] -> Some (List.rev acc)
    | [ Rest name ], (_ :: _ as rest) -> Some (List.rev ((name, String.concat "/" rest) :: acc))
    | Lit l :: pat', s :: segs' when l = s -> go pat' segs' acc
    | P name :: pat', s :: segs' -> go pat' segs' ((name, s) :: acc)
    | _ -> None
  in
  go pattern segments []

let percent_decode ?(plus_is_space = false) (s : string) : string =
  let b = Buffer.create (String.length s) in
  let n = String.length s in
  let rec go i =
    if i >= n then ()
    else if s.[i] = '%' && i + 2 < n then (
      match int_of_string_opt ("0x" ^ String.sub s (i + 1) 2) with
      | Some c ->
          Buffer.add_char b (Char.chr c);
          go (i + 3)
      | None ->
          Buffer.add_char b s.[i];
          go (i + 1))
    else if s.[i] = '+' && plus_is_space then (
      Buffer.add_char b ' ';
      go (i + 1))
    else (
      Buffer.add_char b s.[i];
      go (i + 1))
  in
  go 0;
  Buffer.contents b

let parse_query (qs : string) : (string * string) list =
  let dec = percent_decode ~plus_is_space:true in
  String.split_on_char '&' qs
  |> List.filter_map (fun kv ->
         if kv = "" then None
         else
           match String.index_opt kv '=' with
           | Some i -> Some (dec (String.sub kv 0 i), dec (String.sub kv (i + 1) (String.length kv - i - 1)))
           | None -> Some (dec kv, ""))

(* {1 Services} *)

type error_style = Flat | Plain_text (* {"error": msg} | bare text *)

let error_body (style : error_style) ~(message : string) (status : int) : resp =
  match style with
  | Flat -> Json (status, `Assoc [ ("error", `String message) ])
  | Plain_text -> Text (status, message)

type service = {
  name : string;
  routes : route list;
  error_style : error_style;
  cors : bool; (* emit CORS headers + answer OPTIONS preflights (Julia api_headers parity) *)
  max_body : int; (* request body cap in bytes *)
  ws_limits : ws_limits;
  on_request : meth:string -> route:string -> status:int -> dur_ms:float -> unit; (* metrics hook *)
}

let default_service name routes =
  { name; routes; error_style = Plain_text; cors = false; max_body = 16 * 1024 * 1024;
    ws_limits = default_ws_limits; on_request = (fun ~meth:_ ~route:_ ~status:_ ~dur_ms:_ -> ()) }

let cors_headers =
  [
    ("access-control-allow-origin", "*");
    ("access-control-allow-methods", "DELETE, GET, HEAD, OPTIONS, PATCH, POST, PUT");
    ("access-control-allow-headers", "*");
    ("access-control-max-age", "600");
  ]

let respond ~(cors : bool) (reqd : Httpun.Reqd.t) (status : int) (content_type : string)
    (extra_headers : (string * string) list) (body : string) : unit =
  (* a handler may set content-length itself (HEAD answers carry the blob's length with no body) *)
  let own_length = List.exists (fun (k, _) -> String.lowercase_ascii k = "content-length") extra_headers in
  let headers =
    Httpun.Headers.of_list
      ((if cors then cors_headers else []) @ extra_headers
      @ [ ("content-type", content_type) ] @ (if own_length then [] else [ ("content-length", string_of_int (String.length body)) ]))
  in
  Httpun.Reqd.respond_with_string reqd
    (Httpun.Response.create ~headers (Httpun.Status.of_code status))
    body

let sha1_raw (s : string) : string = Digestif.SHA1.(digest_string s |> to_raw_string)

(* Read the whole request body (up to [max]) then invoke [k (Ok body)] / [k (Error ())]. *)
let with_body ~(max : int) (reqd : Httpun.Reqd.t) (k : (string, unit) result -> unit) : unit =
  let body = Httpun.Reqd.request_body reqd in
  let buf = Buffer.create 4096 in
  let too_big = ref false in
  let rec loop () =
    Httpun.Body.Reader.schedule_read body
      ~on_read:(fun bs ~off ~len ->
        if Buffer.length buf + len > max then too_big := true
        else Buffer.add_string buf (Bigstringaf.substring bs ~off ~len);
        loop ())
      ~on_eof:(fun () -> if !too_big then k (Error ()) else k (Ok (Buffer.contents buf)))
  in
  loop ()

(* {1 WebSocket plumbing} *)

(* Inbound: frames assembled into messages (continuations appended; ping answered; close ->
   `Closed). Oversized messages close the socket with 1009 (message too big). *)
let ws_input_handlers ~(limits : ws_limits) (wsd : Httpun_ws.Wsd.t) (push : ws_frame -> unit) :
    Httpun_ws.Websocket_connection.input_handlers =
  let assembling = Buffer.create 1024 in
  let kind = ref `Text in
  let read_payload payload (k : string -> unit) =
    let chunks = Buffer.create 1024 in
    let rec go () =
      Httpun_ws.Payload.schedule_read payload
        ~on_read:(fun bs ~off ~len ->
          Buffer.add_string chunks (Bigstringaf.substring bs ~off ~len);
          go ())
        ~on_eof:(fun () -> k (Buffer.contents chunks))
    in
    go ()
  in
  let finish_message () =
    let msg = Buffer.contents assembling in
    Buffer.clear assembling;
    match !kind with `Text -> push (`Text msg) | `Binary -> push (`Binary msg)
  in
  let data ~is_fin payload =
    read_payload payload (fun chunk ->
        if Buffer.length assembling + String.length chunk > limits.max_message_bytes then begin
          Buffer.clear assembling;
          (try Httpun_ws.Wsd.close ~code:`Message_too_big wsd with _ -> ());
          push `Closed
        end
        else begin
          Buffer.add_string assembling chunk;
          if is_fin then finish_message ()
        end)
  in
  let frame ~(opcode : Httpun_ws.Websocket.Opcode.t) ~is_fin ~len:_ payload =
    match opcode with
    | `Text ->
        kind := `Text;
        data ~is_fin payload
    | `Binary ->
        kind := `Binary;
        data ~is_fin payload
    | `Continuation -> data ~is_fin payload
    | `Ping -> read_payload payload (fun _ -> try Httpun_ws.Wsd.send_pong wsd with _ -> ())
    | `Pong -> read_payload payload (fun _ -> ())
    | `Connection_close ->
        read_payload payload (fun _ ->
            push `Closed;
            try Httpun_ws.Wsd.close wsd with _ -> ())
    | `Other _ -> read_payload payload (fun _ -> ())
  in
  { Httpun_ws.Websocket_connection.frame; eof = (fun ?error:_ () -> push `Closed) }

(* Outbound: a bounded queue drained by one writer fiber. Each frame is handed to httpun-ws and
   the fiber waits for the flush callback (bounded by [send_stall_s]); on a stall or a closed wsd
   the socket is closed and the queue is abandoned. *)
let start_ws_writer ~sw ~clock ~(limits : ws_limits) (wsd : Httpun_ws.Wsd.t) :
    (([ `Text | `Binary | `Continuation ] * string) option -> unit)
    * (([ `Text | `Binary | `Continuation ] * string) option -> unit)
    * (unit -> bool) =
  let queue : ([ `Text | `Binary | `Continuation ] * string) option Eio.Stream.t =
    Eio.Stream.create limits.outbound_queue
  in
  let dead = ref false in
  let flushed () =
    let p, r = Promise.create () in
    Httpun_ws.Wsd.flushed wsd (fun () -> Promise.resolve r ());
    match Eio.Time.with_timeout clock limits.send_stall_s (fun () -> Promise.await p; Ok ()) with
    | Ok () -> true
    | Error `Timeout -> false
  in
  Fiber.fork ~sw (fun () ->
      let rec loop () =
        match Eio.Stream.take queue with
        | None -> dead := true
        | Some (kind, s) ->
            if Httpun_ws.Wsd.is_closed wsd then dead := true
            else begin
              (try
                 Httpun_ws.Wsd.send_bytes wsd ~kind (Bytes.unsafe_of_string s) ~off:0
                   ~len:(String.length s)
               with _ -> dead := true);
              if (not !dead) && not (flushed ()) then begin
                Printf.printf "[http_server] ws send stalled > %.0fs; closing\n%!" limits.send_stall_s;
                (try Httpun_ws.Wsd.close ~code:`Going_away wsd with _ -> ());
                dead := true
              end;
              if not !dead then loop ()
            end
      in
      loop ());
  (* Once the writer has stopped, nothing takes from the queue: a sender blocked on a full queue
     would wait forever (the API's broadcasts stopped for every connection after one client
     stalled). So the wait is bounded; a queue that stays full that long means the
     writer is stalled or gone. *)
  let send item =
    if not !dead then
      match Eio.Time.with_timeout clock limits.send_stall_s (fun () -> Eio.Stream.add queue item; Ok ()) with
      | Ok () -> ()
      | Error `Timeout -> dead := true
  in
  let try_send item =
    if (not !dead) && Eio.Stream.length queue < limits.outbound_queue then
      (* another domain may fill the last slot between the check and the add *)
      match Eio.Time.with_timeout clock 0.05 (fun () -> Eio.Stream.add queue item; Ok ()) with
      | Ok () | Error `Timeout -> ()
  in
  (send, try_send, fun () -> !dead)

(* {1 Request parsing / routing} *)

type parsed = {
  p_meth : meth option;
  p_raw_meth : string;
  p_path : string;
  p_query : (string * string) list;
  p_headers : (string * string) list;
  p_segments : string list;
}

let parse_request (request : Httpun.Request.t) : parsed =
  let target = request.Httpun.Request.target in
  let path, query =
    match String.index_opt target '?' with
    | Some i -> (String.sub target 0 i, parse_query (String.sub target (i + 1) (String.length target - i - 1)))
    | None -> (target, [])
  in
  let headers =
    List.map (fun (k, v) -> (String.lowercase_ascii k, v)) (Httpun.Headers.to_list request.Httpun.Request.headers)
  in
  let meth : meth option =
    match request.Httpun.Request.meth with
    | `GET | `HEAD -> Some `GET
    | `POST -> Some `POST
    | `PUT -> Some `PUT
    | `DELETE -> Some `DELETE
    | `Other "PATCH" -> Some `PATCH
    | _ -> None
  in
  { p_meth = meth; p_raw_meth = Httpun.Method.to_string request.Httpun.Request.meth; p_path = path;
    p_query = query; p_headers = headers; p_segments = List.map percent_decode (split_path path) }

let find_route (svc : service) (p : parsed) :
    [ `Unmatched | `Wrong_method of string | `Found of route * (string * string) list ] =
  let matching =
    List.filter_map
      (fun r -> match match_pattern r.pattern p.p_segments with Some params -> Some (r, params) | None -> None)
      svc.routes
  in
  match (p.p_meth, matching) with
  | _, [] -> `Unmatched
  | None, (r, _) :: _ -> `Wrong_method (pattern_string r.pattern)
  | Some m, matching -> (
      match List.find_opt (fun (r, _) -> r.meth = m) matching with
      | Some (r, params) -> `Found (r, params)
      | None -> `Wrong_method (pattern_string (fst (List.hd matching)).pattern))

let string_of_sockaddr : Eio.Net.Sockaddr.stream -> string = function
  | `Tcp (ip, port) -> Format.asprintf "%a:%d" Eio.Net.Ipaddr.pp ip port
  | `Unix p -> p

(* {1 Responding} *)

let send_resp (svc : service) ~sw ~clock ~(peer : string) ~(record : status:int -> unit)
    (reqd : Httpun.Reqd.t) (gr : Httpun.Reqd.t Gluten.reqd) (resp : resp) : unit =
  let cors = svc.cors in
  match resp with
  | Json (status, j) ->
      record ~status;
      respond ~cors reqd status "application/json" [] (Yojson.Safe.to_string j)
  | Text (status, s) ->
      record ~status;
      respond ~cors reqd status "text/plain; charset=utf-8" [] s
  | Blob (status, content_type, body) ->
      record ~status;
      respond ~cors reqd status content_type [] body
  | Raw (status, headers, body) ->
      record ~status;
      let content_type =
        match List.assoc_opt "content-type" headers with Some ct -> ct | None -> "application/octet-stream"
      in
      respond ~cors reqd status content_type (List.filter (fun (k, _) -> k <> "content-type") headers) body
  | Redirect (status, location) ->
      record ~status;
      respond ~cors reqd status "text/plain; charset=utf-8" [ ("location", location) ] ""
  | Empty status ->
      record ~status;
      let headers = Httpun.Headers.of_list ((if cors then cors_headers else []) @ [ ("content-length", "0") ]) in
      Httpun.Reqd.respond_with_string reqd (Httpun.Response.create ~headers (Httpun.Status.of_code status)) ""
  | Ws (subprotocol, run_session) -> (
      let extra =
        match subprotocol with
        | Some p -> Some (Httpun.Headers.of_list [ ("sec-websocket-protocol", p) ])
        | None -> None
      in
      let limits = svc.ws_limits in
      let inbox : ws_frame Eio.Stream.t = Eio.Stream.create 64 in
      let closed = ref false in
      let push m =
        (match m with `Closed -> closed := true | _ -> ());
        Eio.Stream.add inbox m
      in
      let upgrade () =
        let ws_conn =
          Httpun_ws.Server_connection.create_websocket (fun wsd ->
              let send, try_send, writer_dead = start_ws_writer ~sw ~clock ~limits wsd in
              let session =
                {
                  ws_send_text = (fun s -> send (Some (`Text, s)));
                  ws_send_binary = (fun s -> send (Some (`Binary, s)));
                  ws_try_send_text = (fun s -> try_send (Some (`Text, s)));
                  ws_recv = (fun () -> if !closed && Eio.Stream.length inbox = 0 then `Closed else Eio.Stream.take inbox);
                  ws_close =
                    (fun ?code () ->
                      closed := true;
                      (try
                         Httpun_ws.Wsd.close
                           ?code:(Option.map (fun c -> Httpun_ws.Websocket.Close_code.of_code_exn c) code)
                           wsd
                       with _ -> ());
                      send None);
                  ws_is_closed = (fun () -> !closed || writer_dead () || Httpun_ws.Wsd.is_closed wsd);
                  ws_peer = peer;
                }
              in
              Fiber.fork ~sw (fun () ->
                  (try run_session session
                   with
                   | Eio.Cancel.Cancelled _ as e -> raise e
                   | exn -> Printf.printf "[http_server] %s ws session error: %s\n%!" svc.name (Printexc.to_string exn));
                  closed := true;
                  send None;
                  try Httpun_ws.Wsd.close wsd with _ -> ());
              ws_input_handlers ~limits wsd push)
        in
        gr.Gluten.upgrade (Gluten.make (module Httpun_ws.Server_connection) ws_conn)
      in
      match Httpun_ws.Handshake.respond_with_upgrade ?headers:extra ~sha1:sha1_raw reqd upgrade with
      | Ok () -> record ~status:101
      | Error _msg ->
          record ~status:400;
          respond ~cors reqd 400 "text/plain" [] "bad websocket handshake")

let answer_preflight (svc : service) (p : parsed) (reqd : Httpun.Reqd.t) ~(record : route:string -> status:int -> unit) : bool =
  if p.p_raw_meth = "OPTIONS" && svc.cors then begin
    let req_headers = match List.assoc_opt "access-control-request-headers" p.p_headers with Some h -> h | None -> "*" in
    record ~route:"OPTIONS" ~status:200;
    respond ~cors:true reqd 200 "text/plain; charset=utf-8" [ ("access-control-allow-headers", req_headers) ] "ok";
    true
  end
  else false

(* Dispatch one request; runs inside the connection fiber, handlers in their own fiber. *)
let dispatch (svc : service) ~sw ~clock ~(peer : string) (gr : Httpun.Reqd.t Gluten.reqd) : unit =
  let reqd = gr.Gluten.reqd in
  let request = Httpun.Reqd.request reqd in
  let started = Eio.Time.now clock in
  let p = parse_request request in
  let record ~route ~status =
    svc.on_request ~meth:p.p_raw_meth ~route ~status ~dur_ms:((Eio.Time.now clock -. started) *. 1000.0)
  in
  let finish ~route resp = send_resp svc ~sw ~clock ~peer ~record:(fun ~status -> record ~route ~status) reqd gr resp in
  if answer_preflight svc p reqd ~record then ()
  else
    match find_route svc p with
    | `Unmatched -> finish ~route:"UNMATCHED" (error_body svc.error_style ~message:"not found" 404)
    | `Wrong_method route -> finish ~route (error_body svc.error_style ~message:"method not allowed" 405)
    | `Found (r, params) ->
        let route = pattern_string r.pattern in
        let m = Option.get p.p_meth in
        with_body ~max:svc.max_body reqd (function
          | Error () -> finish ~route (error_body svc.error_style ~message:"request body too large" 413)
          | Ok body ->
              Fiber.fork ~sw (fun () ->
                  let resp =
                    try r.handler { meth = m; raw_meth = p.p_raw_meth; path = p.p_path; params; query = p.p_query; headers = p.p_headers; body; peer }
                    with
                    | Eio.Cancel.Cancelled _ as e -> raise e
                    | Failure msg -> error_body svc.error_style ~message:("internal error: " ^ msg) 500
                    | exn -> error_body svc.error_style ~message:("internal error: " ^ Printexc.to_string exn) 500
                  in
                  finish ~route resp))

let error_handler (_client : Eio.Net.Sockaddr.stream) ?request:_ _error respond_f : unit =
  let headers = Httpun.Headers.of_list [ ("content-length", "0") ] in
  let body = respond_f headers in
  Httpun.Body.Writer.close body

(* Open connections across all services in this process — the rolling-restart drain gate. *)
let inflight : int Atomic.t = Atomic.make 0
let inflight_connections () : int = Atomic.get inflight

(* Handle one accepted connection to completion (HTTP keep-alive requests, or a WS session). *)
let handle_connection (svc : service) ~clock (flow : _ Eio.Net.stream_socket) (client : Eio.Net.Sockaddr.stream) : unit =
  (* TCP_NODELAY: a reply is several small writes (EVENTs, then EOSE); with Nagle the last one waited
     for the client's delayed ACK, ~40 ms on every short request *)
  (match Eio_unix.Resource.fd_opt flow with
  | Some fd -> (
      try Eio_unix.Fd.use_exn "nodelay" fd (fun u -> Unix.setsockopt u Unix.TCP_NODELAY true)
      with Unix.Unix_error _ | Eio.Io _ -> ())
  | None -> ());
  Atomic.incr inflight;
  let peer = string_of_sockaddr client in
  Fun.protect
    ~finally:(fun () -> Atomic.decr inflight)
    (fun () ->
      Switch.run @@ fun conn_sw ->
      Httpun_eio.Server.create_connection_handler ~sw:conn_sw
        ~request_handler:(fun _client gr -> dispatch svc ~sw:conn_sw ~clock ~peer gr)
        ~error_handler client flow)

(* Accept loop on an already-imported listening socket (Listen.import) in the CURRENT domain.
   Resolving [stop] ends the loop and closes nothing else: in-flight connections (on [sw]) keep
   running and are drained by the caller via [inflight_connections]. *)
let serve_on ~sw ~clock ?(stop : unit Promise.t option) (svc : service)
    (socket : _ Eio.Net.listening_socket) : unit =
  let accept_loop () =
    while true do
      Eio.Net.accept_fork ~sw socket
        ~on_error:(fun exn ->
          match exn with
          | Eio.Cancel.Cancelled _ -> ()
          | _ -> Printf.printf "[http_server] %s connection error: %s\n%!" svc.name (Printexc.to_string exn))
        (fun flow client -> handle_connection svc ~clock flow client)
    done
  in
  match stop with
  | None -> accept_loop ()
  | Some stop -> Fiber.first (fun () -> Promise.await stop) accept_loop
