(* One client WebSocket connection of the cache API, in the ws-connector shape (connection.rs /
   router.rs): a paired upstream WebSocket to the Julia CacheServer is opened per client, on its
   first request the native dispatcher (Funcall) does not handle; such requests are forwarded
   verbatim and every upstream frame is relayed back verbatim; an idle timer closes both sides.
   Without an upstream (upstream_julia_ws null, or its connect fails) such a request is answered
   like Julia answers one it cannot serve: NOTICE "unknown api request" for a funcall name the
   dispatcher does not know, NOTICE "error" otherwise, then EOSE.

   Exactly like ws-connector, `set_primal_protocol` is NOT forwarded: the zlib flag only applies to
   natively answered requests, and proxied responses arrive in whatever form the upstream sends.
   Live-event subscriptions registered by native handlers are dropped on CLOSE and on disconnect. *)

open Eio.Std

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [conn] %s\n%!" (Procinfo.timestamp ()) s) fmt

type t = {
  id : int;
  session : Http_server.ws_session;
  mutable use_zlib : bool;
  mutable last_msg : float;
  mutable backend : Ws_client.t option;
  mutable closing : bool;
  mutable inflight : int; (* natively handled requests being computed right now *)
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
let request_close (c : t) = c.closing <- true

let close_idle ~(older_than : float) () : int =
  let now = Unix.gettimeofday () in
  with_registry (fun () ->
      Hashtbl.fold (fun _ c n -> if now -. c.last_msg >= older_than && c.inflight = 0 then (request_close c; n + 1) else n) registry 0)

let close_all () : int = with_registry (fun () -> Hashtbl.fold (fun _ c n -> request_close c; n + 1) registry 0)

(* Send a natively produced response in ws-connector's framing: messages + notices + EOSE
   (binary zlib EVENTS when the client asked for compression). *)
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

(* Native dispatch of one REQ. Returns true when handled (nothing is forwarded). *)
(* The non-"cache" REQ filters of the Julia CacheServer. on_client_message first rejects any REQ
   whose filters carry "kinds" or "authors" (NOTICE, then the connection is closed); then
   initial_filter_handler maps {"ids"} and {"since"/"until"} to `events` and {"search"} to the
   `search` funcall (still proxied: `None). The live push of new events to since/idsonly
   subscriptions had no producer left in Julia (the importer moved out), so a since/until REQ is a
   one-shot listing. *)
let filter_funcall (raw : string) : [ `Call of Funcall.t * Kw.t | `Reject of string | `None ] =
  match Yojson.Safe.from_string raw with
  | `List (`String "REQ" :: `String _ :: filters) -> (
      let objs = List.filter_map (function `Assoc f -> Some f | _ -> None) filters in
      if List.exists (fun f -> List.mem_assoc "kinds" f || List.mem_assoc "authors" f) objs then
        `Reject "kinds or authors filter is not supported"
      else
        match objs with
        | f :: _ -> (
            match List.assoc_opt "ids" f with
            | Some (`List ids) ->
                let ids = List.filter_map (function `String s when String.length s = 64 && Hex_util.decode_opt s <> None -> Some (`String s) | _ -> None) ids in
                `Call (Funcall.Events, `Assoc [ ("event_ids", `List ids) ])
            | _ when List.mem_assoc "search" f -> `None
            | _ when List.mem_assoc "since" f || List.mem_assoc "until" f ->
                `Call (Funcall.Events, `Assoc (List.filter (fun (k, _) -> List.mem k [ "since"; "until"; "limit"; "idsonly" ]) f))
            | _ -> `None)
        | [] -> `None)
  | _ -> `None
  | exception _ -> `None

