(* primal-importer entry point, mirroring the wiring in start_media_importer.jl:

   - register the ext_* hooks and the LNURL zapper verifier;
   - build the spam detector and its processors (mark_spammers / mark_event_as_spam /
     store_spam_content_hash), exactly as start_media_importer.jl:150-163;
   - run a domain worker pool that, for each firehose message, runs the spam detector and
     imports the event into Postgres;
   - run the firehose client, feeding messages into the worker queue.

   Configuration comes from a JSON file passed as the sole command-line argument (all settings
   are read from there; the environment is not consulted at runtime). See lib/config.ml. *)

open Eio.Std
module CS = Importer.Cache_storage
module N = Importer.Nostr
module Pg = Importer.Postgres
module Cfg = Importer.Config
module SD = Importer.Spam_detection
module FC = Importer.Firehose_client
module WP = Importer.Worker_pool

let usage () =
  Printf.eprintf "usage: %s <config.json>   run the importer with settings from the JSON config file\n%!"
    Sys.argv.(0)

let () =
  (* Config is read entirely from the JSON file named on the command line (required). Parsing runs
     before Eio_main.run — it does not need the Eio env. *)
  let cfg =
    match Sys.argv with
    | [| _; path |] when String.length path > 0 && path.[0] <> '-' -> (
        try Cfg.of_json_file path with
        | Cfg.Config_error msg ->
            Printf.eprintf "primal-importer: config error: %s\n%!" msg;
            exit 2
        | Sys_error msg ->
            Printf.eprintf "primal-importer: %s\n%!" msg;
            exit 2)
    | _ ->
        usage ();
        exit 2
  in
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let proc_mgr = Eio.Stdenv.process_mgr env in
  let proxy = Cfg.proxy_endpoint cfg in

  let stats = Importer.Stats.create () in

  (* ext_* hooks + LNURL zapper verification. Verification is OFF the import critical path:
     workers enqueue onto the Zap_verifier pool (never blocking on third-party HTTP) and its
     dedicated domains fetch the endpoint and apply the zap effects (see lib/zap_verifier.ml). *)
  Importer.Cache_storage_ext.register ();
  let zap_pool = Importer.Zap_verifier.create () in
  CS.set_zap_verifier_submit (Importer.Zap_verifier.submit zap_pool);

  (* Spam detector shared across worker domains; processors mirror start_media_importer.jl, but
     write to the membership filterlist (no in-process Filterlist state). *)
  let sd = SD.create () in
  SD.add_spamlist_processor sd (fun est spamlist ->
      SD.SS.iter
        (fun pk ->
          Importer.Filterlist.block_pubkey_spam ~mem_dbh:est.CS.mem_dbh pk
            ~comment:"spam-detector: clustered spam pubkey")
        spamlist);
  SD.add_spamevent_processor sd (fun est e ->
      Importer.Filterlist.block_event_spam ~mem_dbh:est.CS.mem_dbh e.N.id
        ~comment:"spam-detector: clustered spam event");
  SD.add_spamevent_processor sd (fun est e -> Importer.Cache_storage_ext.store_spam_content_hash est e);

  let pool = WP.create ~capacity:cfg.queue_capacity in
  let make_est () : CS.est =
    Mirage_crypto_rng_unix.use_default (); (* RNG for TLS in this worker domain *)
    let dbh = Pg.connect cfg.cache_db in
    let mem_dbh = Pg.connect cfg.membership_db in
    { CS.cfg = cfg.cs; dbh; mem_dbh }
  in
  (* Rebuild an est's connections after Postgres drops them (restart, network reset). Blocks the
     calling fiber, retrying every [retry]s until BOTH connections are back, so a worker stops
     spinning on a dead handle — and stops pulling new work — until the DB returns instead of
     failing every subsequent event forever. The job that triggered the loss is abandoned; the
     firehose / event-syncer re-deliver it and duplicate imports are cheap. Safe from a worker
     domain: Pg.connect uses that domain's Eio env and Eio.Time.sleep suspends on its scheduler. *)
  let reconnect_est ?(retry = 2.0) (est : CS.est) : unit =
    Importer.Stats.phase "db-reconnect";
    (try Pg.close est.CS.dbh with _ -> ());
    (try Pg.close est.CS.mem_dbh with _ -> ());
    Printf.eprintf "worker: DB connection lost; reconnecting\n%!";
    let rec attempt () =
      match
        try
          let dbh = Pg.connect cfg.cache_db in
          let mem_dbh =
            try Pg.connect cfg.membership_db
            with e ->
              (try Pg.close dbh with _ -> ());
              raise e
          in
          `Ok (dbh, mem_dbh)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn -> `Err exn
      with
      | `Ok (dbh, mem_dbh) ->
          est.CS.dbh <- dbh;
          est.CS.mem_dbh <- mem_dbh;
          Printf.eprintf "worker: DB reconnected\n%!"
      | `Err exn ->
          Printf.eprintf "worker: DB reconnect failed (%s); retry in %.0fs\n%!"
            (Printexc.to_string exn) retry;
          Eio.Time.sleep clock retry;
          attempt ()
    in
    attempt ()
  in
  (* Runs in a worker domain. Counts started/completed (for queue depth & busy-workers) and the
     import outcome; completed is bumped via Fun.protect so it covers errors and cancellation.
     [Msg] = a raw firehose line (parse + spam-check + import); [Event] = an already-parsed event
     from Event_syncer (import directly, no firehose framing or spam detector). *)
  let process (est : CS.est) (job : WP.job) =
    Importer.Stats.started stats;
    Importer.Stats.observe_queue_wait stats (Unix.gettimeofday () -. job.WP.enq_at);
    Fun.protect
      ~finally:(fun () ->
        Importer.Stats.completed stats;
        Importer.Stats.phase "idle")
      (fun () ->
        try
          let result =
            match job.WP.payload with
            | WP.Msg msg ->
                Importer.Stats.phase "spam-check";
                let now = float_of_int (Importer.Utils.current_time ()) in
                ignore (SD.on_message sd ~est msg now);
                Importer.Stats.phase "import";
                CS.import_msg_into_storage est msg
            | WP.Event e ->
                (* Synced events come from our own trusted peer nodes (already signature-verified
                   when imported there); re-running BIP340 on every one — most of them duplicates
                   we already hold — would saturate the workers and throttle the firehose. Import
                   with verification off; all other gates (kind/deleted/preimport) still apply. *)
                let est = { est with CS.cfg = { est.CS.cfg with CS.verification_enabled = false } } in
                Importer.Stats.phase "import-synced";
                CS.import_event est e
          in
          match result with
          | CS.Imported -> Importer.Stats.imported stats
          | CS.Duplicate -> Importer.Stats.duplicate stats
          | CS.Rejected -> Importer.Stats.rejected stats
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            Importer.Stats.errors stats;
            Printf.eprintf "worker: %s\n%!" (Printexc.to_string exn);
            (* A dead connection would make every subsequent event fail identically; reconnect
               (blocking until the DB is back) so this worker resumes importing. *)
            if Pg.is_connection_error exn then reconnect_est est)
  in

  Printf.printf "primal-importer: firehose %s:%d, %d workers%s\n%!" cfg.firehose_host
    cfg.firehose_port cfg.num_workers
    (match cfg.proxy with Some p -> ", proxy " ^ p | None -> "");

  (* Main-domain env + a connection for the periodic scheduled-hooks runner. *)
  Switch.run @@ fun sw ->
  Pg.set_env ~net ~sw;
  let hooks_est = make_est () in

  (* Initialise the humaness threshold from pubkey_trustrank (rank of the 50,000th-ranked
     pubkey), mirroring TrustRank.load. Done on the main domain before the worker domains spawn,
     so they all observe the final value. *)
  Importer.Cache_storage_ext.set_humaness_override cfg.humaness_threshold;
  let humaness = Importer.Cache_storage_ext.load_humaness_threshold hooks_est in
  Printf.printf "primal-importer: humaness_threshold = %g\n%!" humaness;

  (* Serving-layer notification gates (app_settings / notification_settings / mute-list / follows)
     activate only when the membership connection actually has app_settings; detect once here,
     before the worker domains spawn. *)
  let gating = Importer.Cache_storage_ext.init_notification_gating hooks_est in
  Printf.printf "primal-importer: notification serving-layer gates %s (app_settings %s in membership DB)\n%!"
    (if gating then "ON" else "OFF")
    (if gating then "present" else "absent");

  (* Device push delivery (Julia PUSH_NOTIFICATIONS_ENABLED / PushNotifications.start). The
     [enabled] ref gates the per-notification rendering in the worker domains; the [run] fiber
     below owns the sender subprocess. Set before the worker domains spawn. *)
  Importer.Push_notifications.enabled := cfg.push_notifications_enabled;
  Importer.Push_notifications.log_requests := cfg.push_notifications_log;
  Printf.printf "primal-importer: push notifications %s\n%!"
    (if cfg.push_notifications_enabled then "ON (" ^ cfg.push_notification_sender_bin ^ ")" else "OFF");

  (* Main-domain fibers share one domain, so each long-lived fiber owns an explicit Stats slot
     (the implicit per-domain [Stats.phase] is for worker domains only). *)
  let hooks_slot = Importer.Stats.new_slot "sched-hooks" in
  let run_scheduled_hooks_loop () =
    while true do
      Importer.Stats.set_slot hooks_slot "run";
      (try CS.run_scheduled_hooks hooks_est with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          Printf.eprintf "scheduled_hooks: %s\n%!" (Printexc.to_string exn);
          if Pg.is_connection_error exn then reconnect_est hooks_est);
      Importer.Stats.set_slot hooks_slot "idle";
      Eio.Time.sleep clock 60.
    done
  in

  (* Firehose callback (runs in the reader fiber): count the received line, then enqueue (which
     blocks under backpressure); count submitted once it is actually on the queue. The slot makes
     a reader stuck in [submit] (queue full, workers wedged) visible as "firehose:submit Ns" —
     otherwise it just reads as recv 0/s, indistinguishable from a quiet firehose. *)
  let reader_slot = Importer.Stats.new_slot "firehose" in
  let on_message msg =
    Importer.Stats.recv stats;
    Importer.Stats.set_slot reader_slot "submit";
    WP.submit_msg pool msg;
    Importer.Stats.set_slot reader_slot "idle";
    Importer.Stats.submitted stats
  in

  (* Event syncer: build a remote conninfo per peer host (same port/credentials as local, only the
     host differs), then run a fiber that periodically pulls recent events into the queue. *)
  let sync_remotes = List.map (fun host -> { cfg.cache_db with Pg.host }) cfg.event_sync_remotes in
  let syncer_slot = Importer.Stats.new_slot "event-syncer" in
  let run_event_syncer () =
    (* The syncer owns its connections (a dedicated local conninfo + the remotes); it must not
       reuse hooks_est.dbh, which the scheduled-hooks fiber drives concurrently. *)
    if cfg.event_sync_enabled && sync_remotes <> [] then
      Importer.Event_syncer.run ~clock ~local:cfg.cache_db ~remotes:sync_remotes
        ~submit:(fun e ->
          Importer.Stats.set_slot syncer_slot "submit";
          WP.submit_event pool e;
          Importer.Stats.set_slot syncer_slot "idle";
          Importer.Stats.submitted stats)
        ~interval:cfg.event_sync_interval ~overlap:cfg.event_sync_overlap ()
  in

  Fiber.all
    [
      (fun () ->
        WP.run
          ~on_worker_init:(fun i ->
            Importer.Stats.register_domain_slot (Printf.sprintf "w%d" i))
          ~domain_mgr ~net ~n:cfg.num_workers ~make_est ~process pool);
      (fun () ->
        Importer.Zap_verifier.run ~domain_mgr ~net ~clock ?proxy ~n:4 ~stats ~make_est
          ~reconnect_est:(fun est -> reconnect_est est) zap_pool);
      (fun () ->
        FC.run ~net ~clock ~host:cfg.firehose_host ~port:cfg.firehose_port ~on_message
          ~on_reconnect:(fun () -> Importer.Stats.reconnects stats)
          ());
      run_scheduled_hooks_loop;
      run_event_syncer;
      (fun () ->
        if cfg.push_notifications_enabled then
          Importer.Push_notifications.run ~proc_mgr ~clock ~stats ~cache_db:cfg.cache_db
            ~sender_bin:cfg.push_notification_sender_bin ~period:cfg.push_notifications_period ());
      (fun () ->
        if cfg.pushgateway_enabled then
          Importer.Pushgateway.run ~net ~clock ~stats ~host:cfg.pushgateway_host
            ~port:cfg.pushgateway_port ~job:cfg.pushgateway_job
            ~stats_file:cfg.pushgateway_stats_file ~interval:cfg.pushgateway_interval ());
      (fun () ->
        Importer.Stats.report_loop ~clock ~capacity:cfg.queue_capacity ~workers:cfg.num_workers
          stats);
    ]
