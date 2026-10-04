(* primal-jobs: the public build of the jobs daemon; the private build is ocaml-ext/bin. *)
let () = Primal_jobs.Daemon.run ~argv:Sys.argv ()
