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
   in-memory; never touches the DB. *)
let report_loop ~clock ~capacity ~workers (t : t) : unit =
  let g = Atomic.get in
  let start = Eio.Time.now clock in
  let p_recv = ref 0 and p_imp = ref 0 and p_dup = ref 0 and p_rej = ref 0 and p_err = ref 0 in
  while true do
    Eio.Time.sleep clock 1.0;
    let recv = g t.recv and imp = g t.imported and dup = g t.duplicate
    and rej = g t.rejected and err = g t.errors and sub = g t.submitted
    and sta = g t.started and comp = g t.completed and rc = g t.reconnects in
    let d_recv = recv - !p_recv and d_imp = imp - !p_imp and d_dup = dup - !p_dup
    and d_rej = rej - !p_rej and d_err = err - !p_err in
    p_recv := recv; p_imp := imp; p_dup := dup; p_rej := rej; p_err := err;
    let depth = max 0 (sub - sta) and busy = max 0 (sta - comp) in
    let pct = if capacity > 0 then 100. *. float_of_int depth /. float_of_int capacity else 0. in
    let uptime = int_of_float (Eio.Time.now clock -. start) in
    (* rss = whole-process resident memory (what OOM acts on); heap = OCaml major heap (shared
       across domains). The gap between them is C/malloc memory (libpq, TLS) — so a growing rss with
       a flat heap points at a native leak rather than an OCaml one. quick_stat does not walk the
       heap, so it is cheap to sample every second. *)
    let rss = read_rss_bytes () in
    let heap = (Gc.quick_stat ()).Gc.heap_words * (Sys.word_size / 8) in
    Printf.printf
      "[importer %s] recv %d/s  imp %d/s  dup %d/s  rej %d/s  err %d/s | q %d/%d %.1f%% | busy %d/%d | tot %d | rss %s heap %s | r=%d\n%!"
      (fmt_hms uptime) d_recv d_imp d_dup d_rej d_err depth capacity pct busy workers imp
      (fmt_bytes rss) (fmt_bytes heap) rc
  done
