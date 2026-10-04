(* Membership-DB statements of the jobs (checked against primal_membership_ref). *)

module PGOCaml = Postgres.PGOCaml

(* trustrank_maker.jl: the seeds *)
let verified_default_pubkeys (dbh : Postgres.dbh) : string list =
  [%pgsql dbh "select pubkey from verified_users where default_name"]

(* trustrank_maker.jl: ranks zeroed *)
let blocked_pubkeys (dbh : Postgres.dbh) : string list =
  [%pgsql dbh "select target from filterlist where target_type = 'pubkey' and grp in ('spam', 'csam') and blocked group by target"]
