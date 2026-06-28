(* primal-importer entry point, mirroring the wiring in start_media_importer.jl:

   - register the ext_* hooks and the LNURL zapper verifier;
   - build the spam detector and its processors (mark_spammers / mark_event_as_spam /
     store_spam_content_hash), exactly as start_media_importer.jl:150-163;
   - run a domain worker pool that, for each firehose message, runs the spam detector and
     imports the event into Postgres;
   - run the firehose client, feeding messages into the worker queue.

   Configuration comes from the environment (see lib/config.ml). *)

open Eio.Std
module CS = Importer.Cache_storage
module N = Importer.Nostr
module Pg = Importer.Postgres
module Cfg = Importer.Config
module SD = Importer.Spam_detection
module FC = Importer.Firehose_client
module WP = Importer.Worker_pool

let () =
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  let cfg = Cfg.from_env () in
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  let proxy = Cfg.proxy_endpoint cfg in

  (* ext_* hooks + LNURL zapper verification (the verifier closes over Eio net/clock/proxy). *)
  Importer.Cache_storage_ext.register ();
  CS.set_zapper_verifier (fun est ~zapped_pk ~zap_receipt ->
      Importer.Lnurl.verify ~net ~clock ?proxy est ~zapped_pk ~zapper_pubkey:zap_receipt.N.pubkey);

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
  let stats = Importer.Stats.create () in
  let make_est () : CS.est =
    Mirage_crypto_rng_unix.use_default (); (* RNG for TLS in this worker domain *)
    let dbh = Pg.connect (Pg.cache_conninfo ()) in
    let mem_dbh = Pg.connect (Pg.membership_conninfo ()) in
    { CS.cfg = cfg.cs; dbh; mem_dbh }
  in
  (* Runs in a worker domain. Counts started/completed (for queue depth & busy-workers) and the
     import outcome; completed is bumped via Fun.protect so it covers errors and cancellation. *)
  let process (est : CS.est) (msg : string) =
    Importer.Stats.started stats;
    Fun.protect ~finally:(fun () -> Importer.Stats.completed stats) (fun () ->
        try
          let now = float_of_int (Importer.Utils.current_time ()) in
          ignore (SD.on_message sd ~est msg now);
          match CS.import_msg_into_storage est msg with
          | CS.Imported -> Importer.Stats.imported stats
          | CS.Duplicate -> Importer.Stats.duplicate stats
          | CS.Rejected -> Importer.Stats.rejected stats
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            Importer.Stats.errors stats;
            Printf.eprintf "worker: %s\n%!" (Printexc.to_string exn))
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
  let humaness = Importer.Cache_storage_ext.load_humaness_threshold hooks_est in
  Printf.printf "primal-importer: humaness_threshold = %g\n%!" humaness;

  let run_scheduled_hooks_loop () =
    while true do
      (try CS.run_scheduled_hooks hooks_est with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> Printf.eprintf "scheduled_hooks: %s\n%!" (Printexc.to_string exn));
      Eio.Time.sleep clock 60.
    done
  in

  (* Firehose callback (runs in the reader fiber): count the received line, then enqueue (which
     blocks under backpressure); count submitted once it is actually on the queue. *)
  let on_message msg =
    Importer.Stats.recv stats;
    WP.submit pool msg;
    Importer.Stats.submitted stats
  in

  Fiber.all
    [
      (fun () -> WP.run ~domain_mgr ~net ~n:cfg.num_workers ~make_est ~process pool);
      (fun () ->
        FC.run ~net ~clock ~host:cfg.firehose_host ~port:cfg.firehose_port ~on_message
          ~on_reconnect:(fun () -> Importer.Stats.reconnects stats)
          ());
      run_scheduled_hooks_loop;
      (fun () ->
        Importer.Stats.report_loop ~clock ~capacity:cfg.queue_capacity ~workers:cfg.num_workers
          stats);
    ]
