(* primal-api: the public build of the API daemon; the private build is ext/bin. *)
let () = Primal_api.Daemon.run ~argv:Sys.argv ()
