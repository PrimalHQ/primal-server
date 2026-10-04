(* processing_graph_execution_scheduler.rs + .jl: every second, for every func this executor
   handles, claim pending nodes (oldest first) up to the func's concurrency and run each in its own
   fiber; stuck nodes (started, unfinished, under 2 days old) reset at start; stats every 60 s;
   `refresh materialized view concurrently pn_time_for_pubkeys` every 600 s. *)

open Eio.Std
open Procgraph

let julia_duties = [ "import_upload_3"; "block_media"; "purge_media_" ]

let run (ctx : ctx) ~(stop : unit Promise.t) : unit =
  let cfg = ctx.cfg in
  let funcs = List.filter (fun f -> find_handler ~mod_:"" ~func:f <> None) cfg.execute_funcs in
  let skipped = List.filter (fun f -> find_handler ~mod_:"" ~func:f = None) cfg.execute_funcs in
  if skipped <> [] then log "scheduler: no handler for %s; not claimed" (String.concat ", " skipped);
  List.iter (fun f -> let n = reset_stuck ctx f in log "scheduler: reset %d stuck tasks for %s" n f) funcs;
  let cap f = if List.mem f julia_duties then cfg.julia_duty_concurrency else cfg.max_concurrent_per_name in
  let running : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let completed : (string, int) Hashtbl.t = Hashtbl.create 16 and failed : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let incr_t t k d = Hashtbl.replace t k (Option.value (Hashtbl.find_opt t k) ~default:0 + d) in
  let last_stats = ref (Unix.gettimeofday ()) and last_refresh = ref 0.0 in
  Switch.run @@ fun sw ->
  let rec loop () =
    if not (Promise.is_resolved stop) then begin
      List.iter
        (fun func ->
          let rec fill () =
            if Option.value (Hashtbl.find_opt running func) ~default:0 < cap func then
              match (try claim_pending ctx func with exn -> log "claim %s: %s" func (Printexc.to_string exn); None) with
              | Some (n, created) ->
                  incr_t running func 1;
                  Fiber.fork ~sw (fun () ->
                      let t0 = Unix.gettimeofday () in
                      (match execute_node ctx n with
                      | Ok _ -> incr_t completed func 1; if ctx.verbose then log "%s %s ok in %.1fs (created %s)" func (id_hex n) (Unix.gettimeofday () -. t0) created
                      | Error m -> incr_t failed func 1; log "%s %s FAILED in %.1fs: %s" func (id_hex n) (Unix.gettimeofday () -. t0) (String.sub m 0 (min 300 (String.length m)))
                      | exception Eio.Cancel.Cancelled e -> incr_t running func (-1); raise (Eio.Cancel.Cancelled e)
                      | exception exn -> incr_t failed func 1; log "%s %s crashed: %s" func (id_hex n) (Printexc.to_string exn));
                      incr_t running func (-1));
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
            let c = Option.value (Hashtbl.find_opt completed f) ~default:0 and e = Option.value (Hashtbl.find_opt failed f) ~default:0 in
            if pending > 0 || c > 0 || e > 0 || Option.value (Hashtbl.find_opt running f) ~default:0 > 0 then log "stats | %s | pending=%d running=%d completed_last_interval=%d failed=%d" f pending (Option.value (Hashtbl.find_opt running f) ~default:0) c e;
            Hashtbl.replace completed f 0;
            Hashtbl.replace failed f 0)
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
