(* primal-jobs: the background jobs daemon (ocaml-plan.md §9). Each configured role is one fiber
   running the loop its Julia module ran; SIGTERM/SIGINT/SIGUSR1 stop the loops at their next
   check and the process exits. *)

open Eio.Std
module J = Primal_jobs

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [primal-jobs] %s\n%!" (Procinfo.timestamp ()) s) fmt

let () =
  let cfg_path = match Sys.argv with [| _; p |] -> p | _ -> prerr_endline "usage: primal_jobsd <config.json>"; exit 2 in
  let cfg = try J.Config.of_json_file cfg_path with J.Config.Config_error m -> prerr_endline ("primal-jobs: config error: " ^ m); exit 2 in
  Random.self_init ();
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env and proc_mgr = Eio.Stdenv.process_mgr env in
  Switch.run @@ fun sw ->
  Postgres.set_env ~net ~sw;
  let lifecycle = Lifecycle.create ~sw ~clock () in
  let stop = Lifecycle.stop lifecycle in
  log "pid %d: config %s, roles %s" (Unix.getpid ()) cfg_path (String.concat "," (List.map J.Config.string_of_role cfg.roles));
  let admin_fd = Listen.bind ~host:cfg.admin_host ~port:cfg.admin_port () in
  let admin_sock = Listen.import ~sw admin_fd in
  let admin_svc = J.Admin.service ~lifecycle ~cfg in
  List.iter
    (fun role ->
      Fiber.fork_daemon ~sw (fun () ->
          Phases.register_domain_slot (J.Config.string_of_role role);
          (match role with
          | J.Config.Dvm_checker -> J.Dvm_checker.run ~cfg ~net ~clock ~stop
          | J.Config.Pg_listener -> J.Pg_listener.run ~cfg ~net ~clock ~stop
          | J.Config.Trustrank -> J.Trustrank.run ~cfg ~stop ~clock
          | J.Config.Analytics -> J.Analytics.run ~cfg ~net ~clock ~proc_mgr ~stop
          | J.Config.Dag -> J.Dag.run ~cfg ~net ~clock ~stop);
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
