(* Fiber phase slots — the visibility mechanism for long-lived fibers.

   Eio has no way to dump the stacks of suspended fibers (they are heap-allocated effect
   continuations, invisible to a debugger attached to the domain thread), so long-running fibers
   register a [slot] and record what they are doing and since when. A reporter can append any slot
   stuck non-idle > N seconds to its periodic log line, and a watchdog can dump all slots before
   exiting — turning an opaque "busy 12/12" stall into e.g. "w3: https:dns for 1840s".

   The registry is module-global so deep library code (Http) can record phases without threading a
   handle through every call. Slots are written by their owning fiber and read by the reporter,
   hence the Atomic pair. Extracted from importer's Stats; shared by every daemon. *)

type slot = { sname : string; sstate : (string * float) Atomic.t }

let slots : slot list Atomic.t = Atomic.make []

let new_slot (name : string) : slot =
  let s = { sname = name; sstate = Atomic.make ("idle", Unix.gettimeofday ()) } in
  let rec add () =
    let l = Atomic.get slots in
    if not (Atomic.compare_and_set slots l (s :: l)) then add ()
  in
  add ();
  s

let set_slot (s : slot) (phase : string) : unit =
  Atomic.set s.sstate (phase, Unix.gettimeofday ())

(* Implicit current-domain slot, for code that has no slot in scope (Http). Each worker domain
   registers one at startup; on a main domain shared by many fibers it stays unset and [phase] is a
   no-op (main-domain fibers own explicit slots instead). *)
let domain_slot : slot option Domain.DLS.key = Domain.DLS.new_key (fun () -> None)

(* Adopt an existing slot as this domain's implicit slot — for pools that create their slots up
   front (outside the domain) so they can watch them. *)
let set_domain_slot (s : slot) : unit = Domain.DLS.set domain_slot (Some s)
let register_domain_slot (name : string) : unit = set_domain_slot (new_slot name)
let slot_state (s : slot) : string * float = Atomic.get s.sstate

let phase (p : string) : unit =
  match Domain.DLS.get domain_slot with Some s -> set_slot s p | None -> ()

(* Slots currently non-idle for at least [min_age] seconds, oldest first. *)
let stuck_slots ~(min_age : float) : (string * string * float) list =
  let now = Unix.gettimeofday () in
  Atomic.get slots
  |> List.filter_map (fun s ->
         let p, since = Atomic.get s.sstate in
         let age = now -. since in
         if p <> "idle" && age >= min_age then Some (s.sname, p, age) else None)
  |> List.sort (fun (_, _, a) (_, _, b) -> Float.compare b a)

let dump_slots () : unit =
  let now = Unix.gettimeofday () in
  Atomic.get slots |> List.rev
  |> List.iter (fun s ->
         let p, since = Atomic.get s.sstate in
         Printf.printf "  %-16s %s for %.0fs\n" s.sname p (now -. since));
  flush stdout

(* One-line summary of the worst [n] stuck slots (empty string when none), for log lines. *)
let stuck_summary ?(n = 3) ~(min_age : float) () : string =
  match stuck_slots ~min_age with
  | [] -> ""
  | l ->
      let shown = List.filteri (fun i _ -> i < n) l in
      let extra = List.length l - List.length shown in
      " | STUCK "
      ^ String.concat ", "
          (List.map (fun (nm, p, age) -> Printf.sprintf "%s:%s %.0fs" nm p age) shown)
      ^ if extra > 0 then Printf.sprintf " (+%d)" extra else ""

(* All slots as text (newest-registered last), for an admin endpoint. *)
let report () : string =
  let now = Unix.gettimeofday () in
  Atomic.get slots |> List.rev
  |> List.map (fun s ->
         let p, since = Atomic.get s.sstate in
         Printf.sprintf "%-16s %s for %.0fs" s.sname p (now -. since))
  |> String.concat "\n"