let handle_native ~clock (cfg : Config.t) (stats : Stats.t) (live : Live_events.t) (bc : Broadcasts.t) (c : t)
    (p : Protocol.incoming) : bool =
  let dispatch_and_respond ~subid ~(fc : string) (f : Funcall.t) (kwargs : Kw.t) : bool =
    let ctx = { Handlers.cfg; clock; conn_id = c.id; subid } in
    let t0 = Unix.gettimeofday () in
    c.inflight <- c.inflight + 1;
    let outcome =
      Fun.protect
        ~finally:(fun () -> c.inflight <- c.inflight - 1)
        (fun () ->
          if cfg.anon_feed_cache_s > 0.0 && Anon_cache.cacheable f kwargs then
            Anon_cache.lookup ~ttl:cfg.anon_feed_cache_s ~key:(Anon_cache.key f kwargs) ~compute:(fun () -> Funcall.dispatch ctx f kwargs)
          else Funcall.dispatch ctx f kwargs)
    in
    let elapsed = Unix.gettimeofday () -. t0 in
    (match outcome with
    | Response.Handled r ->
        respond c stats ~subid r.messages;
        List.iter
          (fun reg ->
            Live_events.register live ~conn_id:c.id ~subid ~send:c.session.ws_send_text reg;
            Broadcasts.register bc ~conn_id:c.id ~subid ~send:c.session.ws_send_text reg)
          r.registrations;
        Stats.incr stats.handled;
        Wsconnvars.log_request ~funcall:fc ~kwargs ~conn_id:c.id ~subid ~elapsed_s:elapsed;
        if cfg.log_handled then log "handled: %s sub_id=%s %.0fms" fc subid (elapsed *. 1000.)
    | Response.Notice n ->
        respond c stats ~subid ~notices:[ n ] [];
        Stats.incr stats.handled;
        Wsconnvars.log_request ~funcall:fc ~kwargs ~conn_id:c.id ~subid ~elapsed_s:elapsed
    | Response.Not_handled -> ());
    match outcome with Response.Not_handled -> false | _ -> true
  in
  match p with
  | Protocol.Req { subid; funcall = Some "set_primal_protocol"; kwargs; _ } ->
      if Protocol.wants_zlib kwargs then c.use_zlib <- true;
      c.session.ws_send_text (Protocol.eose subid);
      Stats.incr stats.sent;
      Stats.incr stats.handled;
      true
  | Protocol.Req { subid; funcall = Some fc; kwargs; _ } -> (
      match Funcall.of_string fc with Funcall.Proxied s when not (Extensions.has_funcall s) -> false | f -> dispatch_and_respond ~subid ~fc f kwargs)
  | Protocol.Req { subid; funcall = None; raw; _ } -> (
      match filter_funcall raw with
      | `Call (f, kwargs) -> dispatch_and_respond ~subid ~fc:("filter:" ^ Funcall.to_string f) f kwargs
      | `Reject n ->
          (* Julia: NOTICE without EOSE, then close(ws); let the notice reach the wire first *)
          c.session.ws_send_text (Protocol.notice subid n);
          Stats.incr stats.sent;
          Stats.incr stats.handled;
          Eio.Time.sleep clock 0.1;
          request_close c;
          true
      | `None -> false)
  | _ -> false

let run ~net ~clock (cfg : Config.t) (stats : Stats.t) (live : Live_events.t) (bc : Broadcasts.t) (session : Http_server.ws_session) : unit =
  let id = Atomic.fetch_and_add next_id 1 in
  let c =
    { id; session; use_zlib = false; last_msg = Unix.gettimeofday (); backend = None; closing = false; inflight = 0;
      opened_at = Unix.gettimeofday () }
  in
  with_registry (fun () -> Hashtbl.replace registry id c);
  Stats.incr stats.connections;
  Stats.incr stats.accepted;
  let upstream = Config.upstream cfg in
  Fun.protect
    ~finally:(fun () ->
      with_registry (fun () -> Hashtbl.remove registry id);
      Live_events.unregister_conn live ~conn_id:id;
      Broadcasts.unregister_conn bc ~conn_id:id;
      Stats.decr stats.connections;
      (match c.backend with Some b -> (try Ws_client.close b with _ -> ()) | None -> ());
      try session.ws_close () with _ -> ())
    (fun () ->
      Switch.run @@ fun sw ->
      let touch () = c.last_msg <- Unix.gettimeofday () in
      (* Requests of one connection. ws-connector and Julia answer them strictly in order, so one
         slow feed delays everything the page asks for next on that socket (a profile header behind
         a 9 s reads feed). With request_concurrency > 1, REQs run in their own fibers, at most that
         many at once (the semaphore makes the reader wait, so a client cannot queue unbounded work);
         set_primal_protocol (changes how later answers are framed), CLOSE (drops live subscriptions)
         and anything forwarded verbatim stay in order on the reader. Clients key every message by
         subid and wait for its EOSE, so interleaved answers are fine; frames of one answer are
         queued by one fiber, and the upstream socket is written under a mutex. In-flight fibers
         finish after the client loop ends (the switch waits), so a closing connection still gets
         its last answers queued before the socket closes. *)
      let concurrency = max 1 cfg.request_concurrency in
      let slots = Eio.Semaphore.make concurrency in
      let backend_lock = Eio.Mutex.create () in
      (* resolved when the upstream closes: the client connection ends with it, as with ws-connector
         (the client reconnects; subscriptions Julia served are gone with its socket) *)
      let backend_gone, backend_gone_r = Promise.create () in
      let backend_loop backend () =
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
        (try loop () with Eio.Cancel.Cancelled _ as e -> raise e | End_of_file -> () | exn -> log "connection %d: upstream: %s" c.id (Printexc.to_string exn));
        ignore (Promise.try_resolve backend_gone_r ());
        `Stop_daemon
      in
      (* under backend_lock *)
      let connected_backend () : Ws_client.t option =
        match (c.backend, upstream) with
        | (Some _ as b), _ -> b
        | None, None -> None
        | None, Some (tls, host, port, path) -> (
            match
              Eio.Time.with_timeout clock cfg.upstream_connect_timeout_s (fun () ->
                  Ok (Ws_client.connect ~tls ~sw ~net ~clock ~host ~port ~path ()))
            with
            | Ok b ->
                c.backend <- Some b;
                Fiber.fork_daemon ~sw (backend_loop b);
                Some b
            | Error `Timeout ->
                Stats.incr stats.backend_failures;
                log "connection %d: upstream connect timeout" c.id;
                None
            | exception (Eio.Cancel.Cancelled _ as e) -> raise e
            | exception e ->
                Stats.incr stats.backend_failures;
                log "connection %d: upstream connect: %s" c.id (Printexc.to_string e);
                None)
      in
      (* ~connect:false: only over an upstream this connection already opened (a CLOSE of a
         subscription the upstream never saw is not worth a connect) *)
      let send_backend ?(connect = true) (send : Ws_client.t -> unit) : bool =
        Eio.Mutex.use_rw ~protect:true backend_lock (fun () ->
            match if connect then connected_backend () else c.backend with
            | Some b -> send b; Stats.incr stats.proxied; true
            | None -> false)
      in
      let forward s (p : Protocol.incoming) =
        match p with
        | Protocol.Req { subid; funcall; _ } ->
            if not (send_backend (fun b -> Ws_client.send_text b s)) then
              let n = match Option.map Funcall.of_string funcall with Some (Funcall.Proxied _) -> "unknown api request" | _ -> "error" in
              respond c stats ~subid ~notices:[ n ] []
        | _ -> ignore (send_backend ~connect:false (fun b -> Ws_client.send_text b s))
      in
      let handle_parsed s (p : Protocol.incoming) =
        let handled =
          try handle_native ~clock cfg stats live bc c p
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | e ->
              Stats.incr stats.errors;
              log "native handler: %s" (Printexc.to_string e);
              false
        in
        (match p with
        | Protocol.Req { funcall = Some fc; subid; _ } when (not handled) && cfg.log_not_handled ->
            log "not handled: %s sub_id=%s" fc subid
        | _ -> ());
        if not handled then forward s p
      in
      let client_loop () =
        let rec loop () =
          if c.closing then ()
          else
            match session.ws_recv () with
            | `Closed -> ()
            | `Binary b ->
                touch ();
                Stats.incr stats.recv;
                ignore (send_backend ~connect:false (fun be -> Ws_client.send_binary be b));
                loop ()
            | `Text s ->
                touch ();
                Stats.incr stats.recv;
                let p = Protocol.parse s in
                (match p with
                | Protocol.Close subid ->
                    Live_events.unregister_sub live ~conn_id:c.id ~subid;
                    Broadcasts.unregister_sub bc ~conn_id:c.id ~subid
                | _ -> ());
                let in_order =
                  concurrency = 1
                  ||
                  match p with
                  | Protocol.Req { funcall = Some "set_primal_protocol"; _ } | Protocol.Close _ | Protocol.Other _ -> true
                  | Protocol.Req { funcall = Some fc; kwargs; _ } ->
                      (* a fresh anonymous-feed cache entry is answered inline: no slot, no wait behind the burst *)
                      cfg.anon_feed_cache_s > 0.0
                      && (match Funcall.of_string fc with f when Anon_cache.cacheable f kwargs -> Anon_cache.fresh (Anon_cache.key f kwargs) | _ -> false)
                  | Protocol.Req _ -> false
                in
                if in_order then handle_parsed s p
                else begin
                  Eio.Semaphore.acquire slots;
                  Fiber.fork ~sw (fun () ->
                      Fun.protect
                        ~finally:(fun () -> Eio.Semaphore.release slots)
                        (fun () ->
                          try handle_parsed s p
                          with
                          | Eio.Cancel.Cancelled _ as e -> raise e
                          | exn ->
                              Stats.incr stats.errors;
                              log "connection %d: %s" c.id (Printexc.to_string exn);
                              request_close c))
                end;
                loop ()
        in
        loop ()
      in
      (* ws-connector: every 3 s, close when idle for >= (0.95..1.0) * idle_timeout (the timeout
         itself comes from wsconnvars, re-read each tick). *)
      let idle_loop () =
        let rfactor = 0.95 +. Random.float 0.05 in
        let rec loop () =
          Eio.Time.sleep clock 3.0;
          if c.closing || session.ws_is_closed () then ()
          else
            let limit = rfactor *. Wsconnvars.idle_connection_timeout_s () in
            let dt = Unix.gettimeofday () -. c.last_msg in
            if dt >= limit then begin
              Stats.incr stats.idle_closed;
              log "closing idle connection %d (%s), last message %.0fs ago" c.id session.ws_peer dt
            end
            else loop ()
        in
        loop ()
      in
      (try Fiber.any [ client_loop; (fun () -> Promise.await backend_gone); idle_loop ]
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | End_of_file -> ()
       | exn ->
           Stats.incr stats.errors;
           log "connection %d: %s" c.id (Printexc.to_string exn));
      c.closing <- true)
