(* Per-domain PostgreSQL pools (ocaml-plan.md §4.2). PGOCaml connections are domain-bound, so every
   worker domain owns its own pools; a request runs on the domain that accepted its connection and
   leases from that domain's pools. Phantom tags keep cache and membership handles apart at the type
   level: a membership query cannot be run on a cache lease.

   Sizes mirror ws-connector / ws-handlers: cache pool with statement_timeout 30 s, membership pool
   without one, plus a small management pool (wsconnvars) on the main domain. *)

type cache
type membership
type 'db pool = Pool : Postgres.pool -> 'db pool [@@unboxed]
type 'db conn = Conn : Postgres.dbh -> 'db conn [@@unboxed]

let raw (Conn d : 'db conn) : Postgres.dbh = d
let use ?acquire (Pool p : 'db pool) (f : 'db conn -> 'a) : 'a = Postgres.use ?acquire p (fun dbh -> f (Conn dbh))

type pools = { cache : cache pool; membership : membership pool }

let key : pools option Domain.DLS.key = Domain.DLS.new_key (fun () -> None)

(* Create this domain's pools (lazy connections). Call once per domain after Postgres.set_env. *)
let init ~(cache_db : Postgres.conninfo) ~(membership_db : Postgres.conninfo) ~(cache_size : int)
    ~(membership_size : int) : unit =
  let cache = Pool (Postgres.make_pool ~size:cache_size cache_db) in
  let membership = Pool (Postgres.make_pool ~size:membership_size membership_db) in
  Domain.DLS.set key (Some { cache; membership })

let pools () : pools =
  match Domain.DLS.get key with Some p -> p | None -> failwith "Db: pools not initialised in this domain"

let cache () : cache pool = (pools ()).cache
let membership () : membership pool = (pools ()).membership

(* ws-connector's pool.get() timeout: 15 s waiting for a free connection -> "Database pool timeout".
   The timeout bounds the wait for the lease only; the callback runs unbounded (Postgres.use). *)
let pool_get_timeout = 15.0

exception Pool_timeout = Postgres.Pool_timeout

let with_cache ~clock (f : cache conn -> 'a) : 'a = use ~acquire:(clock, pool_get_timeout) (cache ()) f
let with_membership ~clock (f : membership conn -> 'a) : 'a = use ~acquire:(clock, pool_get_timeout) (membership ()) f
