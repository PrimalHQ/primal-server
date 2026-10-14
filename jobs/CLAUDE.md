# CLAUDE.md — jobs

The background jobs daemon (`primal_jobsd`): DAG, TrustRank, analytics, DVM checker, rebroadcasting and
the media role (processing graph, uploads, Blossom); `README.md` has the roles and config keys.

- Build/test with the shared flake: `nix develop "path:$(git rev-parse --show-toplevel)/common" -c dune build @all`.
- Config: one JSON file, the sole argument; `--check-config` validates it. Roles are singletons: stop the
  old process before starting a new one, never run two generations.
- Roles are simple loops (`Periodic.run`), no task framework. A role that writes shared tables must be
  idempotent or the only writer.
- Cache-DB statements are `[%pgsql]`-checked; the importer library (`primal_importer`) is linked for storage
  code shared with it (notifications, instant indexers). Media-DB SQL is dynamic (`Postgres.query`).
- The DAG runner's window is bounded by an event count (200k, indexed) and sized from the last run's cost;
  `dag_statement_timeout_s` (default 30) is the DAG pools' statement limit; a restart begins at the nodes'
  contiguous coverage frontier. Nodes load a window's events into memory, so never hand them an unbounded
  window (an import burst made every run fail on the statement timeout).
- The media role fetches untrusted URLs: through `media.proxies` / `metadata_proxy`, or directly only to
  public addresses (`Media_tools.connect`).
- This repo is public: no deployment details (hosts, IPs, internal ports, paths) in files or commit messages.
