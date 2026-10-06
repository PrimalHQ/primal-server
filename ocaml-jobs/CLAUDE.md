# CLAUDE.md — ocaml-jobs

The background jobs daemon (`primal_jobsd`); see `README.md` and `../ocaml-plan.md` §9.

- Build/test with the shared flake: `nix develop "path:$(git rev-parse --show-toplevel)/ocaml-common" -c dune build @all`.
- **Restart with `./rebuild-restart-jobs.sh`** (stop then start; roles are singletons, never run two
  generations). Config is the JSON file the restart script passes (`PRIMAL_JOBS_CONFIG`), every key required.
- Roles are simple loops (`Periodic.run`), no task framework. A role that writes the same tables as
  its Julia counterpart must be either idempotent next to it or enabled only after Julia's stops.
- Cache-DB statements are `[%pgsql]`-checked against `primal1`; the importer library
  (`primal_importer`) is linked for storage code shared with it (notifications, instant indexers).
- The DAG runner's window is bounded by an event count (200k, indexed) and sized from the last run's cost;
  `dag_statement_timeout_s` (optional, default 30; 600 on <stage-host>) is the DAG pools' statement limit; a restart
  begins at the nodes' contiguous coverage frontier. Nodes load a window's events into memory, so never
  hand them an unbounded window (an import burst made every run fail on the 30 s timeout).
- `rebuild-restart-jobs.sh` is stop-then-start and ends the calling shell on its last line: run it detached.
