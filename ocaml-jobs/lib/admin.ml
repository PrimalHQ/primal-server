(* Admin HTTP on 127.0.0.1: health, readiness and a status page listing the roles. *)

open Http_server

let service ~(lifecycle : Lifecycle.t) ~(cfg : Config.t) : Http_server.service =
  let status () =
    `Assoc
      [ ("pid", `Int (Unix.getpid ())); ("state", `String (Lifecycle.string_of_state (Lifecycle.state lifecycle))); ("uptime_s", `Float (Lifecycle.uptime lifecycle));
        ("roles", `List (List.map (fun r -> `String (Config.string_of_role r)) cfg.roles)); ("rss_bytes", `Int (Procinfo.read_rss_bytes ())) ]
  in
  default_service "admin"
    [
      { meth = `GET; pattern = [ Lit "healthz" ]; handler = (fun _ -> Text (200, "ok")) };
      { meth = `GET; pattern = [ Lit "readyz" ]; handler = (fun _ -> if Lifecycle.is_ready lifecycle then Text (200, "ready") else Text (503, Lifecycle.string_of_state (Lifecycle.state lifecycle))) };
      { meth = `GET; pattern = [ Lit "status" ]; handler = (fun _ -> Json (200, status ())) };
      { meth = `GET; pattern = [ Lit "tasks" ]; handler = (fun _ -> Text (200, Phases.report ())) };
      { meth = `POST; pattern = [ Lit "stop" ]; handler = (fun _ -> Lifecycle.request_drain ~reason:"admin POST /stop" lifecycle; Text (200, "stopping")) };
    ]
