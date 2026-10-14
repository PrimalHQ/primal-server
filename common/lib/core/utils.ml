(* Misc helpers mirroring Julia src/utils.jl. *)

(* Julia: Utils.current_time() — wall-clock seconds since the epoch. *)
let current_time () : int = int_of_float (Unix.time ())
