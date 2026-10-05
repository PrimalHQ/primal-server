(* primal-fetcher: the relay fetcher + firehose daemon (ocaml-plan.md §8), replacing
   start_fetcher.jl. Relay connections run as fibers spread over num_domains domains; one
   processor domain dedups, verifies, archives and broadcasts; the firehose server, the
   fetcher_relays poller, the metrics pusher and the admin HTTP run on the main domain. *)

open Eio.Std
module F = Primal_fetcher

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [primal-fetcher] %s\n%!" (Procinfo.timestamp ()) s) fmt

let () =
  let cfg_path = match Sys.argv with [| _; p |] -> p | _ -> prerr_endline "usage: primal_fetcherd <config.json>"; exit 2 in
  let cfg = try F.Config.of_json_file cfg_path with F.Config.Config_error m -> prerr_endline ("primal-fetcher: config error: " ^ m); exit 2 in
  Random.self_init ();
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  Http.init_tls ();
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env and domain_mgr = Eio.Stdenv.domain_mgr env in
  Switch.run @@ fun sw ->
  Postgres.set_env ~net ~sw;
  let lifecycle = Lifecycle.create ~sw ~clock () in
  let stop = Lifecycle.stop lifecycle in
  let stats = F.Stats.create () in
  let dedup = F.Dedup.create ~keep_s:cfg.dedup_keep_s in
  let archive = if cfg.archive_enabled then Some (F.Archive.create ~root:cfg.archive_dir) else None in
  let firehose = F.Firehose.create ~capacity:cfg.firehose_queue ~stats in
  let stats_file = cfg.archive_dir ^ "/stats.json" in
  let stats_fields, stats_baseline = F.Stats.load_baseline stats_file in
  log "pid %d: config %s, node %d, firehose %s:%d, %d domains, proxy %s, archive %s" (Unix.getpid ()) cfg_path cfg.node_idx cfg.firehose_host cfg.firehose_port cfg.num_domains
    (Option.value cfg.proxy_url ~default:"none") (if cfg.archive_enabled then cfg.archive_dir else "disabled");
  (* the processor queue and the per-domain relay queues *)
  let q : F.Relay_conn.item Eio.Stream.t = Eio.Stream.create 100_000 in
  let emit it = if Eio.Stream.length q >= 100_000 then F.Stats.incr stats.processor_queue_full else Eio.Stream.add q it in
  let domains = Array.init cfg.num_domains (fun _ -> Eio.Stream.create 1_000_000) in
  let relays = F.Relay_set.create ~cfg ~stats ~domains in
  let active = ref true in
  Fiber.fork_daemon ~sw (fun () ->
      Eio.Domain_manager.run domain_mgr (fun () -> F.Processor.run ~cfg ~stats ~dedup ~archive ~firehose ~q ~stop);
      `Stop_daemon);
  Array.iteri
    (fun i (dq : F.Relay_conn.t Eio.Stream.t) ->
      Fiber.fork_daemon ~sw (fun () ->
          Eio.Domain_manager.run domain_mgr (fun () ->
              Phases.register_domain_slot (Printf.sprintf "relays-%d" i);
              let connect_sem = Eio.Semaphore.make cfg.connect_concurrency in
              Switch.run (fun dsw ->
                  let rec loop () =
                    match Fiber.first (fun () -> Some (Eio.Stream.take dq)) (fun () -> Promise.await stop; None) with
                    | Some c ->
                        Fiber.fork ~sw:dsw (fun () ->
                            try F.Relay_conn.run ~cfg ~stats ~dedup ~net ~clock ~stop ~connect_sem ~emit ~active:(fun () -> !active) c
                            with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log "relay %s: %s" c.url (Printexc.to_string exn));
                        loop ()
                    | None -> ()
                  in
                  loop ()));
          `Stop_daemon))
    domains;
  (* the firehose server *)
  let fh_fd = Listen.bind ~backlog:64 ~host:cfg.firehose_host ~port:cfg.firehose_port () in
  let fh_sock = Listen.import ~sw fh_fd in
  Fiber.fork_daemon ~sw (fun () -> F.Firehose.serve firehose ~sw ~clock ~stop fh_sock; `Stop_daemon);
  (* the relay set: files first, then the DB poller *)
  let n = F.Relay_set.add relays (F.Relay_set.load_files ~cfg) in
  log "%d relays from files" n;
  Fiber.fork_daemon ~sw (fun () -> F.Relay_set.db_poller relays ~clock ~stop; `Stop_daemon);
  (* metrics + stats.json + dedup pruning *)
  Fiber.fork_daemon ~sw (fun () ->
      let rec loop () =
        if not (Promise.is_resolved stop) then begin
          F.Stats.save stats_file stats_fields stats_baseline stats;
          (match cfg.pushgateway with
          | Some (host, port, job) -> (
              try
                Pushgateway.set_many ~net ~clock ~timeout:5.0 ~host ~port ~job
                  [ ("fetcher_message_count", "counter", Atomic.get stats.message_count); ("fetcher_exception_count", "counter", Atomic.get stats.exception_count); ("fetcher_chars_received", "counter", Atomic.get stats.chars_received);
                    ("fetcher_chars_sent", "counter", Atomic.get stats.chars_sent); ("fetcher_relays_total", "gauge", Atomic.get stats.relays_total); ("fetcher_relays_connected", "gauge", Atomic.get stats.relays_connected);
                    ("fetcher_new_events", "counter", Atomic.get stats.any); ("fetcher_firehose_dropped", "counter", Atomic.get stats.firehose_dropped); ("fetcher_rss_bytes", "gauge", Procinfo.read_rss_bytes ()) ]
              with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log "pushgateway: %s" (Printexc.to_string exn))
          | None -> ());
          let now = Utils.current_time () in
          if now - dedup.last_prune >= 60 then ignore (F.Dedup.prune dedup ~now);
          match Fiber.first (fun () -> Promise.await stop; `Stop) (fun () -> Eio.Time.sleep clock cfg.metrics_period_s; `Tick) with `Stop -> () | `Tick -> loop ()
        end
      in
      loop ();
      `Stop_daemon);
  (* periodic one-line report, as the importer logs *)
  Fiber.fork_daemon ~sw (fun () ->
      let pm = ref 0 and pa = ref 0 in
      let rec loop () =
        match Fiber.first (fun () -> Promise.await stop; `Stop) (fun () -> Eio.Time.sleep clock 10.0; `Tick) with
        | `Stop -> ()
        | `Tick ->
            let m = Atomic.get stats.message_count and a = Atomic.get stats.any in
            log "relays %d/%d/%d (providing|connected|total) connecting %d waiting %d | msgs %d/s new %d/s | seenearly %d parseerr %d verifyerr %d | fh subs %d dropped %d | qlen %d dedup %d | rss %s | wsbuf %s/%d"
              (Atomic.get stats.relays_providing) (Atomic.get stats.relays_connected) (Atomic.get stats.relays_total) (Atomic.get stats.connecting) (Atomic.get stats.relays_waiting) ((m - !pm) / 10) ((a - !pa) / 10) (Atomic.get stats.seenearly) (Atomic.get stats.parseerr) (Atomic.get stats.verifyerr)
              (F.Firehose.subscribers firehose) (Atomic.get stats.firehose_dropped) (Eio.Stream.length q) (F.Dedup.size dedup) (Procinfo.fmt_bytes (Procinfo.read_rss_bytes ())) (Procinfo.fmt_bytes (Ws_client.total_reader_capacity ())) (Ws_client.client_count ());
            pm := m;
            pa := a;
            loop ()
      in
      loop ();
      `Stop_daemon);
  let admin_fd = Listen.bind ~host:cfg.admin_host ~port:cfg.admin_port () in
  let admin_sock = Listen.import ~sw admin_fd in
  Lifecycle.serving lifecycle;
  Fiber.fork_daemon ~sw (fun () ->
      Promise.await stop;
      active := false;
      log "stopping: closing relay connections, saving resume files";
      Eio.Time.sleep clock 3.0;
      List.iter (fun (c : F.Relay_conn.t) -> if c.since <> c.saved_since then F.Resume.save ~state_dir:cfg.state_dir c.url c.since) (F.Relay_set.conns relays);
      F.Stats.save stats_file stats_fields stats_baseline stats;
      (match archive with Some a -> F.Archive.close_all a | None -> ());
      Lifecycle.stopped lifecycle;
      exit 0);
  Http_server.serve_on ~sw ~clock ~stop (F.Admin.service ~lifecycle ~cfg ~stats ~dedup ~firehose ~relays) admin_sock;
  Lifecycle.stopped lifecycle;
  exit 0
