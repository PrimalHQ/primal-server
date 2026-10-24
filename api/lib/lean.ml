(* The optional "lean" config object: query paths for a cache DB with a slimmer schema (no
   event_relay / event_created_at reads, counter rows that may be missing, pubkey_events with a
   kind column, ...). Absent or null = every statement exactly as before.

   {v
   "lean": {
     "enabled": true,                          the lean paths (all of the items below)
     "follows_count_from_followers": false,    user_profile follows count from pubkey_followers
     "thread_parents_from_basic_tags": false   thread parents parsed from the event's tags
   }
   v}

   The two sub-flags take effect only with [enabled]. Unknown keys are an error.

   Set once at startup ([set], before any domain or fiber reads it); read everywhere through
   [enabled] & co. *)

exception Error of string

type t = {
  enabled : bool;
  follows_count_from_followers : bool; (* C7: least(5000, count) of pubkey_followers rows *)
  thread_parents_from_basic_tags : bool; (* C13: the importer's parse_parent_eid over event tags *)
}

let off = { enabled = false; follows_count_from_followers = false; thread_parents_from_basic_tags = false }

let keys = [ "enabled"; "follows_count_from_followers"; "thread_parents_from_basic_tags" ]

let of_json (j : Yojson.Safe.t) : t =
  match j with
  | `Null -> off
  | `Assoc f ->
      List.iter (fun (k, _) -> if not (List.mem k keys) then raise (Error (Printf.sprintf "lean: unknown key %S" k))) f;
      let b k =
        match List.assoc_opt k f with
        | None | Some `Null -> false
        | Some (`Bool v) -> v
        | Some _ -> raise (Error (Printf.sprintf "lean.%s: expected a bool" k))
      in
      { enabled = b "enabled"; follows_count_from_followers = b "follows_count_from_followers";
        thread_parents_from_basic_tags = b "thread_parents_from_basic_tags" }
  | _ -> raise (Error "lean: expected an object or null")

let current : t Atomic.t = Atomic.make off
let set (t : t) = Atomic.set current t
let get () = Atomic.get current
let enabled () = (get ()).enabled
let follows_count_from_followers () = let t = get () in t.enabled && t.follows_count_from_followers
let thread_parents_from_basic_tags () = let t = get () in t.enabled && t.thread_parents_from_basic_tags

(* The kinds the importer creates an event_stats row for (cache_storage.ml is_note_kind), without
   30023 (articles answer from reads). With lazy counter rows a missing row of one of these is all
   zeros; other kinds never had a row. *)
let stats_kinds = [ 1; 1068; 6969; 20; 34235; 34236; 1111 ]

(* is_note_kind with 30023: the kinds whose events have (or, lazily, stand for) an event_stats row *)
let note_kinds = 30023 :: stats_kinds

(* the kinds the importer writes to pubkey_events (cache_storage.ml is_pubkey_event_kind) *)
let pubkey_events_kinds = [ 1; 1068; 6969; 20; 34235; 34236; 6 ]

(* sql array literals of the lists above, for statements that cannot take them as parameters *)
let sql_ints l = String.concat ", " (List.map string_of_int l)
