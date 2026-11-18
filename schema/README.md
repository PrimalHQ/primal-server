# Baseline schemas

Snapshots of the database schemas the OCaml services use. They replace the retired Julia code,
which created its tables on start, and the old `sql/app.sql` and `sql/schemas/` dumps (history: tag
`julia-final`). `cache.sql` and `media.sql` are the lean cache schema (2026-11-18), the only one the
code supports; `membership.sql` is from 2026-10-14.

- `cache.sql`: the cache DB (schema `public`), as the production cache host has it, with migrations
  1003 and 2008 applied (the classic tables gone). The extensions it uses come first (amcheck,
  dblink, hstore, pg_cron), and the `schema_migrations` rows of the migrations it already includes
  come last, so `../sql/migrate.sh` applies only the migrations added after the snapshot.
  A cache DB created from an older snapshot (before 2026-11-18) is the classic schema: migration
  1003 refuses to run on it (no `pubkey_stats` table), and the code no longer works with it. Create
  a new cache DB from this file instead; the importer fills it again (`selfhost/primal.sh`: stop,
  move `var/pg` aside, `init`, `build`, `start`).
- `membership.sql`: the part of the membership DB (`public`) that this repository's code uses: the
  tables and functions it queries (settings, notifications, filter lists, verified names, media
  uploads, memberships and tiers, ...). The rest of that DB (payments and reporting) is not part of
  this repository. Two views the API reads, `legend_users` and `premium_users`, are stand-ins built
  from `memberships` with the columns the queries use; the real ones derive them from payment
  records. The membership queries are checked against a database with this schema,
  `primal_membership_ref`, on the same server as `primal1`.
- `media.sql`: the media DB (schemas `public` and `archive`), 2026-11-18, the lean cache schema with
  migrations 1003 and 2008 applied, with its extensions first and its `schema_migrations` rows last. The objects
  that reach other hosts are left out, because they name internal addresses: three functions
  (`categorized_uploads`, `ollama`, `vals`), the `membership_server` FDW and its four foreign
  tables (`app_settings`, `media_block`, `media_uploads_media_block_csam`, `short_urls`). A few
  admin moderation functions use those tables and work once they exist.

A new cache DB:

    createdb primal1
    psql -X -d primal1 -f cache.sql        # as a superuser (CREATE EXTENSION)
    ../sql/migrate.sh                      # with PGHOST/PGPORT/PGDATABASE set

It needs the extensions listed at the top of `cache.sql` (amcheck, dblink, hstore, pg_cron).
With `ON_ERROR_STOP` off (psql's default), a statement whose extension is missing fails and the
rest loads; so does `CREATE SCHEMA public`, which a new database already has.

The membership reference DB, on the same server:

    createdb primal_membership_ref
    psql -X -d primal_membership_ref -f membership.sql

The `[%pgsql]` checks build against these databases (`../README.md`). The dev shell sets
`PGHOST`/`PGPORT` itself, so point them at another server inside the shell:

    nix develop "path:$(git rev-parse --show-toplevel)/nix" \
      -c env PGHOST=... PGPORT=... dune build @all

A build against the restored baselines alone succeeded on 2026-11-18 (`dune build @all` of the
public workspace, and `selfhost/primal.sh` from an empty PostgreSQL: init, build, start, bootstrap,
answers from the API).

Refreshing a snapshot (read-only on the source DB):

    pg_dump --schema-only --no-owner --no-privileges --no-subscriptions --no-publications \
      -n public -d primal1
    pg_dump --data-only --no-owner --inserts -t public.schema_migrations -d primal1

The 2026-11-18 snapshots were made that way from the production hosts (host-local scratch tables
left out with `-T`), restored into a throwaway cluster, migrated with `../sql/migrate.sh`, and
dumped again.

Then put the extensions (`pg_extension`) first and set the migrations' `applied_by` to `baseline`.
For the media DB: `-n public -n archive`, and keep the objects that name internal hosts out.
