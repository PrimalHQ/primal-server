(* The importer's optional "lean" settings (config key [lean], a JSON object; absent or null = all
   off = the classic write path, statement for statement) and the pure helpers its code paths use:
   the kind allowlist, the NIP-01 "newer version" order, the bookmark diff, per-domain TTL caches
   and the cross-domain set of recently superseded ids. No database access here, so it is unit
   tested in importer/test. The flags are documented in importer/README.md ("Lean mode"). *)

module IS = Set.Make (Int)

type t = {
  enabled : bool;
      (* refactors with identical results: fewer statements, no repeated reads, merged counter
         updates, TTL caches, ids-first event sync, event_hooks expiry *)
  no_event_created_at : bool; (* stop writing event_created_at *)
  no_hashtags : bool; (* stop writing hashtags (+ its scheduled_hooks expiry); event_hashtags stays *)
  no_pubkey_ids : bool; (* stop reading/writing pubkey_ids *)
  no_thread_parents : bool; (* stop writing event_thread_parents (reply chains walked from tags) *)
  no_cmr_legacy : bool; (* stop writing cmr_pubkeys_parent, cmr_words, cmr_hashtags *)
  lazy_counters : bool; (* no zero rows in event_stats / pubkey_followers_cnt / pubkey_zapped *)
  pubkey_events_kind : bool; (* write pubkey_events.kind *)
  transaction_per_event : bool; (* an event's side effects in one transaction *)
  delete_superseded : bool; (* delete the previous version of a replaceable/addressable event *)
  keep_versions_kinds : int list; (* ... except these kinds (default [30023]) *)
  kind_allowlist : IS.t option; (* kinds 0, 3, 10000-19999, 30000-39999 imported only if listed *)
  hooks_expire_days : int; (* pending event_hooks older than this are deleted (with [enabled]) *)
}

let off =
  {
    enabled = false;
    no_event_created_at = false;
    no_hashtags = false;
    no_pubkey_ids = false;
    no_thread_parents = false;
    no_cmr_legacy = false;
    lazy_counters = false;
    pubkey_events_kind = false;
    transaction_per_event = false;
    delete_superseded = false;
    keep_versions_kinds = [ 30023 ];
    kind_allowlist = None;
    hooks_expire_days = 30;
  }

(* Any flag on: import_event takes the lean path (whose flag-off branches are the classic code). *)
let active (l : t) : bool =
  l.enabled || l.no_event_created_at || l.no_hashtags || l.no_pubkey_ids || l.no_thread_parents
  || l.no_cmr_legacy || l.lazy_counters || l.pubkey_events_kind || l.transaction_per_event
  || l.delete_superseded || l.kind_allowlist <> None

let keys =
  [ "enabled"; "no_event_created_at"; "no_hashtags"; "no_pubkey_ids"; "no_thread_parents"; "no_cmr_legacy";
    "lazy_counters"; "pubkey_events_kind"; "transaction_per_event"; "delete_superseded"; "keep_versions_kinds";
    "kind_allowlist"; "hooks_expire_days" ]

(* Parse the [lean] object. Every key is optional (absent or null = default); an unknown key or a
   wrongly typed value is an error, so a typo can't silently leave a flag off. *)
let of_json (j : Yojson.Safe.t) : (t, string) result =
  match j with
  | `Null -> Ok off
  | `Assoc kv -> (
      match List.find_opt (fun (k, _) -> not (List.mem k keys)) kv with
      | Some (k, _) -> Error (Printf.sprintf "lean: unknown key %S" k)
      | None -> (
          let get k = match List.assoc_opt k kv with None | Some `Null -> None | Some v -> Some v in
          let bool k d =
            match get k with None -> d | Some (`Bool b) -> b | Some _ -> failwith (Printf.sprintf "lean.%s: expected a bool" k)
          in
          let int_list k =
            match get k with
            | None -> None
            | Some (`List l) ->
                Some (List.map (function `Int i -> i | _ -> failwith (Printf.sprintf "lean.%s: expected ints" k)) l)
            | Some _ -> failwith (Printf.sprintf "lean.%s: expected a list of ints" k)
          in
          try
            Ok
              {
                enabled = bool "enabled" false;
                no_event_created_at = bool "no_event_created_at" false;
                no_hashtags = bool "no_hashtags" false;
                no_pubkey_ids = bool "no_pubkey_ids" false;
                no_thread_parents = bool "no_thread_parents" false;
                no_cmr_legacy = bool "no_cmr_legacy" false;
                lazy_counters = bool "lazy_counters" false;
                pubkey_events_kind = bool "pubkey_events_kind" false;
                transaction_per_event = bool "transaction_per_event" false;
                delete_superseded = bool "delete_superseded" false;
                keep_versions_kinds = Option.value (int_list "keep_versions_kinds") ~default:off.keep_versions_kinds;
                kind_allowlist = Option.map IS.of_list (int_list "kind_allowlist");
                hooks_expire_days =
                  (match get "hooks_expire_days" with
                  | None -> off.hooks_expire_days
                  | Some (`Int d) when d > 0 -> d
                  | Some _ -> failwith "lean.hooks_expire_days: expected a positive int");
              }
          with Failure msg -> Error msg))
  | _ -> Error "lean: expected an object or null"

(* {1 Kinds} *)

(* The kinds the allowlist governs: metadata, contact lists, replaceable and addressable kinds.
   Regular kinds keep the importer's accepted_kind. *)
let allowlist_governs (k : int) : bool = k = 0 || k = 3 || (10000 <= k && k < 20000) || (30000 <= k && k < 40000)

let kind_allowed (l : t) (k : int) : bool =
  match l.kind_allowlist with None -> true | Some s -> (not (allowlist_governs k)) || IS.mem k s

(* Kinds whose versions replace each other (one current version per pointer). *)
let is_versioned_kind (k : int) : bool = k = 0 || k = 3 || (10000 <= k && k < 20000) || (30000 <= k && k < 40000)

let keeps_versions (l : t) (k : int) : bool = List.mem k l.keep_versions_kinds

(* NIP-01: of two versions, the one with the greater created_at wins; on a tie, the lower id. Ids
   are raw 32-byte strings, whose byte order is the order of their hex. *)
let newer ~(created_at : int) ~(id : string) ~(old_created_at : int) ~(old_id : string) : bool =
  created_at > old_created_at || (created_at = old_created_at && String.compare id old_id < 0)

(* {1 pubkey_bookmarks diff}

   The classic path deletes all of a user's rows and inserts one (pubkey, ref_event_id, null, null,
   null) row per e tag, duplicates included. [existing] is what the table holds now, as
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

(* {1 Recently superseded ids} (with [delete_superseded])

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
