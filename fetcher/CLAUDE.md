# CLAUDE.md — fetcher

The relay fetcher + firehose daemon (`primal_fetcherd`); `README.md` has the design, config keys and endpoints.

- Build/test with the shared flake: `nix develop "path:$(git rev-parse --show-toplevel)/nix" -c dune build @all`
  (`dune test fetcher`). `_build/` is at the repo root.
- Run it locally with `selfhost/primal.sh` (`restart` after a rebuild). Status:
  `curl -s http://127.0.0.1:<admin_port>/status`; `/relays` lists every relay with its state.
- Config: one JSON file, the sole argument; `--check-config` validates it. The relay lists are
  `relays/` (or `relays_file`), plus the relays the importer records in `fetcher_relays`.
- The per-relay state directory names and the archive line format are read back by the fetcher itself
  (`Resume`, `Processor`) and by archive consumers: change them only together.
- `bin/firehose_tap.exe HOST PORT SECONDS` counts lines, EVENTs and distinct ids per second of a firehose;
  run it against two firehoses at once to compare fetchers. `watchdog.sh` restarts a stalled fetcher.
- Never point two fetchers at the same `state_dir`/`archive_dir`.
- This repo is public: no deployment details (hosts, IPs, internal ports, paths) in files or commit messages.
