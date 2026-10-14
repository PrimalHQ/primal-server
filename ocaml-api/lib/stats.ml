(* primal-api counters (cross-domain atomics) and the periodic status line, in the spirit of
   ws-connector's per-second stderr line: connections, received, sent, handled. *)

type t = {
  connections : int Atomic.t; (* open client WebSockets (gauge) *)
  accepted : int Atomic.t; (* client WebSockets accepted since start *)
  recv : int Atomic.t; (* client frames received *)
  sent : int Atomic.t; (* frames sent to clients *)
  handled : int Atomic.t; (* requests answered (not counting the NOTICEs for unhandled ones) *)
  idle_closed : int Atomic.t;
  live_events : int Atomic.t; (* events run through the live-event distributor *)
  errors : int Atomic.t;
  requests : int Atomic.t; (* requests answered natively since the last pushgateway push *)
  max_request_us : int Atomic.t; (* their longest duration (µs), reset by the push *)
}

let create () =
  {
    connections = Atomic.make 0; accepted = Atomic.make 0; recv = Atomic.make 0; sent = Atomic.make 0;
    handled = Atomic.make 0; idle_closed = Atomic.make 0; live_events = Atomic.make 0;
    errors = Atomic.make 0; requests = Atomic.make 0; max_request_us = Atomic.make 0;
  }

let incr = Atomic.incr
let decr = Atomic.decr
let get = Atomic.get

(* One request answered natively in [elapsed_s]: counted, and the period's maximum raised. *)
let record_request (t : t) (elapsed_s : float) : unit =
  Atomic.incr t.requests;
  let us = int_of_float (elapsed_s *. 1e6) in
  let rec raise_max () =
    let cur = Atomic.get t.max_request_us in
    if us > cur && not (Atomic.compare_and_set t.max_request_us cur us) then raise_max ()
  in
  raise_max ()

(* Prometheus text exposition for the admin /metrics endpoint. *)
let metrics_text ?(extra = []) (t : t) : string =
  let b = Buffer.create 1024 in
  let m name typ v = Buffer.add_string b (Printf.sprintf "# TYPE %s %s\n%s %d\n" name typ name v) in
  m "primal_api_connections" "gauge" (get t.connections);
  m "primal_api_accepted_total" "counter" (get t.accepted);
  m "primal_api_recv_total" "counter" (get t.recv);
  m "primal_api_sent_total" "counter" (get t.sent);
  m "primal_api_handled_total" "counter" (get t.handled);
  m "primal_api_idle_closed_total" "counter" (get t.idle_closed);
  m "primal_api_live_events_total" "counter" (get t.live_events);
  m "primal_api_errors_total" "counter" (get t.errors);
  m "primal_api_rss_bytes" "gauge" (Procinfo.read_rss_bytes ());
  List.iter (fun (name, typ, v) -> m name typ v) extra;
  Buffer.contents b

(* One line every [interval] seconds: gauges plus per-interval deltas of the counters. *)
let report_loop ~clock ~(interval : float) (t : t) : unit =
  let start = Eio.Time.now clock in
  let p_recv = ref 0 and p_sent = ref 0 and p_handled = ref 0 in
  while true do
    Eio.Time.sleep clock interval;
    let d r cur = let v = cur - !r in r := cur; v in
    let uptime = int_of_float (Eio.Time.now clock -. start) in
    Printf.printf
      "[api %s up %s] conns %d | recv %d sent %d handled %d (last %.0fs) | accepted %d idle-closed %d err %d | rss %s heap %s%s\n%!"
      (Procinfo.timestamp ()) (Procinfo.fmt_hms uptime) (get t.connections) (d p_recv (get t.recv))
      (d p_sent (get t.sent)) (d p_handled (get t.handled)) interval (get t.accepted) (get t.idle_closed)
      (get t.errors)
      (Procinfo.fmt_bytes (Procinfo.read_rss_bytes ()))
      (Procinfo.fmt_bytes (Procinfo.heap_bytes ()))
      (Phases.stuck_summary ~min_age:30.0 ())
  done

(* Every [period] seconds, push the request metrics under the Julia cache nodes' names
   (PushGatewayExporter in cache_server_handlers_ext.jl): cache_max_request_duration (s, the
   period's longest request) and cache_requests_per_second, then reset both. Typed counter, as
   Julia's set! did: the pushgateway
   rejects a name whose type differs from the other jobs' series. A generation that is draining ([active] false) stops
   pushing, so it doesn't overwrite the serving generation's values. Push failures are logged. *)
let push_loop ~net ~clock ~(period : float) ~host ~port ~job ~(active : unit -> bool) (t : t) : unit =
  while active () do
    Eio.Time.sleep clock period;
    let n = Atomic.exchange t.requests 0 and max_us = Atomic.exchange t.max_request_us 0 in
    if active () then
      try
        Pushgateway.set_values ~net ~clock ~host ~port ~job
          [
            ("cache_max_request_duration", "counter", Printf.sprintf "%.6f" (float_of_int max_us /. 1e6));
            ("cache_requests_per_second", "counter", Printf.sprintf "%.3f" (float_of_int n /. period));
          ]
      with exn -> Printf.printf "[api] pushgateway %s:%d: %s\n%!" host port (Printexc.to_string exn)
  done
