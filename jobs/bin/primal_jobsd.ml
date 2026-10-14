(* primal-jobs: the public build of the jobs daemon; the private build is ext/bin. *)
let () = Primal_jobs.Daemon.run ~argv:Sys.argv ()
