(* The jobs daemon (ocaml-plan.md §9): each configured role is one fiber running the loop its Julia
   module ran; SIGTERM/SIGINT/SIGUSR1 stop the loops at their next check and the process exits.
   bin/primal_jobsd.ml and the private ocaml-ext/bin call [run]; the latter registers its roles in
   [init]. *)

open Eio.Std

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [primal-jobs] %s\n%!" (Procinfo.timestamp ()) s) fmt

let run ~(argv : string array) ?(init : Config.t -> unit = fun _ -> ()) () : unit =
  let cfg_path = match argv with [| _; p |] -> p | _ -> prerr_endline "usage: primal_jobsd <config.json>"; exit 2 in
  let cfg = try Config.of_json_file cfg_path with Config.Config_error m -> prerr_endline ("primal-jobs: config error: " ^ m); exit 2 in
  (try init cfg with exn -> prerr_endline ("primal-jobs: extension init failed: " ^ Printexc.to_string exn); exit 2);
  List.iter (function Config.Ext name when Roles.find name = None -> prerr_endline ("primal-jobs: role " ^ name ^ " is not registered (roles: " ^ String.concat "," (Roles.names ()) ^ ")"); exit 2 | _ -> ()) cfg.roles;
  Random.self_init ();
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env and proc_mgr = Eio.Stdenv.process_mgr env in
  Switch.run @@ fun sw ->
  Postgres.set_env ~net ~sw;
  let lifecycle = Lifecycle.create ~sw ~clock () in
  let stop = Lifecycle.stop lifecycle in
  log "pid %d: config %s, roles %s" (Unix.getpid ()) cfg_path (String.concat "," (List.map Config.string_of_role cfg.roles));
  let admin_fd = Listen.bind ~host:cfg.admin_host ~port:cfg.admin_port () in
  let admin_sock = Listen.import ~sw admin_fd in
  let admin_svc = Admin.service ~lifecycle ~cfg in
  List.iter
    (fun role ->
      Fiber.fork_daemon ~sw (fun () ->
          Phases.register_domain_slot (Config.string_of_role role);
          (match role with
          | Config.Dvm_checker -> Dvm_checker.run ~cfg ~net ~clock ~stop
          | Config.Pg_listener -> Pg_listener.run ~cfg ~net ~clock ~stop
          | Config.Trustrank -> Trustrank.run ~cfg ~stop ~clock
          | Config.Analytics -> Analytics.run ~cfg ~net ~clock ~proc_mgr ~stop
          | Config.Dag -> Dag.run ~cfg ~net ~clock ~stop
          | Config.Rebroadcast -> Rebroadcast.run ~cfg ~net ~clock ~stop
          | Config.Failover -> Failover.run ~cfg ~net ~clock ~stop
          | Config.Media -> (
              match cfg.media with
              | Some m -> Primal_jobs_media.Media_role.run ~cfg:m ~cache_db:cfg.cache_db ~membership_db:cfg.membership_db ~net ~clock ~proc_mgr ~stop
              | None -> log "media role: the config has no \"media\" object")
          | Config.Ext name -> ( match Roles.find name with Some f -> f { Roles.cfg; net; clock; proc_mgr; stop } | None -> log "role %s not registered" name));
          `Stop_daemon))
    cfg.roles;
  Lifecycle.serving lifecycle;
  Fiber.fork_daemon ~sw (fun () ->
      Promise.await stop;
      log "stopping";
      Eio.Time.sleep clock 1.0;
      Lifecycle.stopped lifecycle;
      exit 0);
  Http_server.serve_on ~sw ~clock ~stop admin_svc admin_sock;
  Lifecycle.stopped lifecycle;
  exit 0
