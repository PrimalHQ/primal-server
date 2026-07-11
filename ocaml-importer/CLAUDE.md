# CLAUDE.md — ocaml-importer

OCaml 5 / Eio reimplementation of the Julia Primal Nostr cache-server **importer**
(`primal-server/src/cache_storage.jl` + `cache_storage_ext.jl`). SQL is statically checked at
compile time by the PGOCaml `[%pgsql]` ppx against the live `primal1` DB. See `README.md` for the
full layout, binaries, and environment variables.

## Build / run

All dune commands run inside the project's flake dev shell. Set `P` to this directory:

```sh
P=$HOME/work/itk/primal/primal-net-server/primal-server/ocaml-importer
cd "$P"
nix develop "path:$P" -c dune build @all   # build (fails if any inline [%pgsql] mismatches primal1)
nix develop "path:$P" -c dune build @check  # type-check only
```

`PGDATABASE=primal1` (live DB) is used for BOTH compile-time SQL checking and runtime. The
reference DB `primal_importer_ref` is only for occasional tests.

## Runtime config is a JSON file, not the environment

`main.exe` reads **all** of its settings from a single JSON file given as its sole argument
(`main.exe <config.json>`); the environment is **not** consulted at runtime. The file lives at
`$HOME/work/itk/primal/primal-importer-config.json` and `rebuild-restart-importer.sh` passes it
automatically (override with `IMPORTER_CONFIG`). Every key is required. To change a runtime
setting, edit that JSON file and restart. The defaults are documented in `README.md` →
Configuration and encoded in `Config.from_env` (`lib/config.ml`), which the dev tools
(`bin/compare`, etc. — these still read the environment) use; `Config.of_json_file` loads the
file.

## Always use `rebuild-restart-importer.sh` after code/SQL changes

`./rebuild-restart-importer.sh` rebuilds with dune and, only if the build succeeds, (re)starts
`main.exe` as a detached background process (stopping any importer already running from this
project's binary — matched by full exe path, never by bare name). Its stdout+stderr go to
`$HOME/var/primalserver/ocaml-importer.log` (truncated each run); the pid and log path print to
stderr.

**Run it after any relevant change** so a freshly-built `main` is always the one running. Because
`main` writes to the live `primal1` DB, this lets you verify in real time that a change produces
the correct rows:

1. Edit code/SQL.
2. `./rebuild-restart-importer.sh` (a broken build leaves the running importer untouched).
3. Watch `tail -f $HOME/var/primalserver/ocaml-importer.log` (per-second stats, `event_syncer:`
   lines, any `worker:`/exception output) and query the DB to confirm the data is correct, e.g.
   `event`, `event_stats_1_1b380f4869`, `pubkey_notifications_1_e5459ab9dd`,
   `pubkey_notification_cnts_1_d78f6fcade`.

Don't launch `main.exe` / `dune exec bin/main.exe` by hand for iterative work — that risks two
importers writing to the same DB. The script's stop step prevents that.

## Gotchas

- Inline SQL targets primal1's **version-hashed base tables** directly (e.g. `event`,
  `event_stats_1_1b380f4869`, `pubkey_notifications_1_e5459ab9dd`) — not the logical views — so
  selects type as clean non-`option` columns and `ON CONFLICT` works.
- A PGOCaml connection is single-threaded: never let two fibers issue queries on the same `dbh`
  concurrently (it corrupts the wire protocol → `42P05` / `ParseComplete`). Each concurrent
  fiber/worker needs its own connection (see `Event_syncer`, which owns its connections).
- `primal1` also receives production data via logical replication, so a table's row count mixes
  this importer's writes with replicated rows — don't assume every recent row came from here.
- Tables that live only in the **membership DB** (e.g. `app_settings`, `notification_settings`) are
  absent from primal1, so `[%pgsql]` can't check them. Query them with `Postgres.query` (raw, no
  compile-time check) against `mem_dbh`, use `decode($n,'hex')` for bytea params, and gate the
  feature on the table actually being present (see `Cache_storage_ext.init_notification_gating`).
- `sql/refdb-truncate.sh` may only ever touch `primal_importer_ref`; never truncate `primal1`.
