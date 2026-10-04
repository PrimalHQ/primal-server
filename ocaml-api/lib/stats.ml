(* primal-api counters (cross-domain atomics) and the periodic status line, in the spirit of
   ws-connector's per-second stderr line: connections, received, sent, proxied, handled. *)

type t = {
  connections : int Atomic.t; (* open client WebSockets (gauge) *)
  accepted : int Atomic.t; (* client WebSockets accepted since start *)
  recv : int Atomic.t; (* client frames received *)
  sent : int Atomic.t; (* frames sent to clients (native + proxied) *)
  handled : int Atomic.t; (* requests answered natively *)
  proxied : int Atomic.t; (* client frames forwarded to the upstream *)
  backend_frames : int Atomic.t; (* upstream frames relayed to clients *)
  backend_failures : int Atomic.t; (* upstream connects that failed *)
  idle_closed : int Atomic.t;
  live_events : int Atomic.t; (* events run through the live-event distributor *)
  errors : int Atomic.t;
}

let create () =
  {
    connections = Atomic.make 0; accepted = Atomic.make 0; recv = Atomic.make 0; sent = Atomic.make 0;
    handled = Atomic.make 0; proxied = Atomic.make 0; backend_frames = Atomic.make 0;
    backend_failures = Atomic.make 0; idle_closed = Atomic.make 0; live_events = Atomic.make 0;
    errors = Atomic.make 0;
  }

let incr = Atomic.incr
let decr = Atomic.decr
let get = Atomic.get

(* Prometheus text exposition for the admin /metrics endpoint. *)
let metrics_text ?(extra = []) (t : t) : string =
  let b = Buffer.create 1024 in
  let m name typ v = Buffer.add_string b (Printf.sprintf "# TYPE %s %s\n%s %d\n" name typ name v) in
  m "primal_api_connections" "gauge" (get t.connections);
  m "primal_api_accepted_total" "counter" (get t.accepted);
  m "primal_api_recv_total" "counter" (get t.recv);
  m "primal_api_sent_total" "counter" (get t.sent);
  m "primal_api_handled_total" "counter" (get t.handled);
  m "primal_api_proxied_total" "counter" (get t.proxied);
  m "primal_api_backend_frames_total" "counter" (get t.backend_frames);
  m "primal_api_backend_failures_total" "counter" (get t.backend_failures);
  m "primal_api_idle_closed_total" "counter" (get t.idle_closed);
  m "primal_api_live_events_total" "counter" (get t.live_events);
  m "primal_api_errors_total" "counter" (get t.errors);
  m "primal_api_rss_bytes" "gauge" (Procinfo.read_rss_bytes ());
  List.iter (fun (name, typ, v) -> m name typ v) extra;
  Buffer.contents b

(* One line every [interval] seconds: gauges plus per-interval deltas of the counters. *)
let report_loop ~clock ~(interval : float) (t : t) : unit =
  let start = Eio.Time.now clock in
  let p_recv = ref 0 and p_sent = ref 0 and p_handled = ref 0 and p_proxied = ref 0 and p_bf = ref 0 in
  while true do
    Eio.Time.sleep clock interval;
    let d r cur = let v = cur - !r in r := cur; v in
    let uptime = int_of_float (Eio.Time.now clock -. start) in
    Printf.printf
      "[api %s up %s] conns %d | recv %d sent %d handled %d proxied %d backend %d (last %.0fs) | accepted %d idle-closed %d bfail %d err %d | rss %s heap %s%s\n%!"
      (Procinfo.timestamp ()) (Procinfo.fmt_hms uptime) (get t.connections) (d p_recv (get t.recv))
      (d p_sent (get t.sent)) (d p_handled (get t.handled)) (d p_proxied (get t.proxied))
      (d p_bf (get t.backend_frames)) interval (get t.accepted) (get t.idle_closed)
      (get t.backend_failures) (get t.errors)
      (Procinfo.fmt_bytes (Procinfo.read_rss_bytes ()))
      (Procinfo.fmt_bytes (Procinfo.heap_bytes ()))
      (Phases.stuck_summary ~min_age:30.0 ())
  done
