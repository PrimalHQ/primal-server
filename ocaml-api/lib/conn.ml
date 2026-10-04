(* One client WebSocket connection of the cache API, in the ws-connector shape (connection.rs /
   router.rs): a paired upstream WebSocket to the Julia CacheServer is opened per client; frames
   the native dispatcher does not handle are forwarded verbatim and every upstream frame is relayed
   back verbatim; an idle timer closes both sides. Phase 2 handles `set_primal_protocol` and
   `server_name` natively; the funcall registry of §5.2 plugs in here in Phase 3.

   Exactly like ws-connector, `set_primal_protocol` is NOT forwarded: the zlib flag only applies to
   natively answered requests, and proxied responses arrive in whatever form the upstream sends. *)

open Eio.Std

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [conn] %s\n%!" (Procinfo.timestamp ()) s) fmt

type t = {
  id : int;
  session : Http_server.ws_session;
  mutable use_zlib : bool;
  mutable last_msg : float;
  mutable backend : Ws_client.t option;
  mutable closing : bool;
  opened_at : float;
}

(* Registry of live connections (all domains), for drain and the admin endpoint. *)
let registry : (int, t) Hashtbl.t = Hashtbl.create 1024
let registry_lock = Mutex.create ()
let next_id = Atomic.make 1

let with_registry f =
  Mutex.lock registry_lock;
  Fun.protect ~finally:(fun () -> Mutex.unlock registry_lock) f

let count () = with_registry (fun () -> Hashtbl.length registry)

(* Ask a connection to close (from any domain): flag it; its own idle/reader fibers notice within
   a tick and close both sockets. *)
let request_close (c : t) = c.closing <- true

let close_idle ~(older_than : float) () : int =
  let now = Unix.gettimeofday () in
  with_registry (fun () ->
      Hashtbl.fold (fun _ c n -> if now -. c.last_msg >= older_than then (request_close c; n + 1) else n) registry 0)

let close_all () : int =
  with_registry (fun () -> Hashtbl.fold (fun _ c n -> request_close c; n + 1) registry 0)

(* Send a natively produced response: messages (JSON texts) + notices + EOSE, in ws-connector's
   framing (binary zlib EVENTS when the client asked for compression). *)
let respond (c : t) (stats : Stats.t) ~subid ?(notices = []) (msgs : string list) : unit =
  if c.use_zlib then begin
    c.session.ws_send_binary (Protocol.events_zlib subid msgs);
    Stats.incr stats.sent
  end
  else
    List.iter (fun m -> c.session.ws_send_text (Protocol.event subid m); Stats.incr stats.sent) msgs;
  List.iter (fun n -> c.session.ws_send_text (Protocol.notice subid n); Stats.incr stats.sent) notices;
  c.session.ws_send_text (Protocol.eose subid);
  Stats.incr stats.sent

(* Native dispatch. Returns true when handled (nothing is forwarded). *)
let handle_native (cfg : Config.t) (stats : Stats.t) (c : t) (p : Protocol.incoming) : bool =
  match p with
  | Protocol.Req { subid; funcall = Some "set_primal_protocol"; kwargs; _ } ->
      if Protocol.wants_zlib kwargs then c.use_zlib <- true;
      c.session.ws_send_text (Protocol.eose subid);
      Stats.incr stats.sent;
      Stats.incr stats.handled;
      true
  | Protocol.Req { subid; funcall = Some "server_name"; _ } ->
      respond c stats ~subid [ Yojson.Safe.to_string (`Assoc [ ("content", `String cfg.servername) ]) ];
      Stats.incr stats.handled;
      true
  | _ -> false

let run ~net ~clock (cfg : Config.t) (stats : Stats.t) (session : Http_server.ws_session) : unit =
  let id = Atomic.fetch_and_add next_id 1 in
  let c =
    { id; session; use_zlib = false; last_msg = Unix.gettimeofday (); backend = None; closing = false;
      opened_at = Unix.gettimeofday () }
  in
  with_registry (fun () -> Hashtbl.replace registry id c);
  Stats.incr stats.connections;
  Stats.incr stats.accepted;
  let tls, host, port, path = Config.upstream cfg in
  Fun.protect
    ~finally:(fun () ->
      with_registry (fun () -> Hashtbl.remove registry id);
      Stats.decr stats.connections;
      (match c.backend with Some b -> (try Ws_client.close b with _ -> ()) | None -> ());
      try session.ws_close () with _ -> ())
    (fun () ->
      Switch.run @@ fun sw ->
      (* Upstream first (ws-connector connects the backend before serving the client). *)
      (match
         Eio.Time.with_timeout clock cfg.upstream_connect_timeout_s (fun () ->
             Ok (Ws_client.connect ~tls ~sw ~net ~clock ~host ~port ~path ()))
       with
      | Ok b -> c.backend <- Some b
      | Error `Timeout ->
          Stats.incr stats.backend_failures;
          failwith "upstream connect timeout"
      | exception e ->
          Stats.incr stats.backend_failures;
          raise e);
      let backend = Option.get c.backend in
      let touch () = c.last_msg <- Unix.gettimeofday () in
      let client_loop () =
        let rec loop () =
          if c.closing then ()
          else
            match session.ws_recv () with
            | `Closed -> ()
            | `Binary b ->
                touch ();
                Stats.incr stats.recv;
                Ws_client.send_binary backend b;
                Stats.incr stats.proxied;
                loop ()
            | `Text s ->
                touch ();
                Stats.incr stats.recv;
                let p = Protocol.parse s in
                let handled = try handle_native cfg stats c p with e -> Stats.incr stats.errors; log "native handler: %s" (Printexc.to_string e); false in
                (match p with
                | Protocol.Req { funcall = Some fc; subid; _ } ->
                    if handled && cfg.log_handled then log "handled: %s sub_id=%s" fc subid
                    else if (not handled) && cfg.log_not_handled then log "not handled: %s sub_id=%s" fc subid
                | _ -> ());
                if not handled then begin
                  Ws_client.send_text backend s;
                  Stats.incr stats.proxied
                end;
                loop ()
        in
        loop ()
      in
      let backend_loop () =
        let rec loop () =
          if c.closing then ()
          else
            match Ws_client.recv_frame backend with
            | `Closed -> ()
            | `Text s ->
                touch ();
                session.ws_send_text s;
                Stats.incr stats.backend_frames;
                Stats.incr stats.sent;
                loop ()
            | `Binary b ->
                touch ();
                session.ws_send_binary b;
                Stats.incr stats.backend_frames;
                Stats.incr stats.sent;
                loop ()
        in
        loop ()
      in
      (* ws-connector: every 3 s, close when idle for >= (0.95..1.0) * idle_timeout. *)
      let idle_loop () =
        let rfactor = 0.95 +. Random.float 0.05 in
        let limit = rfactor *. cfg.idle_connection_timeout_s in
        let rec loop () =
          Eio.Time.sleep clock 3.0;
          if c.closing || session.ws_is_closed () then ()
          else
            let dt = Unix.gettimeofday () -. c.last_msg in
            if dt >= limit then begin
              Stats.incr stats.idle_closed;
              log "closing idle connection %d (%s), last message %.0fs ago" c.id session.ws_peer dt
            end
            else loop ()
        in
        loop ()
      in
      (try Fiber.any [ client_loop; backend_loop; idle_loop ]
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | End_of_file -> ()
       | exn -> Stats.incr stats.errors; log "connection %d: %s" c.id (Printexc.to_string exn));
      c.closing <- true)
