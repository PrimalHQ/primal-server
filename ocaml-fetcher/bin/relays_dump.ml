(* relays_dump CONFIG: print the relay set loaded from the files (Relay_set.load_files), one per
   line — for diffing against Julia's Fetching.relays. *)
let () =
  let cfg = Primal_fetcher.Config.of_json_file Sys.argv.(1) in
  List.iter print_endline (Primal_fetcher.Relay_set.load_files ~cfg)
