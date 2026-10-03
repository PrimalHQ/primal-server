# SQL migrations

Applied by `../migrate.sh` in lexical order; each file runs once and is recorded in
`public.schema_migrations`. One version table is shared by every project, so number ranges are
reserved per project to keep names unique:

| Range | Project |
|---|---|
| `0001`–`0999` | `ocaml-common` (shared tables, helper functions) |
| `1000`–`1999` | `ocaml-importer` |
| `2000`–`2999` | `ocaml-api` (incl. the split of `sql/app.sql`) |
| `3000`–`3999` | `ocaml-fetcher` |
| `4000`–`4999` | `ocaml-jobs` (DAG outputs, analytics, trustrank) |
| `9000`–`9999` | private `ocaml-ext` (parent repo: studio, …) |

Rules: idempotent where cheap (`create ... if not exists`, `create or replace function`), never
edit an applied file (add a new one), prefer `create index concurrently` on hot tables, and
remember the `[%pgsql]` ppx checks against the live schema, so run migrations before `dune build`.
