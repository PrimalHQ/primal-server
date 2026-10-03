(* In-memory counters for the importer, sampled once per second by a reporter fiber and logged as
   a single line (see [report_loop], wired in bin/main.ml).

   Every counter is cumulative and incremented from the worker domains, so they are [Atomic.t]:
   OCaml 5 atomics give cross-domain visibility, where plain refs would race. The reporter runs on
   the main domain and only reads them.

   The fiber phase-slot registry and the process-level helpers (RSS, formatting) moved to
   primal_common (Phases, Procinfo) in Phase 0; the aliases below keep the importer's call sites
   (Stats.phase, Stats.new_slot, ...) unchanged. *)

type t = {
  recv : int Atomic.t;       (* firehose lines received *)
  submitted : int Atomic.t;  (* enqueued onto the worker queue *)
  started : int Atomic.t;    (* dequeued by a worker, processing begun *)
  completed : int Atomic.t;  (* processing finished (any outcome, incl. error) *)
  imported : int Atomic.t;   (* newly stored events *)
  duplicate : int Atomic.t;  (* lost the atomic store_event claim (already imported) *)
  rejected : int Atomic.t;   (* refused before storage (verify/kind/deleted/ext/parse) *)
  errors : int Atomic.t;     (* exceptions while processing a message *)
  reconnects : int Atomic.t; (* firehose disconnect/reconnect cycles *)
  lnurl_ok : int Atomic.t;      (* LNURL zapper-verification fetches that returned a body *)
  lnurl_fail : int Atomic.t;    (* ... that failed fast (DNS/connect/TLS/HTTP error) *)
  lnurl_timeout : int Atomic.t; (* ... that hit the request deadline *)
  (* Zap-receipt verification outcomes. A zap whose zapper cannot be verified is never counted
     (no og_zap_receipts row, no satszapped, no notification), so these are the only visibility
     into silently-uncounted zaps. *)
  zap_ok : int Atomic.t;         (* verified: import effects applied *)
  zap_retry : int Atomic.t;      (* deferred (no metadata / fetch failure) and requeued *)
  zap_unverified : int Atomic.t; (* endpoint answered but disowned the receipt author: final *)
  zap_dropped : int Atomic.t;    (* given up on: retries exhausted, or queue/retry list full *)
  push_sent : int Atomic.t;     (* device push notifications delivered (per sender responses) *)
  push_latest : int Atomic.t;   (* unix time of the last completed send op (0 = never) *)
  qwait_max_ms : int Atomic.t;  (* max queue wait (submit -> dequeue) seen since last report *)
}

let create () =
  {
    recv = Atomic.make 0;
    submitted = Atomic.make 0;
    started = Atomic.make 0;
    completed = Atomic.make 0;
    imported = Atomic.make 0;
    duplicate = Atomic.make 0;
    rejected = Atomic.make 0;
    errors = Atomic.make 0;
    reconnects = Atomic.make 0;
    lnurl_ok = Atomic.make 0;
    lnurl_fail = Atomic.make 0;
    lnurl_timeout = Atomic.make 0;
    zap_ok = Atomic.make 0;
    zap_retry = Atomic.make 0;
    zap_unverified = Atomic.make 0;
    zap_dropped = Atomic.make 0;
    push_sent = Atomic.make 0;
    push_latest = Atomic.make 0;
    qwait_max_ms = Atomic.make 0;
  }

(* Named per-counter bumps so callers never touch the record fields directly (keeps field labels
   in scope only here). Each is called from the hot path / reader fiber. *)
let recv t = Atomic.incr t.recv
let submitted t = Atomic.incr t.submitted
let started t = Atomic.incr t.started
let completed t = Atomic.incr t.completed
let imported t = Atomic.incr t.imported
let duplicate t = Atomic.incr t.duplicate
let rejected t = Atomic.incr t.rejected
let errors t = Atomic.incr t.errors
let reconnects t = Atomic.incr t.reconnects
let lnurl_ok t = Atomic.incr t.lnurl_ok
let lnurl_fail t = Atomic.incr t.lnurl_fail
let lnurl_timeout t = Atomic.incr t.lnurl_timeout
let zap_ok t = Atomic.incr t.zap_ok
let zap_retry t = Atomic.incr t.zap_retry
let zap_unverified t = Atomic.incr t.zap_unverified
let zap_dropped t = Atomic.incr t.zap_dropped

(* One sender response can report a whole batch, so this bump takes a count; it also stamps
   push_latest (the Julia push_notification_latest metric source). *)
let push_sent t (n : int) =
  ignore (Atomic.fetch_and_add t.push_sent n);
  Atomic.set t.push_latest (int_of_float (Unix.time ()))

let push_sent_total t = Atomic.get t.push_sent
let push_latest t = Atomic.get t.push_latest

(* Record one job's queue wait (seconds between submit and dequeue); the reporter prints and
   resets the per-interval maximum, so a queue that is "full but flowing" (small waits) is
   distinguishable from one that is backing up. *)
let observe_queue_wait t (seconds : float) : unit =
  let ms = int_of_float (seconds *. 1000.) in
  let rec bump () =
    let cur = Atomic.get t.qwait_max_ms in
    if ms > cur && not (Atomic.compare_and_set t.qwait_max_ms cur ms) then bump ()
  in
  bump ()

(* Instantaneous gauges + cumulative counters for the pushgateway exporter. *)
let queue_depth t = max 0 (Atomic.get t.submitted - Atomic.get t.started)
let busy_workers t = max 0 (Atomic.get t.started - Atomic.get t.completed)
let errors_total t = Atomic.get t.errors
let lnurl_totals t = (Atomic.get t.lnurl_ok, Atomic.get t.lnurl_fail, Atomic.get t.lnurl_timeout)

