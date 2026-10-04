(* primal-api: the Primal cache API daemon (ocaml-plan.md §5). Phase 2 skeleton: the public
   WebSocket port served from N domains (one accept loop each on a shared SO_REUSEPORT socket),
   `set_primal_protocol` / `server_name` answered natively and everything else proxied frame for
   frame to the Julia CacheServer; admin HTTP on 127.0.0.1; rolling-restart drain (§6). *)

open Eio.Std
module Api = Primal_api

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [primal-api] %s\n%!" (Procinfo.timestamp ()) s) fmt

let usage () =
  prerr_endline "usage: primal_apid <config.json>";
  exit 2

let () =
  let cfg_path = match Sys.argv with [| _; p |] -> p | _ -> usage () in
  let cfg =
    try Api.Config.of_json_file cfg_path
    with Api.Config.Config_error m ->
      prerr_endline ("primal-api: config error: " ^ m);
      exit 2
  in
  Random.self_init ();
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  Switch.run @@ fun sw ->
  let lifecycle = Lifecycle.create ~sw ~clock () in
  let stop = Lifecycle.stop lifecycle in
  let stats = Api.Stats.create () in
  log "pid %d: config %s, servername %s, upstream %s" (Unix.getpid ()) cfg_path cfg.servername
    cfg.upstream_julia_ws;

  (* The public WebSocket service: any GET with an Upgrade header becomes a Conn session; a plain
     GET (health probes, browsers) gets a text banner like HTTP.jl did. *)
  let is_upgrade (r : Http_server.req) =
    match Http_server.req_header r "upgrade" with
    | Some u -> String.lowercase_ascii u = "websocket"
    | None -> false
  in
  let live = Api.Live_events.create () in
  let bc = Api.Broadcasts.create () in
  Api.Handlers.net_ref := Some net;
  Api.Wsconnvars.open_request_log cfg.request_log;
  let init_domain_db () =
    Db.init ~cache_db:cfg.cache_db ~membership_db:cfg.membership_db ~cache_size:cfg.cache_pool_size
      ~membership_size:cfg.membership_pool_size
  in
  let ws_handler (r : Http_server.req) : Http_server.resp =
    if is_upgrade r then Http_server.Ws (None, fun session -> Api.Conn.run ~net ~clock cfg stats live bc session)
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
  let admin_fd = Listen.bind ~host:cfg.admin_host ~port:cfg.admin_port () in
  let internal_fd = Listen.bind ~host:cfg.public_ws_host ~port:cfg.internal_http_port () in
  let internal_svc = Api.Internal_http.service ~cfg ~clock in
  log "listening: ws %s:%d (%d domains), internal http :%d, admin %s:%d" cfg.public_ws_host cfg.public_ws_port
    cfg.num_domains cfg.internal_http_port cfg.admin_host cfg.admin_port;
  let admin_svc = Api.Admin.service ~lifecycle ~stats ~cfg ~live ~bc in

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
        Fiber.both
          (fun () -> Http_server.serve_on ~sw:dsw ~clock ~stop public_svc sock; Eio.Net.close sock)
          (fun () -> Http_server.serve_on ~sw:dsw ~clock ~stop internal_svc isock; Eio.Net.close isock))
  in
  let main_domain () =
    Switch.run @@ fun msw ->
    Postgres.set_env ~net ~sw:msw;
    init_domain_db ();
    let sock = Listen.import ~sw:msw public_fd in
    let admin_sock = Listen.import ~sw:msw admin_fd in
    let isock = Listen.import ~sw:msw internal_fd in
    Fiber.fork_daemon ~sw:msw (fun () ->
        Api.Wsconnvars.run ~clock ~period:cfg.wsconnvars_poll_s ~default_idle_s:cfg.idle_connection_timeout_s;
        `Stop_daemon);
    if cfg.live_events_enabled then
      Fiber.fork_daemon ~sw:msw (fun () ->
          Api.Live_events.run live ~net ~clock ~stats cfg.cache_db;
          `Stop_daemon);
    Fiber.fork_daemon ~sw:msw (fun () ->
        Api.Broadcasts.run bc ~net ~clock ~network_stats_url:cfg.network_stats_url ~netstats_period:cfg.netstats_period_s;
        `Stop_daemon);
    Fiber.fork_daemon ~sw:msw (fun () ->
        if cfg.status_interval_s > 0. then Api.Stats.report_loop ~clock ~interval:cfg.status_interval_s stats;
        `Stop_daemon);
    Lifecycle.serving lifecycle;
    Fiber.all
      [
        (fun () -> Http_server.serve_on ~sw:msw ~clock ~stop public_svc sock; Eio.Net.close sock);
        (fun () -> Http_server.serve_on ~sw:msw ~clock ~stop internal_svc isock; Eio.Net.close isock);
        (fun () -> Http_server.serve_on ~sw:msw ~clock ~stop admin_svc admin_sock);
      ]
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
      (try Unix.close internal_fd with _ -> ());
      log "draining: %d connections, %d http inflight" (Api.Conn.count ()) (Http_server.inflight_connections ());
      let idle = Api.Conn.close_idle ~older_than:30.0 () in
      if idle > 0 then log "closed %d idle connections" idle;
      let left = Lifecycle.wait_drained ~clock ~grace:cfg.drain_grace_s Http_server.inflight_connections in
      if left > 0 then begin
        log "grace over, closing %d remaining connections" (Api.Conn.close_all ());
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
