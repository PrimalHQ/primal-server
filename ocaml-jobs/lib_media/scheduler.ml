(* processing_graph_execution_scheduler.rs + .jl: every second, for every func this executor
   handles, claim pending nodes (oldest first) up to the func's concurrency; stuck nodes
   (started, unfinished, under 2 days old) reset at start; stats every 60 s;
   `refresh materialized view concurrently pn_time_for_pubkeys` every 600 s.

   Execution happens on [cfg.worker_domains] worker domains (the Rust executor ran on a
   multi-threaded runtime; on one domain the synchronous file writes and sha256 of large
   originals stalled every fiber for minutes). The scheduler domain claims and hands nodes over
   an Eio.Stream; each worker domain has its own ctx with its own DB pools (connections are
   domain-bound), and runs [worker_fibers] node fibers. Counters are atomics. *)

open Eio.Std
open Procgraph

let julia_duties = [ "import_upload_3"; "block_media"; "purge_media_" ]

type job = { n : node; func : string; created : string }

let run (ctx : ctx) ~(stop : unit Promise.t) : unit =
  let cfg = ctx.cfg in
  let funcs = List.filter (fun f -> find_handler ~mod_:"" ~func:f <> None) cfg.execute_funcs in
  let skipped = List.filter (fun f -> find_handler ~mod_:"" ~func:f = None) cfg.execute_funcs in
  if skipped <> [] then log "scheduler: no handler for %s; not claimed" (String.concat ", " skipped);
  List.iter (fun f -> let n = reset_stuck ctx f in log "scheduler: reset %d stuck tasks for %s" n f) funcs;
  let cap f = if List.mem f julia_duties then cfg.julia_duty_concurrency else cfg.max_concurrent_per_name in
  let counter () = let t = Hashtbl.create 16 in List.iter (fun f -> Hashtbl.replace t f (Atomic.make 0)) funcs; t in
  let running = counter () and completed = counter () and failed = counter () in
  let get t f = match Hashtbl.find_opt t f with Some a -> Atomic.get a | None -> 0 in
  let incr_t t f d = match Hashtbl.find_opt t f with Some a -> ignore (Atomic.fetch_and_add a d) | None -> () in
  let total_cap = List.fold_left (fun acc f -> acc + cap f) 0 funcs in
  let jobs : job Eio.Stream.t = Eio.Stream.create (max 16 total_cap) in
  let domains = max 1 cfg.worker_domains in
  let worker_fibers = max 1 ((total_cap + domains - 1) / domains) in
  log "scheduler: %d worker domains x %d fibers for %d claim slots" domains worker_fibers total_cap;
  let run_job (wctx : ctx) (j : job) =
    let t0 = Unix.gettimeofday () in
    (match execute_node wctx j.n with
    | Ok _ -> incr_t completed j.func 1; if wctx.verbose then log "%s %s ok in %.1fs (created %s)" j.func (id_hex j.n) (Unix.gettimeofday () -. t0) j.created
    | Error m -> incr_t failed j.func 1; log "%s %s FAILED in %.1fs: %s" j.func (id_hex j.n) (Unix.gettimeofday () -. t0) (String.sub m 0 (min 300 (String.length m)))
    | exception Eio.Cancel.Cancelled e -> incr_t running j.func (-1); raise (Eio.Cancel.Cancelled e)
    | exception exn -> incr_t failed j.func 1; log "%s %s crashed: %s" j.func (id_hex j.n) (Printexc.to_string exn));
    incr_t running j.func (-1)
  in
  Switch.run @@ fun sw ->
  (* worker domains *)
  for d = 1 to domains do
    Fiber.fork_daemon ~sw (fun () ->
        Eio.Domain_manager.run ctx.domain_mgr (fun () ->
            Switch.run @@ fun dsw ->
            Postgres.set_env ~net:ctx.net ~sw:dsw;
            Mirage_crypto_rng_unix.use_default ();
            let wctx = { ctx with cache = Postgres.make_pool ~size:cfg.worker_pool_size ctx.cache.Postgres.ci; mem = Postgres.make_pool ~size:3 ctx.mem.Postgres.ci } in
            Fiber.all
              (List.init worker_fibers (fun _ () ->
                   let rec loop () =
                     match Fiber.first (fun () -> Promise.await stop; `Stop) (fun () -> `Job (Eio.Stream.take jobs)) with
                     | `Stop -> ()
                     | `Job j -> (try run_job wctx j with Eio.Cancel.Cancelled e -> raise (Eio.Cancel.Cancelled e) | exn -> log "worker %d: %s" d (Printexc.to_string exn)); loop ()
                   in
                   loop ())));
        `Stop_daemon)
  done;
  let last_stats = ref (Unix.gettimeofday ()) and last_refresh = ref 0.0 in
  let rec loop () =
    if not (Promise.is_resolved stop) then begin
      List.iter
        (fun func ->
          let rec fill () =
            if get running func < cap func then
              match (try claim_pending ctx func with exn -> log "claim %s: %s" func (Printexc.to_string exn); None) with
              | Some (n, created) ->
                  incr_t running func 1;
                  Eio.Stream.add jobs { n; func; created };
                  fill ()
              | None -> ()
          in
          fill ())
        funcs;
      let now = Unix.gettimeofday () in
      if now -. !last_stats >= 60.0 then begin
        last_stats := now;
        List.iter
          (fun f ->
            let pending = try pending_count ctx f with _ -> -1 in
            let c = get completed f and e = get failed f in
            if pending > 0 || c > 0 || e > 0 || get running f > 0 then log "stats | %s | pending=%d running=%d completed_last_interval=%d failed=%d" f pending (get running f) c e;
            incr_t completed f (-c);
            incr_t failed f (-e))
          funcs
      end;
      if now -. !last_refresh >= cfg.refresh_matview_period_s then begin
        last_refresh := now;
        Fiber.fork ~sw (fun () -> try ignore (Postgres.use ctx.cache (fun dbh -> Postgres.query dbh "refresh materialized view concurrently pn_time_for_pubkeys" [])) with Eio.Cancel.Cancelled e -> raise (Eio.Cancel.Cancelled e) | exn -> log "refresh pn_time_for_pubkeys: %s" (Printexc.to_string exn))
      end;
      match Fiber.first (fun () -> Promise.await stop; `Stop) (fun () -> Eio.Time.sleep ctx.clock cfg.scheduler_period_s; `Tick) with `Stop -> () | `Tick -> loop ()
    end
  in
  loop ();
  log "scheduler: stopping, waiting for running nodes"
