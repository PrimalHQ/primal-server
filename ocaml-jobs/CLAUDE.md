# CLAUDE.md — ocaml-jobs

The background jobs daemon (`primal_jobsd`); see `README.md` and `../ocaml-plan.md` §9.

- Build/test with the shared flake: `nix develop "path:$(git rev-parse --show-toplevel)/ocaml-common" -c dune build @all`.
- **Restart with `./rebuild-restart-jobs.sh`** (stop then start; roles are singletons, never run two
  generations). Config `$PRIMAL_CONFIG_DIR/primal-jobs-config.json`, every key required.
- Roles are simple loops (`Periodic.run`), no task framework. A role that writes the same tables as
  its Julia counterpart must be either idempotent next to it or enabled only after Julia's stops.
- Cache-DB statements are `[%pgsql]`-checked against `primal1`; the importer library
  (`primal_importer`) is linked for storage code shared with it (notifications, instant indexers).
