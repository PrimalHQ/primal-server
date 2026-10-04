(* Admin HTTP on 127.0.0.1: health, readiness, a status page with the Fetching.mon numbers
   (providing|waiting|total relays, per-second rates) and the dedup/firehose counters. *)

open Http_server

let service ~(lifecycle : Lifecycle.t) ~(cfg : Config.t) ~(stats : Stats.t) ~(dedup : Dedup.t) ~(firehose : Firehose.t) ~(relays : Relay_set.t) : Http_server.service =
  let prev = ref (Unix.gettimeofday (), Atomic.get stats.message_count, Atomic.get stats.any, Atomic.get stats.chars_received) in
  let status () =
    let now = Unix.gettimeofday () in
    let pt, pm, pa, pc = !prev in
    let dt = Float.max 0.001 (now -. pt) in
    let m = Atomic.get stats.message_count and a = Atomic.get stats.any and c = Atomic.get stats.chars_received in
    prev := (now, m, a, c);
    `Assoc
      [ ("pid", `Int (Unix.getpid ())); ("state", `String (Lifecycle.string_of_state (Lifecycle.state lifecycle))); ("uptime_s", `Float (Lifecycle.uptime lifecycle)); ("node_idx", `Int cfg.node_idx);
        ("relays", `Assoc [ ("total", `Int (Atomic.get stats.relays_total)); ("connected", `Int (Atomic.get stats.relays_connected)); ("waiting", `Int (Atomic.get stats.relays_waiting)); ("providing", `Int (Atomic.get stats.relays_providing)) ]);
        ("rates_since_last_status", `Assoc [ ("messages_per_s", `Float (float_of_int (m - pm) /. dt)); ("new_events_per_s", `Float (float_of_int (a - pa) /. dt)); ("chars_received_per_s", `Float (float_of_int (c - pc) /. dt)) ]);
        ("counters", Stats.to_json stats); ("dedup_size", `Int (Dedup.size dedup)); ("firehose_subscribers", `Int (Firehose.subscribers firehose)); ("rss_bytes", `Int (Procinfo.read_rss_bytes ())); ("heap_bytes", `Int (Procinfo.heap_bytes ())) ]
  in
  let relays_page () =
    let cs = List.sort (fun (a : Relay_conn.t) b -> compare b.message_count a.message_count) (Relay_set.conns relays) in
    `List (List.map (fun (c : Relay_conn.t) -> `Assoc [ ("url", `String c.url); ("connected", `Bool c.connected); ("waiting", `Bool c.waiting_delay); ("delay", `Float c.delay); ("messages", `Int c.message_count); ("exceptions", `Int c.exception_count); ("since", `Int c.since); ("last_exception", `String c.last_exception) ]) cs)
  in
  default_service "admin"
    [
      { meth = `GET; pattern = [ Lit "healthz" ]; handler = (fun _ -> Text (200, "ok")) };
      { meth = `GET; pattern = [ Lit "readyz" ]; handler = (fun _ -> if Lifecycle.is_ready lifecycle then Text (200, "ready") else Text (503, Lifecycle.string_of_state (Lifecycle.state lifecycle))) };
      { meth = `GET; pattern = [ Lit "status" ]; handler = (fun _ -> Json (200, status ())) };
      { meth = `GET; pattern = [ Lit "relays" ]; handler = (fun _ -> Json (200, relays_page ())) };
      { meth = `GET; pattern = [ Lit "tasks" ]; handler = (fun _ -> Text (200, Phases.report ())) };
      { meth = `POST; pattern = [ Lit "gc" ]; handler = (fun _ -> let before = Procinfo.heap_bytes () in Gc.compact (); Json (200, `Assoc [ ("heap_before", `Int before); ("heap_after", `Int (Procinfo.heap_bytes ())); ("rss_after", `Int (Procinfo.read_rss_bytes ())) ])) };
      { meth = `POST; pattern = [ Lit "stop" ]; handler = (fun _ -> Lifecycle.request_drain ~reason:"admin POST /stop" lifecycle; Text (200, "stopping")) };
    ]
