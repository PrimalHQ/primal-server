(* Off-critical-path LNURL zapper verification.

   Import workers used to fetch the zapped user's LNURL-pay endpoint inline for every zap
   receipt, so a slow wallet provider throttled the import pipeline (and, before end-to-end
   HTTP timeouts, a wedged one deadlocked it — the 2026-07-11 incident). Now they enqueue a
   Cache_storage.zap_job here and move on; [n] dedicated verifier domains (each with its own
   est / DB connections) fetch the endpoint and apply the zap's import effects on success.

   The fetch layer is cached and fused, shared across the verifier domains behind a mutex
   (plain Stdlib mutex — the critical sections never suspend):
   - url -> advertised-nostrPubkey cache (positive TTL 1h, negative 10min): most zaps go to a
     few popular users, so repeat zaps skip HTTP entirely;
   - per-host circuit breaker: after [breaker_fails] consecutive fetch failures a host is
     skipped for [breaker_cooldown]s (treated as unverified), so a dead provider costs a few
     timeouts, not one per zap.

   Submission never blocks: when the pool can't keep up, the job is dropped (the zap stays
   uncounted, exactly as if verification had failed) — import throughput must never depend on
   third-party HTTP.

   A *failed* verification, on the other hand, is retried rather than dropped. A transport
   failure says nothing about the zap's validity, yet the receipt is already stored, so nothing
   downstream will ever revisit it: the zap is silently uncounted forever. On 2026-08-04 that
   cost 13% of e-tagged zap receipts in a four-hour window (66 of 507) while the same fetches
   from a standalone process on the same host succeeded 100/100 — including both zaps on
   nevent1qqs8pnl…, whose two fetches of walletofsatoshi.com/…/btc_alm each hit the 10s deadline.
   Deferrable outcomes (fetch failure, breaker cooldown, and the zapped user's metadata not
   imported yet) now go on a delayed retry list; only an endpoint that answers and disowns the
   receipt author is final. *)

open Eio.Std
module CS = Cache_storage

let queue_capacity = 2048
let drop_threshold = 2000 (* headroom below capacity so racing submitters still never block *)
let positive_ttl = 3600.0
let negative_ttl = 600.0
let breaker_fails = 3
let breaker_cooldown = 300.0
let cache_max_entries = 50_000 (* crude bound: reset the cache when it grows past this *)
let pool_stall = 600.0 (* pool watchdog: all verifiers stuck non-idle this long -> exit *)

(* Retry schedule for deferrable failures, in seconds after the attempt that failed. Spread wide
   enough to outlast the negative cache (10 min) and the breaker cooldown (5 min) — a retry that
   lands inside either just re-reads the same cached failure — and to give a missing kind-0 time
   to arrive. Length = number of retries; after the last one the job is dropped for good. *)
let retry_backoff = [| 90.0; 420.0; 1800.0; 5400.0 |]

(* Bound on the pending-retry list. Retries are a repair path, not a queue: if this many jobs are
   waiting, verification is broadly broken and shedding is better than unbounded growth. *)
let retry_max = 20_000

let retry_sweep_interval = 15.0

(* What the endpoint told us, as cached. [None] = it never answered (transport failure), which is
   deferrable; [Some pk_opt] = it answered, with [pk_opt] its advertised nostrPubkey if any — a
   verdict, so a cached [Some None] must not be retried the way a cached [None] is. *)
type answer = string option option

