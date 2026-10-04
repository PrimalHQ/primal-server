(* Admin HTTP on 127.0.0.1 (ocaml-plan.md §5.6): health/readiness for the load balancer and the
   restart script, the fiber phase registry (the pgwire `tasks` replacement), Prometheus metrics,
   and a programmatic drain. *)

open Http_server

let service ~(lifecycle : Lifecycle.t) ~(stats : Stats.t) ~(cfg : Config.t) ~(live : Live_events.t) : Http_server.service =
  let status_json () =
    `Assoc
      [
        ("pid", `Int (Unix.getpid ()));
        ("state", `String (Lifecycle.string_of_state (Lifecycle.state lifecycle)));
        ("uptime_s", `Float (Lifecycle.uptime lifecycle));
        ("servername", `String cfg.servername);
        ("public_ws_port", `Int cfg.public_ws_port);
        ("upstream", `String cfg.upstream_julia_ws);
        ("connections", `Int (Conn.count ()));
        ( "live_subscriptions",
          let a, f, c = Live_events.stats live in
          `Assoc [ ("addresses", `Int a); ("follows_users", `Int f); ("connections", `Int c) ] );
        ("inflight_http", `Int (Http_server.inflight_connections ()));
        ("rss_bytes", `Int (Procinfo.read_rss_bytes ()));
      ]
  in
  let routes =
    [
      { meth = `GET; pattern = [ Lit "healthz" ]; handler = (fun _ -> Text (200, "ok")) };
      {
        meth = `GET;
        pattern = [ Lit "readyz" ];
        handler =
          (fun _ ->
            if Lifecycle.is_ready lifecycle then Text (200, "ready")
            else Text (503, Lifecycle.string_of_state (Lifecycle.state lifecycle)));
      };
      { meth = `GET; pattern = [ Lit "status" ]; handler = (fun _ -> Json (200, status_json ())) };
      { meth = `GET; pattern = [ Lit "tasks" ]; handler = (fun _ -> Text (200, Phases.report ())) };
      {
        meth = `GET;
        pattern = [ Lit "metrics" ];
        handler =
          (fun _ ->
            let extra =
              [
                ("primal_api_ready", "gauge", if Lifecycle.is_ready lifecycle then 1 else 0);
                ("primal_api_inflight_http", "gauge", Http_server.inflight_connections ());
              ]
            in
            Text (200, Stats.metrics_text ~extra stats));
      };
      {
        meth = `POST;
        pattern = [ Lit "drain" ];
        handler =
          (fun _ ->
            Lifecycle.request_drain ~reason:"admin POST /drain" lifecycle;
            Text (200, "draining"));
      };
    ]
  in
  { (Http_server.default_service "admin" routes) with error_style = Plain_text }
