# SQL migrations

Applied by `../migrate.sh` in lexical order; each file runs once and is recorded in
`public.schema_migrations` (version, applied_at, applied_by host:user, file checksum, duration).
The OCaml runner is the only owner of that table: a foreign one (the bigint-versioned Ecto/sqlx
layout the retired tools left behind, as on the media host) is renamed aside with `--take-over`.
Every `rebuild-restart-*.sh` runs the runner against the host's own database before `dune build`,
so a host is never built or started against a schema behind the files; the media host builds its
query checks against the stage host's schema, so the stage host migrates first. `--status` lists
what is pending, `--record VERSION` records a change that was made by hand. One version table is
shared by every project, so number ranges are reserved per project to keep names unique:

| Range | Project |
|---|---|
| `0001`–`0999` | `ocaml-common` (shared tables, helper functions) |
| `1000`–`1999` | `ocaml-importer` |
| `2000`–`2999` | `ocaml-api` (incl. the split of `sql/app.sql`) |
| `3000`–`3999` | `ocaml-fetcher` |
| `4000`–`4999` | `ocaml-jobs` (DAG outputs, analytics, trustrank) |
| `9000`–`9999` | private `ocaml-ext` (parent repo: studio, …) |

Rules: idempotent always (`create ... if not exists`, `create or replace`, constraints behind a
`pg_constraint` check as in 0002), because a host that got a change by hand or from Julia re-runs
the file harmlessly; never edit an applied file (add a new one); `create index concurrently` on hot
tables (the runner executes statement by statement, outside a transaction, so it works) with a
`-- lock_timeout: 120s` header when the default 5 s is too short; additive only while a Julia node
still runs against the same database (it creates its tables on start and expects its columns);
and remember the `[%pgsql]` ppx checks against the live schema, so migrate before `dune build`.
