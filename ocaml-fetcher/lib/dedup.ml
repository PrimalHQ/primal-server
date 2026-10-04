(* Time-bounded in-memory event-id set replacing the 256 SQLite shards of deduped_events: an id
   seen within [keep_s] is a duplicate (Julia: seenearly). Shared by every domain under a mutex. *)

type t = { mu : Mutex.t; tbl : (string, int) Hashtbl.t; keep_s : int; mutable last_prune : int }

let create ~keep_s = { mu = Mutex.create (); tbl = Hashtbl.create (1 lsl 20); keep_s; last_prune = 0 }

(* true when [id] is new (and records it) *)
let check_and_add (t : t) (id : string) ~(now : int) : bool =
  Mutex.protect t.mu (fun () ->
      if Hashtbl.mem t.tbl id then false
      else begin
        Hashtbl.replace t.tbl id now;
        true
      end)

let mem (t : t) (id : string) : bool = Mutex.protect t.mu (fun () -> Hashtbl.mem t.tbl id)

let prune (t : t) ~(now : int) : int =
  Mutex.protect t.mu (fun () ->
      let cutoff = now - t.keep_s in
      let n0 = Hashtbl.length t.tbl in
      Hashtbl.filter_map_inplace (fun _ seen -> if seen < cutoff then None else Some seen) t.tbl;
      t.last_prune <- now;
      n0 - Hashtbl.length t.tbl)

let size (t : t) : int = Mutex.protect t.mu (fun () -> Hashtbl.length t.tbl)
