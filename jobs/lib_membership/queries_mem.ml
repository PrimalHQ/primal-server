(* Membership-DB statements of the jobs (checked against primal_membership_ref). *)

module PGOCaml = Postgres.PGOCaml

(* trustrank_maker.jl: the seeds *)
let verified_default_pubkeys (dbh : Postgres.dbh) : string list =
  [%pgsql dbh "select pubkey from verified_users where default_name"]

(* trustrank_maker.jl: ranks zeroed *)
let blocked_pubkeys (dbh : Postgres.dbh) : string list =
  [%pgsql dbh "select target from filterlist where target_type = 'pubkey' and grp in ('spam', 'csam') and blocked group by target"]

(* {1 event_rebroadcasting.jl} *)

type rebroadcast = { rb_pubkey : string; rb_since : int64; rb_kinds : string option; rb_relays : string option; rb_batchhash : string option; rb_event_idx : int64 }

let rebroadcasts_pending (dbh : Postgres.dbh) : rebroadcast list =
  [%pgsql dbh "select pubkey, event_created_at, kinds::text, target_relays::text, batchhash, event_idx from event_rebroadcasting where started_at is not null and finished_at is null"]
  |> List.filter_map (function
       | pubkey, Some since, kinds, relays, batchhash, Some idx -> Some { rb_pubkey = pubkey; rb_since = since; rb_kinds = kinds; rb_relays = relays; rb_batchhash = batchhash; rb_event_idx = idx }
       | _ -> None)

let rebroadcast_finished (dbh : Postgres.dbh) ~pubkey : unit =
  ignore [%pgsql dbh "update event_rebroadcasting set finished_at = now(), status = 'finished fine' where pubkey = $pubkey"]

let rebroadcast_intermediate (dbh : Postgres.dbh) ~pubkey ~idx : unit =
  let idx = Int64.of_int idx in
  ignore [%pgsql dbh "update event_rebroadcasting set event_idx_intermediate = $idx where pubkey = $pubkey"]

let rebroadcast_batch_status (dbh : Postgres.dbh) ~pubkey ~(status : string) : unit =
  ignore [%pgsql dbh "update event_rebroadcasting set last_batch_status = $status where pubkey = $pubkey"]

let rebroadcast_advance (dbh : Postgres.dbh) ~pubkey ~created_at ~cnt ~batchhash : unit =
  let created_at = Int64.of_int created_at and cnt = Int64.of_int cnt in
  ignore [%pgsql dbh "update event_rebroadcasting set event_created_at = $created_at, event_idx = event_idx + $cnt, batchhash = $batchhash where pubkey = $pubkey"]

let rebroadcast_failed (dbh : Postgres.dbh) ~pubkey ~(exn : string) : unit =
  ignore [%pgsql dbh "update event_rebroadcasting set exception = $exn, finished_at = now(), status = 'failed' where pubkey = $pubkey"]

(* failover singleton *)
let try_advisory_lock (dbh : Postgres.dbh) ~(key : int) : bool =
  let key = Int64.of_int key in
  match [%pgsql dbh "select pg_try_advisory_lock($key)"] with Some b :: _ -> b | _ -> false
