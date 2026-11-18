(* The importer's import rules for the lean cache schema (infrastructure
   docs/proposal-lean-schema-iteration2-20261026.md) and the pure helpers its code paths use: the
   kind allowlist, the NIP-01 "newer version" order, the bookmark diff, per-domain TTL caches and the
   cross-domain set of recently superseded ids. No database access here, so it is unit tested in
   importer/test. The config keys are documented in importer/README.md ("Import rules").

   Until 2026-11 these were flags of an optional "lean" config object (absent = the classic schema's
   write path); the classic path is gone, and only the four parameters below remain, as top-level
   config keys. *)

module IS = Set.Make (Int)

type t = {
  kind_allowlist : IS.t; (* kinds 0, 3, 10000-19999, 30000-39999 imported only if listed *)
  keep_versions_kinds : int list; (* replaceable/addressable kinds whose superseded versions stay *)
  hooks_expire_days : int; (* pending event_hooks older than this are deleted *)
  contact_list_versions : int;
      (* > 0: kind 3 keeps the versions membership_recovery_contact_lists shows (the longest list of
         each of the newest this-many days) and the current one, the rest deleted; 0 = like any kind *)
}

(* The production values (2026-11). *)
let default_kind_allowlist =
  [ 0; 3; 10000; 10002; 10003; 10063; 10555; 17000; 30000; 30004; 30023; 30311; 31234; 31990; 34235; 34236; 37001; 39089 ]

let default =
  { kind_allowlist = IS.of_list default_kind_allowlist; keep_versions_kinds = [ 30023 ]; hooks_expire_days = 30;
    contact_list_versions = 30 }

let keys = [ "kind_allowlist"; "keep_versions_kinds"; "hooks_expire_days"; "contact_list_versions" ]

(* The four optional top-level keys of the importer config (absent or null = default). A wrongly
   typed value is an error; so is the retired "lean" object. *)
