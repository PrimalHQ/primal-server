# CLAUDE.md — importer

The importer daemon (`primal_importerd.exe`): firehose -> cache DB. `README.md` has the pipeline, tables, config keys
and dev tools.

- Build with the shared flake: `nix develop "path:$(git rev-parse --show-toplevel)/nix" -c dune build @all`
  (fails if any inline `[%pgsql]` doesn't match the cache DB schema; `dune build @check` type-checks only).
- Runtime config is one JSON file, the sole argument (`primal_importerd.exe <config.json>`); the environment is not
  consulted. `--check-config` validates it. `Config.from_env` exists only for the dev tools in `tools/`.
- Run it locally with `selfhost/primal.sh` (`restart` after a rebuild); watch its per-second status line in
  `var/log/importer.log` and check the rows it writes with `selfhost/primal.sh psql`. Never run two
  importers against the same DB.
- Inline SQL targets the version-hashed base tables directly (e.g. `event`, `event_stats_1_1b380f4869`,
  `pubkey_notifications_1_e5459ab9dd`), not the logical views, so selects type as non-`option` columns and
  `ON CONFLICT` works.
- A PGOCaml connection is single-fiber: two fibers on one `dbh` corrupt the wire protocol (`42P05` /
  `ParseComplete`). Each concurrent fiber/worker owns its connection (see `Event_syncer`).
- Worker domains race on hot rows: counters that several workers touch need a unique index and one upsert
  statement (migration `sql/migrations/1001_*`); apply such migrations before building, since
  the `[%pgsql]` `ON CONFLICT` check needs the index.
- Tables that live only in the membership DB (e.g. `app_settings`, `notification_settings`) can't be
  `[%pgsql]`-checked here: query them with `Postgres.query` against the membership connection, `decode($n,'hex')`
  for bytea params, and gate the feature on the table existing (`Cache_storage_ext.init_notification_gating`).
- In a deployment the cache DB may also receive rows by logical replication, so don't assume every row came
  from this importer.
- Gap repair: `event_sync_backfill` replays a peer's `event` table into the import queue, resumable from its
  state file; set it back to `null` and restart when `backfill: done` is logged. The DAG (jobs) catches
  up afterwards in bounded windows.
- This repo is public: no deployment details (hosts, IPs, internal ports, paths) in files or commit messages.
