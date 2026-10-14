(* The API daemon: the public WebSocket port served from N domains (one accept
   loop each on a shared SO_REUSEPORT socket), the internal/moderation HTTP ports, admin
   HTTP on 127.0.0.1, rolling-restart drain. bin/primal_apid.ml and the private
   ocaml-ext/bin call [run]; the latter registers its extensions in [init]. *)

open Eio.Std

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [primal-api] %s\n%!" (Procinfo.timestamp ()) s) fmt

let usage () =
  prerr_endline "usage: primal_apid <config.json>\n       primal_apid --check-config <config.json>   parse the config (and run the extensions' init), then exit";
  exit 2

(* [init] runs after the config is parsed and before anything listens: the private extensions
   register their funcalls, routes, kinds there. *)
let run ~(argv : string array) ?(init : Config.t -> unit = fun _ -> ()) () : unit =
  let cfg_path, check_only = match argv with [| _; "--check-config"; p |] -> (p, true) | [| _; p |] -> (p, false) | _ -> usage () in
  let cfg =
    try
      let c = Config.of_json_file cfg_path in
      Replicate.configure c.replicate_to;
      c
    with Config.Config_error m ->
      prerr_endline ("primal-api: config error: " ^ m);
      exit 2
  in
  (try init cfg with exn -> prerr_endline ("primal-api: extension init failed: " ^ Printexc.to_string exn); exit 2);
  if check_only then (print_endline ("primal-api: config ok: " ^ cfg_path); exit 0);
  Random.self_init ();
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  Switch.run @@ fun sw ->
  let lifecycle = Lifecycle.create ~sw ~clock () in
  let stop = Lifecycle.stop lifecycle in
  let stats = Stats.create () in
  log "pid %d: config %s, servername %s" (Unix.getpid ()) cfg_path cfg.servername;

  (* The public WebSocket service: any GET with an Upgrade header becomes a Conn session; a plain
     GET (health probes, browsers) gets a text banner like HTTP.jl did. *)
  let is_upgrade (r : Http_server.req) =
    match Http_server.req_header r "upgrade" with
    | Some u -> String.lowercase_ascii u = "websocket"
    | None -> false
  in
  let live = Live_events.create () in
  let bc = Broadcasts.create () in
  Handlers.net_ref := Some net;
  Wsconnvars.open_request_log cfg.request_log;
  let init_domain_db () =
    Db.init ~cache_db:cfg.cache_db ~membership_db:cfg.membership_db ~cache_size:cfg.cache_pool_size
      ~membership_size:cfg.membership_pool_size
  in
  let ws_handler (r : Http_server.req) : Http_server.resp =
    if is_upgrade r then Http_server.Ws (None, fun session -> Conn.run ~clock cfg stats live bc session)
    else Http_server.Text (200, "Primal cache API Websocket endpoint\n")
  in
  let public_svc =
    {
      (Http_server.default_service "ws"
         [
           { meth = `GET; pattern = []; handler = ws_handler };
           { meth = `GET; pattern = [ Rest "path" ]; handler = ws_handler };
         ])
      with
      ws_limits =
        {
          Http_server.max_message_bytes = cfg.ws_max_message_bytes;
          outbound_queue = cfg.ws_outbound_queue;
          send_stall_s = cfg.ws_send_stall_s;
        };
    }
  in
  let public_fd = Listen.bind ~host:cfg.public_ws_host ~port:cfg.public_ws_port () in
  let cache_fd = Option.map (fun p -> Listen.bind ~host:cfg.public_ws_host ~port:p ()) cfg.cache_ws_port in
  let admin_fd = Listen.bind ~host:cfg.admin_host ~port:cfg.admin_port () in
  let internal_fd = Listen.bind ~host:cfg.public_ws_host ~port:cfg.internal_http_port () in
  let internal_svc = Internal_http.service ~cfg ~clock in
  let moderation_fd = Listen.bind ~host:cfg.public_ws_host ~port:cfg.moderation_http_port () in
  let moderation_svc = Moderation_http.service ~cfg ~clock in
  log "listening: ws %s:%d%s (%d domains), internal http :%d, moderation http :%d, admin %s:%d" cfg.public_ws_host cfg.public_ws_port
    (match cfg.cache_ws_port with Some p -> Printf.sprintf " + cache ws :%d" p | None -> "") cfg.num_domains cfg.internal_http_port cfg.moderation_http_port cfg.admin_host cfg.admin_port;
  let admin_svc = Admin.service ~lifecycle ~stats ~cfg ~live ~bc in

  (* Worker domains: each imports the shared listening fd and runs its own accept loop. *)
  let worker i () =
    Eio.Domain_manager.run domain_mgr (fun () ->
        Switch.run @@ fun dsw ->
        Phases.register_domain_slot (Printf.sprintf "d%d" i);
        Mirage_crypto_rng_unix.use_default ();
        Postgres.set_env ~net ~sw:dsw;
        init_domain_db ();
        let sock = Listen.import ~sw:dsw public_fd in
        let isock = Listen.import ~sw:dsw internal_fd in
        let csock = Option.map (Listen.import ~sw:dsw) cache_fd in
        Fiber.all
          ([ (fun () -> Http_server.serve_on ~sw:dsw ~clock ~stop public_svc sock; Eio.Net.close sock);
             (fun () -> Http_server.serve_on ~sw:dsw ~clock ~stop internal_svc isock; Eio.Net.close isock) ]
          @ (match csock with Some c -> [ (fun () -> Http_server.serve_on ~sw:dsw ~clock ~stop public_svc c; Eio.Net.close c) ] | None -> [])))
  in
  let main_domain () =
    Switch.run @@ fun msw ->
    Postgres.set_env ~net ~sw:msw;
    init_domain_db ();
    let sock = Listen.import ~sw:msw public_fd in
    let csock = Option.map (Listen.import ~sw:msw) cache_fd in
    let admin_sock = Listen.import ~sw:msw admin_fd in
    let isock = Listen.import ~sw:msw internal_fd in
    let modsock = Listen.import ~sw:msw moderation_fd in
    Fiber.fork_daemon ~sw:msw (fun () ->
        Wsconnvars.run ~clock ~period:cfg.wsconnvars_poll_s ~default_idle_s:cfg.idle_connection_timeout_s;
        `Stop_daemon);
    if cfg.live_events_enabled then
      Fiber.fork_daemon ~sw:msw (fun () ->
          Live_events.run live ~net ~clock ~stats cfg.cache_db;
          `Stop_daemon);
    if cfg.replicate_to <> [] then
      Fiber.fork_daemon ~sw:msw (fun () ->
          Replicate.run ~net ~clock ();
          `Stop_daemon);
    Fiber.fork_daemon ~sw:msw (fun () ->
        Broadcasts.run bc ~net ~clock ~cfg;
        `Stop_daemon);
    Fiber.fork_daemon ~sw:msw (fun () ->
        if cfg.status_interval_s > 0. then Stats.report_loop ~clock ~interval:cfg.status_interval_s stats;
        `Stop_daemon);
    (match cfg.pushgateway with
    | Some (host, port, job, period) ->
        Fiber.fork_daemon ~sw:msw (fun () ->
            Stats.push_loop ~net ~clock ~period ~host ~port ~job ~active:(fun () -> not (Promise.is_resolved stop)) stats;
            `Stop_daemon)
    | None -> ());
    Lifecycle.serving lifecycle;
    Fiber.all
      ([
         (fun () -> Http_server.serve_on ~sw:msw ~clock ~stop public_svc sock; Eio.Net.close sock);
         (fun () -> Http_server.serve_on ~sw:msw ~clock ~stop internal_svc isock; Eio.Net.close isock);
         (fun () -> Http_server.serve_on ~sw:msw ~clock ~stop moderation_svc modsock; Eio.Net.close modsock);
         (fun () -> Http_server.serve_on ~sw:msw ~clock ~stop admin_svc admin_sock);
       ]
      @ (match csock with Some c -> [ (fun () -> Http_server.serve_on ~sw:msw ~clock ~stop public_svc c; Eio.Net.close c) ] | None -> []))
  in
  (* Drain controller: runs CONCURRENTLY with the accept loops (their switches keep the connection
     fibers alive, so waiting for Fiber.all below would wait for every client to leave on its own).
     On stop: the listening socket is closed in every domain (serve_on returns, the dup and the
     bound fd are closed, so the kernel stops routing new connections here), idle WebSockets go
     now, active ones after the grace period, everything by the hard deadline; then the process
     exits. *)
  Fiber.fork_daemon ~sw (fun () ->
      Promise.await stop;
      (* the bound fd itself: with every domain's dup closed the socket leaves the kernel's
         SO_REUSEPORT group and new connections only reach the new generation *)
      (try Unix.close public_fd with _ -> ());
      (match cache_fd with Some fd -> (try Unix.close fd with _ -> ()) | None -> ());
      (try Unix.close internal_fd with _ -> ());
      (try Unix.close moderation_fd with _ -> ());
      log "draining: %d connections, %d http inflight" (Conn.count ()) (Http_server.inflight_connections ());
      let idle = Conn.close_idle ~older_than:30.0 () in
      if idle > 0 then log "closed %d idle connections" idle;
      let left = Lifecycle.wait_drained ~clock ~grace:cfg.drain_grace_s Http_server.inflight_connections in
      if left > 0 then begin
        log "grace over, closing %d remaining connections" (Conn.close_all ());
        ignore (Lifecycle.wait_drained ~clock ~grace:cfg.drain_ws_max_s Http_server.inflight_connections)
      end;
      Lifecycle.stopped lifecycle;
      log "exiting (%d connections remaining)" (Http_server.inflight_connections ());
      exit 0);
  Fiber.all (main_domain :: List.init (max 0 (cfg.num_domains - 1)) (fun i -> worker (i + 1)));
  (* Every listener and connection finished on its own (e.g. a drain with no clients). *)
  Lifecycle.stopped lifecycle;
  log "exiting (all connections finished)";
  exit 0
