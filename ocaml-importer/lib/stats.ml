(* In-memory counters for the importer, sampled once per second by a reporter fiber and logged as
   a single line (see [report_loop], wired in bin/main.ml).

   Every counter is cumulative and incremented from the worker domains, so they are [Atomic.t]:
   OCaml 5 atomics give cross-domain visibility, where plain refs would race. The reporter runs on
   the main domain and only reads them. *)

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

(* {1 Fiber phase slots}

   Eio has no way to dump the stacks of suspended fibers (they are heap-allocated effect
   continuations, invisible to a debugger attached to the domain thread), so long-running fibers
   register a [slot] and record what they are doing and since when. The reporter appends any slot
   stuck non-idle > 30s to the per-second line, and the watchdog dumps all slots before exiting —
   turning an opaque "busy 12/12" stall into e.g. "w3: https:dns for 1840s".

   The registry is module-global (not part of [t]) so deep lib code (http.ml) can record phases
   without threading a handle through every call. Slots are written by their owning fiber and read
   by the reporter, hence the Atomic pair. *)

type slot = { sname : string; sstate : (string * float) Atomic.t }

let slots : slot list Atomic.t = Atomic.make []

let new_slot (name : string) : slot =
  let s = { sname = name; sstate = Atomic.make ("idle", Unix.gettimeofday ()) } in
  let rec add () =
    let l = Atomic.get slots in
    if not (Atomic.compare_and_set slots l (s :: l)) then add ()
  in
  add ();
  s

let set_slot (s : slot) (phase : string) : unit =
  Atomic.set s.sstate (phase, Unix.gettimeofday ())

(* Implicit current-domain slot, for code that has no slot in scope (http.ml). Each worker domain
   registers one at startup; on the main domain — shared by many fibers — it stays unset and
   [phase] is a no-op (main-domain fibers own explicit slots instead). *)
let domain_slot : slot option Domain.DLS.key = Domain.DLS.new_key (fun () -> None)

(* Adopt an existing slot as this domain's implicit slot — for pools that create their slots up
   front (outside the domain) so they can watch them (see Zap_verifier's pool watchdog). *)
let set_domain_slot (s : slot) : unit = Domain.DLS.set domain_slot (Some s)
let register_domain_slot (name : string) : unit = set_domain_slot (new_slot name)

let slot_state (s : slot) : string * float = Atomic.get s.sstate

let phase (p : string) : unit =
  match Domain.DLS.get domain_slot with Some s -> set_slot s p | None -> ()

(* Slots currently non-idle for at least [min_age] seconds, oldest first. *)
let stuck_slots ~(min_age : float) : (string * string * float) list =
  let now = Unix.gettimeofday () in
  Atomic.get slots
  |> List.filter_map (fun s ->
         let p, since = Atomic.get s.sstate in
         let age = now -. since in
         if p <> "idle" && age >= min_age then Some (s.sname, p, age) else None)
  |> List.sort (fun (_, _, a) (_, _, b) -> Float.compare b a)

let dump_slots () : unit =
  let now = Unix.gettimeofday () in
  Atomic.get slots |> List.rev
  |> List.iter (fun s ->
         let p, since = Atomic.get s.sstate in
         Printf.printf "  %-16s %s for %.0fs\n" s.sname p (now -. since));
  flush stdout

(* Cumulative imported-event count (the [tot] field of the per-second log line). Read by the
   pushgateway exporter fiber, which publishes it as a Prometheus counter. *)
let imported_total t = Atomic.get t.imported

let fmt_hms s = Printf.sprintf "%02d:%02d:%02d" (s / 3600) (s / 60 mod 60) (s mod 60)

(* Whole-process resident set size (bytes), read from /proc/self/statm (field 2 = resident pages).
   This is process-wide — it covers every worker domain and all C/malloc allocations (libpq buffers,
   TLS, etc.), not just the OCaml heap — so it is the number the OOM killer actually acts on. Linux
   x86_64 pages are 4 KiB. Best-effort: any read failure yields 0. *)
let page_size = 4096

let read_rss_bytes () =
  try
    let ic = open_in "/proc/self/statm" in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        match String.split_on_char ' ' (input_line ic) with
        | _size :: resident :: _ -> int_of_string resident * page_size
        | _ -> 0)
  with _ -> 0

let fmt_bytes b =
  let b = float_of_int b in
  if b >= 1073741824. then Printf.sprintf "%.2fG" (b /. 1073741824.)
  else if b >= 1048576. then Printf.sprintf "%.0fM" (b /. 1048576.)
  else Printf.sprintf "%.0fK" (b /. 1024.)

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
      dump_slots ();
      Printf.printf "[importer] WATCHDOG: exiting so systemd restarts us\n%!";
      exit 1
    end;
    let pct = if capacity > 0 then 100. *. float_of_int depth /. float_of_int capacity else 0. in
    let uptime = int_of_float (Eio.Time.now clock -. start) in
    (* rss = whole-process resident memory (what OOM acts on); heap = OCaml major heap (shared
       across domains). The gap between them is C/malloc memory (libpq, TLS) — so a growing rss with
       a flat heap points at a native leak rather than an OCaml one. quick_stat does not walk the
       heap, so it is cheap to sample every second. *)
    let rss = read_rss_bytes () in
    let heap = (Gc.quick_stat ()).Gc.heap_words * (Sys.word_size / 8) in
    let d_lok = g t.lnurl_ok - !p_lok and d_lfail = g t.lnurl_fail - !p_lfail
    and d_lto = g t.lnurl_timeout - !p_lto in
    p_lok := g t.lnurl_ok; p_lfail := g t.lnurl_fail; p_lto := g t.lnurl_timeout;
    let push_total = g t.push_sent in
    let qw_ms = Atomic.exchange t.qwait_max_ms 0 in
    (* Wall-clock timestamp (uptime alone is painful to correlate with systemd/DB incidents). *)
    let tm = Unix.localtime (Unix.gettimeofday ()) in
    let stamp =
      Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
        tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
    in
    (* Any fiber stuck non-idle > 30s gets called out (worst 3), so a partial wedge — a few
       workers pinned on one job — is visible long before the watchdog would fire. *)
    let stuck =
      match stuck_slots ~min_age:30.0 with
      | [] -> ""
      | l ->
          let shown = List.filteri (fun i _ -> i < 3) l in
          let extra = List.length l - List.length shown in
          " | STUCK "
          ^ String.concat ", "
              (List.map (fun (n, p, age) -> Printf.sprintf "%s:%s %.0fs" n p age) shown)
          ^ (if extra > 0 then Printf.sprintf " (+%d)" extra else "")
    in
    Printf.printf
      "[importer %s up %s] recv %d/s  imp %d/s  dup %d/s  rej %d/s  err %d/s | q %d/%d %.1f%% qw %.1fs | busy %d/%d | lnurl %d/%d/%d | push %d | tot %d | rss %s heap %s | r=%d%s\n%!"
      stamp (fmt_hms uptime) d_recv d_imp d_dup d_rej d_err depth capacity pct
      (float_of_int qw_ms /. 1000.) busy workers d_lok d_lfail d_lto push_total imp
      (fmt_bytes rss) (fmt_bytes heap) rc stuck
  done
