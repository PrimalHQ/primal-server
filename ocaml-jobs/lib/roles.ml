(* The jobs role registry the private extensions fill (Roles.register):
   a role name in the config that is not a built-in one must be registered here before the daemon
   starts, else it is a startup failure. *)

open Eio.Std

type ctx = { cfg : Config.t; net : Eio_unix.Net.t; clock : float Eio.Time.clock_ty r; proc_mgr : Eio_unix.Process.mgr_ty r; stop : unit Promise.t }

let roles : (string, ctx -> unit) Hashtbl.t = Hashtbl.create 8

let register (name : string) (f : ctx -> unit) : unit =
  if Hashtbl.mem roles name then failwith ("Roles.register: duplicate " ^ name);
  Hashtbl.replace roles name f

let find (name : string) : (ctx -> unit) option = Hashtbl.find_opt roles name
let names () : string list = List.sort compare (List.of_seq (Hashtbl.to_seq_keys roles))