(* (verified, retried, unverified, dropped) — cumulative. *)
let zap_totals t =
  ( Atomic.get t.zap_ok,
    Atomic.get t.zap_retry,
    Atomic.get t.zap_unverified,
    Atomic.get t.zap_dropped )

(* {1 Fiber phase slots} — see primal_common Phases; aliases keep existing call sites. *)

type slot = Phases.slot

let new_slot = Phases.new_slot
let set_slot = Phases.set_slot
let set_domain_slot = Phases.set_domain_slot
let register_domain_slot = Phases.register_domain_slot
let slot_state = Phases.slot_state
let phase = Phases.phase
let stuck_slots = Phases.stuck_slots
let dump_slots = Phases.dump_slots

(* Cumulative imported-event count (the [tot] field of the per-second log line). Read by the
   pushgateway exporter fiber, which publishes it as a Prometheus counter. *)
let imported_total t = Atomic.get t.imported

(* Loop forever (run as a fiber on the main domain): once per second, print per-second deltas of
   the rate counters plus instantaneous queue depth / busy-workers / cumulative totals. Pure
   in-memory; never touches the DB.

   Stall watchdog: if at least one worker is busy yet NO job completes for [watchdog_stall_s]
   consecutive seconds, the process is wedged (every per-job operation is bounded: HTTP ~10s,
   statement_timeout on DB queries), so print a loud line and [exit 1] — the systemd service has
   Restart=always, turning a permanent deadlock into a ~1-minute outage. During a DB outage the
   workers block in their reconnect loop and this fires too; the restarted process then retries
   its startup connect under systemd, which is the same recovery loop, just noisier. The importer
   is stateless and re-imports are cheap, so a restart never loses data. *)
let report_loop ?(watchdog_stall_s = 180) ~clock ~capacity ~workers (t : t) : unit =
  let g = Atomic.get in
  let start = Eio.Time.now clock in
  let p_recv = ref 0 and p_imp = ref 0 and p_dup = ref 0 and p_rej = ref 0 and p_err = ref 0 in
  let p_comp = ref 0 and stalled_s = ref 0 in
  let p_lok = ref 0 and p_lfail = ref 0 and p_lto = ref 0 in
  while true do
    Eio.Time.sleep clock 1.0;
    let recv = g t.recv and imp = g t.imported and dup = g t.duplicate
    and rej = g t.rejected and err = g t.errors and sub = g t.submitted
    and sta = g t.started and comp = g t.completed and rc = g t.reconnects in
    let d_recv = recv - !p_recv and d_imp = imp - !p_imp and d_dup = dup - !p_dup
    and d_rej = rej - !p_rej and d_err = err - !p_err in
    p_recv := recv; p_imp := imp; p_dup := dup; p_rej := rej; p_err := err;
    let depth = max 0 (sub - sta) and busy = max 0 (sta - comp) in
    let d_comp = comp - !p_comp in
    p_comp := comp;
    if busy > 0 && d_comp = 0 then incr stalled_s else stalled_s := 0;
    if !stalled_s >= watchdog_stall_s then begin
      Printf.printf
        "[importer] WATCHDOG: %d/%d workers busy but no job completed for %ds (q %d/%d, tot %d); \
         fiber phases:\n%!"
        busy workers !stalled_s depth capacity imp;
      Phases.dump_slots ();
      Printf.printf "[importer] WATCHDOG: exiting so systemd restarts us\n%!";
      exit 1
    end;
    let pct = if capacity > 0 then 100. *. float_of_int depth /. float_of_int capacity else 0. in
    let uptime = int_of_float (Eio.Time.now clock -. start) in
    (* rss = whole-process resident memory (what OOM acts on); heap = OCaml major heap (shared
       across domains). The gap between them is C/malloc memory (libpq, TLS) — so a growing rss with
       a flat heap points at a native leak rather than an OCaml one. *)
    let rss = Procinfo.read_rss_bytes () in
    let heap = Procinfo.heap_bytes () in
    let d_lok = g t.lnurl_ok - !p_lok and d_lfail = g t.lnurl_fail - !p_lfail
    and d_lto = g t.lnurl_timeout - !p_lto in
    p_lok := g t.lnurl_ok; p_lfail := g t.lnurl_fail; p_lto := g t.lnurl_timeout;
    let push_total = g t.push_sent in
    (* Cumulative, not per-second: an uncounted zap is rare and individually significant, so what
       matters is the running total since start, not the rate in the last second. *)
    let z_ok, z_retry, z_unver, z_drop = zap_totals t in
    let qw_ms = Atomic.exchange t.qwait_max_ms 0 in
    (* Any fiber stuck non-idle > 30s gets called out (worst 3), so a partial wedge — a few
       workers pinned on one job — is visible long before the watchdog would fire. *)
    let stuck = Phases.stuck_summary ~min_age:30.0 () in
    Printf.printf
      "[importer %s up %s] recv %d/s  imp %d/s  dup %d/s  rej %d/s  err %d/s | q %d/%d %.1f%% qw %.1fs | busy %d/%d | lnurl %d/%d/%d | zap %d/%d/%d/%d | push %d | tot %d | rss %s heap %s | r=%d%s\n%!"
      (Procinfo.timestamp ()) (Procinfo.fmt_hms uptime) d_recv d_imp d_dup d_rej d_err depth
      capacity pct
      (float_of_int qw_ms /. 1000.) busy workers d_lok d_lfail d_lto z_ok z_retry z_unver z_drop
      push_total imp (Procinfo.fmt_bytes rss) (Procinfo.fmt_bytes heap) rc stuck
  done
