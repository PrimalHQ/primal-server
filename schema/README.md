# Baseline schemas

Snapshots (2026-10-14) of the database schemas the OCaml services use. They replace the retired
Julia code, which created its tables on start, and the old `sql/app.sql` and `sql/schemas/` dumps
(history: tag `julia-final`).

- `cache.sql`: the cache DB, schemas `public` and `cache`. The extensions it uses come first, and
  the `schema_migrations` rows of the migrations it already includes come last, so
  `../sql/migrate.sh` applies only the migrations added after the snapshot.
- `membership.sql`: the membership DB (`public`). The membership queries are checked against a
  database with this schema, `primal_membership_ref`, on the same server as `primal1`.
- `media.sql`: the media DB (schemas `public` and `archive`), with its extensions first. The objects
  that reach other hosts are left out, because they name internal addresses: three functions
  (`categorized_uploads`, `ollama`, `vals`), the `membership_server` FDW and its four foreign
  tables (`app_settings`, `media_block`, `media_uploads_media_block_csam`, `short_urls`). A few
  admin moderation functions use those tables and work once they exist. Its `schema_migrations`
  table has no rows (`schema_migrations_legacy_20261008` is the version table of a retired tool),
  so on a database created from it `../sql/migrate.sh` treats every migration as pending (the
  files are idempotent by rule, `../sql/migrations/README.md`).

A new cache DB:

    createdb primal1
    psql -X -d primal1 -f cache.sql        # as a superuser (CREATE EXTENSION)
    ../sql/migrate.sh                      # with PGHOST/PGPORT/PGDATABASE set

It needs the extensions listed at the top of `cache.sql` (pgvector, pg_cron, plv8, http, ...).
With `ON_ERROR_STOP` off (psql's default), a statement whose extension is missing fails and the
rest loads; so does `CREATE SCHEMA public`, which a new database already has.

The membership reference DB, on the same server:

    createdb primal_membership_ref
    psql -X -d primal_membership_ref -f membership.sql

The `[%pgsql]` checks build against these databases (`../README.md`). The dev shell sets
`PGHOST`/`PGPORT` itself, so point them at another server inside the shell:

    nix develop "path:$(git rev-parse --show-toplevel)/common" \
      -c env PGHOST=... PGPORT=... dune build @all

A build against the restored baselines alone succeeded on 2026-10-14.

Refreshing a snapshot (read-only on the source DB):

    pg_dump --schema-only --no-owner --no-privileges --no-subscriptions --no-publications \
      -n public -n cache -d primal1
    pg_dump --data-only --no-owner --inserts -t public.schema_migrations -d primal1

Then put the extensions (`pg_extension`) first and set the migrations' `applied_by` to `baseline`.
For the media DB: `-n public -n archive`, and keep the objects that name internal hosts out.