type t = {
  (* (job, attempts already made). Import workers submit with 0; the retry fiber re-submits with
     the count so far. *)
  queue : (CS.zap_job * int) Eio.Stream.t;
  dropped : int Atomic.t;
  cache : (string, answer * float) Hashtbl.t; (* url -> (answer, expires_at) *)
  breaker : (string, int * float) Hashtbl.t; (* host -> (consecutive fails, skip until) *)
  (* (due_at, attempts_so_far, job), unordered — the sweep scans the whole list, and the backoff
     tiers mean insertion order is not due order anyway. Written by the verifier domains, drained
     by the retry fiber in [run]; both under [lock]. [retries_len] tracks the length so [defer]
     does not walk the list on every deferral. *)
  mutable retries : (float * int * CS.zap_job) list;
  mutable retries_len : int;
  lock : Mutex.t;
  (* Held here rather than only passed to [run], so [submit] — called from an import worker via
     Cache_storage's hook, with no stats handle of its own — can still account for its drops. *)
  stats : Stats.t;
}

let create ~(stats : Stats.t) () : t =
  {
    queue = Eio.Stream.create queue_capacity;
    dropped = Atomic.make 0;
    cache = Hashtbl.create 4096;
    breaker = Hashtbl.create 64;
    retries = [];
    retries_len = 0;
    lock = Mutex.create ();
    stats;
  }

(* Non-blocking enqueue; drops (with a rate-limited log) when saturated. A drop here is a zap
   that will never be counted, so it lands in zap_dropped like any other give-up. *)
let enqueue (t : t) (job : CS.zap_job) ~(attempts : int) : bool =
  if Eio.Stream.length t.queue >= drop_threshold then begin
    Stats.zap_dropped t.stats;
    let n = 1 + Atomic.fetch_and_add t.dropped 1 in
    if n = 1 || n mod 1000 = 0 then
      Printf.eprintf "zap_verifier: queue full; %d verifications dropped so far\n%!" n;
    false
  end
  else begin
    Eio.Stream.add t.queue (job, attempts);
    true
  end

(* Enqueue from an import worker: a first attempt. *)
let submit (t : t) (job : CS.zap_job) : unit = ignore (enqueue t job ~attempts:0 : bool)

let with_lock (m : Mutex.t) (f : unit -> 'a) : 'a =
  Mutex.lock m;
  Fun.protect ~finally:(fun () -> Mutex.unlock m) f

type lookup = Cached of answer | Fetch | Skip

let cache_lookup (t : t) ~(url : string) ~(host : string) ~(now : float) : lookup =
  with_lock t.lock (fun () ->
      match Hashtbl.find_opt t.cache url with
      | Some (ans, expires) when expires > now -> Cached ans
      | _ -> (
          match Hashtbl.find_opt t.breaker host with
          | Some (fails, until) when fails >= breaker_fails && until > now -> Skip
          | _ -> Fetch))

(* [None] = transport failure (DNS/connect/TLS/timeout): trips the breaker and caches negative.
   [Some pk_opt] = the endpoint answered (pk_opt = its advertised nostrPubkey, if any): resets
   the breaker and caches the answer. *)
let record_result (t : t) ~(url : string) ~(host : string) ~(now : float) (res : answer) : unit =
  with_lock t.lock (fun () ->
      if Hashtbl.length t.cache > cache_max_entries then Hashtbl.reset t.cache;
      match res with
      | None ->
          let fails =
            match Hashtbl.find_opt t.breaker host with Some (f, _) -> f + 1 | None -> 1
          in
          Hashtbl.replace t.breaker host (fails, now +. breaker_cooldown);
          Hashtbl.replace t.cache url (None, now +. negative_ttl)
      | Some pk_opt ->
          Hashtbl.remove t.breaker host;
          let ttl = match pk_opt with Some _ -> positive_ttl | None -> negative_ttl in
          Hashtbl.replace t.cache url (Some pk_opt, now +. ttl))

(* Queue [job] for another attempt, or give up and account for the loss. [attempts] is how many
   attempts have already been made (1 after the first). *)
let defer (t : t) ~(stats : Stats.t) ~(attempts : int) ~(reason : string) (job : CS.zap_job) : unit
    =
  if attempts > Array.length retry_backoff then begin
    Stats.zap_dropped stats;
    Printf.eprintf "zap_verifier: giving up on zap %s after %d attempts (%s); zap uncounted\n%!"
      (Hex_util.encode job.CS.zj_receipt.Nostr.id) attempts reason
  end
  else begin
    let due = Unix.gettimeofday () +. retry_backoff.(attempts - 1) in
    let queued =
      with_lock t.lock (fun () ->
          if t.retries_len >= retry_max then false
          else begin
            t.retries <- (due, attempts, job) :: t.retries;
            t.retries_len <- t.retries_len + 1;
            true
          end)
    in
    if queued then Stats.zap_retry stats
    else begin
      Stats.zap_dropped stats;
      let n = 1 + Atomic.fetch_and_add t.dropped 1 in
      if n = 1 || n mod 1000 = 0 then
        Printf.eprintf "zap_verifier: retry list full (%d); %d verifications dropped so far\n%!"
          retry_max n
    end
  end

(* Decide one zap receipt (cache/breaker first, HTTP on miss). Writes nothing, so the caller can
   retry any failure here without risking half-applied effects.

   [Verified]: the endpoint's advertised nostrPubkey is the receipt's author.
   [Unverified]: the endpoint answered and its nostrPubkey is absent or someone else's — a
     verdict, and retrying cannot change it.
   [Deferred]: no metadata for the zapped user yet, the fetch failed, or the host is in breaker
     cooldown — none of which says anything about the zap. *)
type verdict = Verified | Unverified | Deferred of string

let verify (t : t) ~net ~clock ?proxy ~(stats : Stats.t) (est : CS.est) (job : CS.zap_job) :
    verdict =
  Stats.phase "zap:endpoint";
  match Lnurl.endpoint_url est ~zapped_pk:job.CS.zj_zapped_pk with
  | None -> Deferred "no lnurl endpoint for zapped pubkey"
  | Some u -> (
      let url = Printf.sprintf "https://%s:%d%s" u.Http.host u.Http.port u.Http.path in
      let now = Unix.gettimeofday () in
      (* [Error reason] = we never got an answer; [Ok pk_opt] = the endpoint answered. *)
      let advertised =
        match cache_lookup t ~url ~host:u.Http.host ~now with
        | Cached (Some pk_opt) -> Ok pk_opt (* endpoint answered (cached verdict) *)
        | Cached None -> Error "cached fetch failure"
        | Skip -> Error "host in circuit-breaker cooldown"
        | Fetch -> (
            match Lnurl.timed_get ~net ~clock ?proxy ~stats u with
            | None ->
                record_result t ~url ~host:u.Http.host ~now None;
                Error "lnurl fetch failed"
            | Some body ->
                let pk = Lnurl.extract_nostr_pubkey body in
                record_result t ~url ~host:u.Http.host ~now (Some pk);
                Ok pk)
      in
      match advertised with
      | Ok (Some pk) when pk = job.CS.zj_receipt.Nostr.pubkey -> Verified
      | Ok _ -> Unverified
      | Error reason -> Deferred reason)

(* Run [n] verifier domains forever (mirrors Worker_pool.run): each takes jobs off the shared
   queue with its own est, so a slow fetch delays only this pool, never the import workers.

   Pool watchdog: DNS resolution (getaddrinfo in a systhread) is the one operation the request
   timeout cannot interrupt, and the circuit breaker never trips on a hang (it needs a COMPLETED
   failure) — so a resolver-blackholed host can wedge every verifier permanently, which the main
   stall watchdog would never notice (imports keep completing). If ALL verifiers have been stuck
   non-idle for [pool_stall]s, dump the fiber phases and exit for systemd's Restart=always
   (which also clears the leaked systhreads). Zaps queued meanwhile are dropped, not lost import
   data — re-imported receipts are dedup'd upstream. *)
let run ~(domain_mgr : _ Eio.Domain_manager.t) ~(net : _ Eio.Net.t) ~clock ?proxy ~(n : int)
    ~(stats : Stats.t) ~(make_est : unit -> CS.est) ~(reconnect_est : CS.est -> unit) (t : t) :
    unit =
  let pg_net = (net :> Postgres.net_t) in
  let slots = List.init n (fun i -> Stats.new_slot (Printf.sprintf "zv%d" i)) in
  let verifier i () =
    Eio.Domain_manager.run domain_mgr (fun () ->
        Switch.run @@ fun sw ->
        Postgres.set_env ~net:pg_net ~sw;
        Stats.set_domain_slot (List.nth slots i);
        let est = make_est () in
        let fail exn =
          Printf.eprintf "zap_verifier: %s\n%!" (Printexc.to_string exn);
          if Postgres.is_connection_error exn then reconnect_est est
        in
        let rec loop () =
          let job, prior = Eio.Stream.take t.queue in
          let attempts = prior + 1 in
          (match
             try Ok (verify t ~net ~clock ?proxy ~stats est job) with
             | Eio.Cancel.Cancelled _ as e -> raise e
             | exn -> Error exn
           with
          | Ok Verified -> (
              Stats.phase "zap:apply";
              (* Not retried on failure: apply_zap_effects is several autocommitted statements,
                 so a second run after a partial one would double-count sats and duplicate the
                 og_zap_receipts row. Losing the zap is the lesser error. *)
              try
                CS.apply_zap_effects est job;
                Stats.zap_ok stats
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                  fail exn;
                  Stats.zap_dropped stats;
                  Printf.eprintf "zap_verifier: zap %s verified but not applied; zap uncounted\n%!"
                    (Hex_util.encode job.CS.zj_receipt.Nostr.id))
          | Ok Unverified -> Stats.zap_unverified stats
          | Ok (Deferred reason) -> defer t ~stats ~attempts ~reason job
          (* Nothing was written, so this is safe to retry. *)
          | Error exn ->
              fail exn;
              defer t ~stats ~attempts ~reason:(Printexc.to_string exn) job);
          Stats.phase "idle";
          loop ()
        in
        loop ())
  in
  (* Move due retries back onto the queue. Runs on the calling (main) domain: the verifier
     domains only ever append to [t.retries], so a stuck verifier cannot block rescheduling. *)
  let retry_fiber () =
    while true do
      Eio.Time.sleep clock retry_sweep_interval;
      let now = Unix.gettimeofday () in
      let due =
        with_lock t.lock (fun () ->
            let due, pending = List.partition (fun (at, _, _) -> at <= now) t.retries in
            t.retries <- pending;
            t.retries_len <- List.length pending;
            due)
      in
      List.iter (fun (_, attempts, job) -> ignore (enqueue t job ~attempts : bool)) due
    done
  in
  let watchdog () =
    while true do
      Eio.Time.sleep clock 30.0;
      let now = Unix.gettimeofday () in
      let stuck_age s =
        let p, since = Stats.slot_state s in
        if p = "idle" then 0.0 else now -. since
      in
      let min_age = List.fold_left (fun acc s -> Float.min acc (stuck_age s)) infinity slots in
      if min_age >= pool_stall then begin
        Printf.printf
          "[importer] ZAP-VERIFIER WATCHDOG: all %d verifiers stuck for %.0fs+ (queue %d, %d \
           awaiting retry, %d dropped); fiber phases:\n%!"
          n min_age (Eio.Stream.length t.queue)
          (with_lock t.lock (fun () -> t.retries_len))
          (Atomic.get t.dropped);
        Stats.dump_slots ();
        Printf.printf "[importer] ZAP-VERIFIER WATCHDOG: exiting so systemd restarts us\n%!";
        exit 1
      end
    done
  in
  Fiber.all (watchdog :: retry_fiber :: List.init n verifier)
