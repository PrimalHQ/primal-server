# SQL migrations

Versioned schema changes for the databases the OCaml daemons use, applied by `../migrate.sh`:

    sql/migrate.sh [--dry-run | --status | --record VERSION | --take-over] [MIGRATIONS_DIR]

The connection comes from the standard `PG*` variables (the dev shell points them at its local
`primal1`); `psql` must be in `PATH` (it is in the dev shell). The runner applies every
`NNNN_name.sql` in this directory that is not yet recorded, in lexical order, each with
`psql -v ON_ERROR_STOP=1 -f`: statement by statement, without a wrapping transaction. Each applied
file is recorded in `public.schema_migrations`: version (the file name without `.sql`),
`applied_at`, `applied_by` (`host:user`), checksum (the first 16 hex digits of the file's sha256),
`duration_ms`. The table is created if missing.

- `--dry-run` lists the pending files and applies nothing.
- `--status` prints the applied count and the pending files; exit status 1 when something is
  pending.
- `--record VERSION` records a file as applied without running it, for a change made by hand.
- `--take-over`: the runner is the only owner of `public.schema_migrations`. If that table exists
  with a non-text `version` column (another tool's layout, such as Ecto's or sqlx's bigint
  versions), the runner aborts; with `--take-over` it renames the table to
  `schema_migrations_legacy_<date>` and creates its own.

Every file runs with a `lock_timeout` of 5 s, so DDL fails fast instead of queueing behind a long
query while the daemons keep serving. A file that needs longer declares it in a header comment
within its first 10 lines:

    -- lock_timeout: 120s

The baseline `../../schema/cache.sql` ends with the `schema_migrations` rows of the migrations it
already contains, so on a database created from it the runner applies only the newer files.

The deployment runs `migrate.sh` against each host's database before starting the services, the
stage DB first.

## Number ranges

One version table is shared by every project, so each project has its own range to keep names
unique:

| Range | Project |
|---|---|
| `0001`–`0999` | `common` (shared tables, helper functions) |
| `1000`–`1999` | `importer` |
| `2000`–`2999` | `api` (including changes to the SQL functions in `../../schema/cache.sql`) |
| `3000`–`3999` | `fetcher` |
| `4000`–`4999` | `jobs` (DAG outputs, analytics, TrustRank, the media role) |
| `9000`–`9999` | private `ext` |

## Rules

- Idempotent always (`create ... if not exists`, `create or replace`, constraints behind a
  `pg_constraint` check as in `0002`): a database that already got the change by hand re-runs the
  file harmlessly.
- The same files run against every host's database, whose tables differ (the media DB's
  `processing_nodes`, for example, is not in the cache DB). A change to a table that only some
  databases have tests for it first, with `\gset` and `\if` (see `4001`).
- Never edit an applied file; add a new one.
- On hot tables use `create index concurrently if not exists` (it works because the runner uses no
  transaction), with a `-- lock_timeout:` header when 5 s is too short. A concurrent build that
  failed half-way leaves an invalid index that `if not exists` would keep: drop it first when it is
  invalid (see `2002`, `4001`).
- The `[%pgsql]` ppx checks statements against the schema of the database it builds against, so
  apply a migration there before building code that depends on it.
