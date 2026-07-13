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
   third-party HTTP. *)

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

type t = {
  queue : CS.zap_job Eio.Stream.t;
  dropped : int Atomic.t;
  cache : (string, string option * float) Hashtbl.t; (* url -> (nostrPubkey?, expires_at) *)
  breaker : (string, int * float) Hashtbl.t; (* host -> (consecutive fails, skip until) *)
  lock : Mutex.t;
}

let create () : t =
  {
    queue = Eio.Stream.create queue_capacity;
    dropped = Atomic.make 0;
    cache = Hashtbl.create 4096;
    breaker = Hashtbl.create 64;
    lock = Mutex.create ();
  }

(* Non-blocking enqueue from an import worker; drops (with a rate-limited log) when saturated. *)
let submit (t : t) (job : CS.zap_job) : unit =
  if Eio.Stream.length t.queue >= drop_threshold then begin
    let n = 1 + Atomic.fetch_and_add t.dropped 1 in
    if n = 1 || n mod 1000 = 0 then
      Printf.eprintf "zap_verifier: queue full; %d verifications dropped so far\n%!" n
  end
  else Eio.Stream.add t.queue job

let with_lock (m : Mutex.t) (f : unit -> 'a) : 'a =
  Mutex.lock m;
  Fun.protect ~finally:(fun () -> Mutex.unlock m) f

type lookup = Cached of string option | Fetch | Skip

let cache_lookup (t : t) ~(url : string) ~(host : string) ~(now : float) : lookup =
  with_lock t.lock (fun () ->
      match Hashtbl.find_opt t.cache url with
      | Some (pk, expires) when expires > now -> Cached pk
      | _ -> (
          match Hashtbl.find_opt t.breaker host with
          | Some (fails, until) when fails >= breaker_fails && until > now -> Skip
          | _ -> Fetch))

(* [None] = transport failure (DNS/connect/TLS/timeout): trips the breaker and caches negative.
   [Some pk_opt] = the endpoint answered (pk_opt = its advertised nostrPubkey, if any): resets
   the breaker and caches the answer. *)
let record_result (t : t) ~(url : string) ~(host : string) ~(now : float)
    (res : string option option) : unit =
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
          Hashtbl.replace t.cache url (pk_opt, now +. ttl))

(* Verify one zap receipt (cache/breaker first, HTTP on miss) and apply its effects if the
   endpoint's advertised nostrPubkey matches the receipt's author. *)
let process (t : t) ~net ~clock ?proxy ~(stats : Stats.t) (est : CS.est) (job : CS.zap_job) :
    unit =
  Stats.phase "zap:endpoint";
  match Lnurl.endpoint_url est ~zapped_pk:job.CS.zj_zapped_pk with
  | None -> ()
  | Some u -> (
      let url = Printf.sprintf "https://%s:%d%s" u.Http.host u.Http.port u.Http.path in
      let now = Unix.gettimeofday () in
      let advertised =
        match cache_lookup t ~url ~host:u.Http.host ~now with
        | Cached pk -> pk
        | Skip -> None
        | Fetch -> (
            match Lnurl.timed_get ~net ~clock ?proxy ~stats u with
            | None ->
                record_result t ~url ~host:u.Http.host ~now None;
                None
            | Some body ->
                let pk = Lnurl.extract_nostr_pubkey body in
                record_result t ~url ~host:u.Http.host ~now (Some pk);
                pk)
      in
      match advertised with
      | Some pk when pk = job.CS.zj_receipt.Nostr.pubkey ->
          Stats.phase "zap:apply";
          CS.apply_zap_effects est job
      | _ -> ())

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
        let rec loop () =
          let job = Eio.Stream.take t.queue in
          (try process t ~net ~clock ?proxy ~stats est job with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
              Printf.eprintf "zap_verifier: %s\n%!" (Printexc.to_string exn);
              if Postgres.is_connection_error exn then reconnect_est est);
          Stats.phase "idle";
          loop ()
        in
        loop ())
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
           dropped); fiber phases:\n%!"
          n min_age (Eio.Stream.length t.queue) (Atomic.get t.dropped);
        Stats.dump_slots ();
        Printf.printf "[importer] ZAP-VERIFIER WATCHDOG: exiting so systemd restarts us\n%!";
        exit 1
      end
    done
  in
  Fiber.all (watchdog :: List.init n verifier)
