(* Filterlist access, mirroring Julia's Filterlist usage but WITHOUT any in-process state.

   Per the importer's design: the `filterlist` table is READ from the local Postgres (the
   serving/cache DB the app reads from, Julia's :p0) and ADDED/UPDATED on the membership
   Postgres (the source of truth, Julia's :membership). There is no in-memory cache here — every
   predicate is a direct query and every block is a direct insert, so a fresh importer process
   immediately sees whatever the membership/DAG side has published, and its own spam decisions
   land in the membership table.

   target/grp/target_type follow the conventions used across the Julia code
   (e.g. app_ext.jl:2000, trustrank_maker.jl:94): blocked spam pubkeys/events, the unblocked
   allowlist, and the import block list. *)

module PGOCaml = Postgres.PGOCaml
open Pg_types

let i64 = Int64.of_int

(* {1 Reads — local cache DB} *)

let is_event_blocked_spam (dbh : Postgres.dbh) (eid : string) : bool =
  match
    [%pgsql dbh
      "select 1 from filterlist where target = $eid and target_type = 'event' and grp = 'spam' and blocked limit 1"]
  with
  | [] -> false
  | _ -> true

let is_pubkey_blocked_spam (dbh : Postgres.dbh) (pk : string) : bool =
  match
    [%pgsql dbh
      "select 1 from filterlist where target = $pk and target_type = 'pubkey' and grp = 'spam' and blocked limit 1"]
  with
  | [] -> false
  | _ -> true

(* Julia access_pubkey_unblocked: an explicit allowlist (blocked = false). *)
let is_pubkey_unblocked (dbh : Postgres.dbh) (pk : string) : bool =
  match
    [%pgsql dbh
      "select 1 from filterlist where target = $pk and target_type = 'pubkey' and not blocked limit 1"]
  with
  | [] -> false
  | _ -> true

(* Julia import_pubkey_blocked: pubkeys barred from import (the bad-actor groups). *)
let is_import_pubkey_blocked (dbh : Postgres.dbh) (pk : string) : bool =
  match
    [%pgsql dbh
      "select 1 from filterlist where target = $pk and target_type = 'pubkey' and blocked \
       and grp in ('spam', 'csam', 'impersonation') limit 1"]
  with
  | [] -> false
  | _ -> true

(* {1 Writes — membership DB} *)

let block ~(mem_dbh : Postgres.dbh) ?added_at ~(target : string) ~(target_type : filterlist_target)
    ~(grp : filterlist_grp) ~(comment : string) () : unit =
  let added_at = match added_at with Some a -> a | None -> i64 (Utils.current_time ()) in
  ignore
    [%pgsql mem_dbh
      "insert into filterlist (target, target_type, blocked, grp, added_at, comment) \
       values ($target, $target_type, true, $grp, $added_at, $comment) on conflict do nothing"]

let block_pubkey_spam ~mem_dbh (pk : string) ~comment =
  block ~mem_dbh ~target:pk ~target_type:Pubkey ~grp:Spam ~comment ()

let block_event_spam ~mem_dbh (eid : string) ~comment =
  block ~mem_dbh ~target:eid ~target_type:Event ~grp:Spam ~comment ()