let of_config (kv : (string * Yojson.Safe.t) list) : (t, string) result =
  let get k = match List.assoc_opt k kv with None | Some `Null -> None | Some v -> Some v in
  let int_list k =
    match get k with
    | None -> None
    | Some (`List l) -> Some (List.map (function `Int i -> i | _ -> failwith (Printf.sprintf "%s: expected ints" k)) l)
    | Some _ -> failwith (Printf.sprintf "%s: expected a list of ints" k)
  in
  if List.mem_assoc "lean" kv then
    Error
      "lean: the \"lean\" object is gone (the lean schema is the only one); drop it and set kind_allowlist, \
       keep_versions_kinds, hooks_expire_days, contact_list_versions at the top level if they differ from the defaults"
  else
    try
      Ok
        {
          kind_allowlist = IS.of_list (Option.value (int_list "kind_allowlist") ~default:default_kind_allowlist);
          keep_versions_kinds = Option.value (int_list "keep_versions_kinds") ~default:default.keep_versions_kinds;
          hooks_expire_days =
            (match get "hooks_expire_days" with
            | None -> default.hooks_expire_days
            | Some (`Int d) when d > 0 -> d
            | Some _ -> failwith "hooks_expire_days: expected a positive int");
          contact_list_versions =
            (match get "contact_list_versions" with
            | None -> default.contact_list_versions
            | Some (`Int n) when n >= 0 -> n
            | Some _ -> failwith "contact_list_versions: expected a non-negative int");
        }
    with Failure msg -> Error msg

(* {1 Kinds} *)

(* The kinds the allowlist governs: metadata, contact lists, replaceable and addressable kinds.
   Regular kinds keep the importer's accepted_kind. *)
let allowlist_governs (k : int) : bool = k = 0 || k = 3 || (10000 <= k && k < 20000) || (30000 <= k && k < 40000)

let kind_allowed (l : t) (k : int) : bool = (not (allowlist_governs k)) || IS.mem k l.kind_allowlist

(* Kinds whose versions replace each other (one current version per pointer). *)
let is_versioned_kind (k : int) : bool = k = 0 || k = 3 || (10000 <= k && k < 20000) || (30000 <= k && k < 40000)

let keeps_versions (l : t) (k : int) : bool = List.mem k l.keep_versions_kinds || (k = 3 && l.contact_list_versions > 0)

(* NIP-01: of two versions, the one with the greater created_at wins; on a tie, the lower id. Ids
   are raw 32-byte strings, whose byte order is the order of their hex. *)
let newer ~(created_at : int) ~(id : string) ~(old_created_at : int) ~(old_id : string) : bool =
  created_at > old_created_at || (created_at = old_created_at && String.compare id old_id < 0)

(* {1 pubkey_bookmarks diff}

   pubkey_bookmarks holds one (pubkey, ref_event_id, null, null, null) row per e tag of the user's
   bookmark list, duplicates included (what deleting all of a user's rows and re-inserting gave). [existing] is what the table holds now, as
   (ref_event_id, plain) with plain = the three other ref columns are null; [desired] the e-tag ids
   in order. The result turns [existing] into exactly that multiset: delete every non-plain row (and
   rows with a null ref_event_id) when there are any, delete all rows of an id whose count must
   shrink (then re-insert its desired count), insert the missing ones. *)
type bookmark_diff = { del_nonplain : bool; del_ids : string list; ins : string list }

let bookmark_diff ~(existing : (string option * bool) list) ~(desired : string list) : bookmark_diff =
  let count l =
    let h = Hashtbl.create 16 in
    List.iter (fun x -> Hashtbl.replace h x (1 + Option.value (Hashtbl.find_opt h x) ~default:0)) l;
    h
  in
  let del_nonplain = List.exists (fun (id, plain) -> id = None || not plain) existing in
  let have = count (List.filter_map (fun (id, plain) -> if plain then id else None) existing) in
  let want = count desired in
  let del_ids = ref [] and ins = ref [] in
  let order = List.sort_uniq compare (Hashtbl.fold (fun k _ acc -> k :: acc) have [] @ desired) in
  List.iter
    (fun id ->
      let h = Option.value (Hashtbl.find_opt have id) ~default:0 and w = Option.value (Hashtbl.find_opt want id) ~default:0 in
      if h > w then begin
        del_ids := id :: !del_ids;
        for _ = 1 to w do ins := id :: !ins done
      end
      else for _ = 1 to w - h do ins := id :: !ins done)
    order;
  { del_nonplain; del_ids = List.rev !del_ids; ins = List.rev !ins }

(* {1 Per-domain TTL caches}

   Each worker domain keeps its own table (Domain.DLS), so no locking; fibers on one domain don't
   yield inside a lookup. A failing [compute] caches nothing. The table is dropped whole when it
   reaches [max] entries (cheap, and it refills within one TTL). *)
module Ttl = struct
  type ('k, 'v) t = { tbl : ('k, float * 'v) Hashtbl.t Domain.DLS.key; ttl : float; max : int }

  let create ?(max = 200_000) ~(ttl : float) () : ('k, 'v) t =
    { tbl = Domain.DLS.new_key (fun () -> Hashtbl.create 1024); ttl; max }

  let find_or_add ?(now = Unix.gettimeofday ()) (t : ('k, 'v) t) (k : 'k) (compute : unit -> 'v) : 'v =
    let h = Domain.DLS.get t.tbl in
    match Hashtbl.find_opt h k with
    | Some (exp, v) when exp > now -> v
    | _ ->
        let v = compute () in
        if Hashtbl.length h >= t.max then Hashtbl.reset h;
        Hashtbl.replace h k (now +. t.ttl, v);
        v

  let clear (t : ('k, 'v) t) : unit = Hashtbl.reset (Domain.DLS.get t.tbl)
end

(* {1 Recently superseded ids}

   A version deleted as superseded is gone from [event], so the atomic claim would accept it again
   when a peer's syncer (or the firehose) delivers it once more, only for the pointer check to delete
   it again. This bounded set, shared by all domains, lets import_event drop such a copy before the
   claim. Purely an optimisation: a miss costs one insert + delete. *)
module Superseded = struct
  let mu = Mutex.create ()
  let tbl : (string, float) Hashtbl.t = Hashtbl.create 4096
  let ttl = 3600.0
  let max = 500_000

  let add ?(now = Unix.gettimeofday ()) (id : string) : unit =
    Mutex.protect mu (fun () ->
        if Hashtbl.length tbl >= max then Hashtbl.reset tbl;
        Hashtbl.replace tbl id (now +. ttl))

  let mem ?(now = Unix.gettimeofday ()) (id : string) : bool =
    Mutex.protect mu (fun () ->
        match Hashtbl.find_opt tbl id with
        | Some exp when exp > now -> true
        | Some _ ->
            Hashtbl.remove tbl id;
            false
        | None -> false)
end

(* {1 Counters} reported by the status line and the pushgateway exporter. *)
let kind_rejected = Atomic.make 0 (* events refused by [kind_allowlist] (also counted as rejected) *)
let superseded_deleted = Atomic.make 0 (* event rows deleted as superseded versions *)
let tx_retries = Atomic.make 0 (* event transactions retried after a deadlock/serialization failure *)
let tx_fallbacks = Atomic.make 0 (* event transactions abandoned for the autocommit path *)
