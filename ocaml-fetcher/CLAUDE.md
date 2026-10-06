# CLAUDE.md — ocaml-fetcher

The relay fetcher + firehose daemon (`primal_fetcherd`); see `README.md` and `../ocaml-plan.md` §8.

- Build/test from any project dir with the shared flake:
  `nix develop "path:$(git rev-parse --show-toplevel)/ocaml-common" -c dune build @all`
  (`dune test ocaml-fetcher`). `_build/` is at the repo root.
- **Always use `./rebuild-restart-fetcher.sh` after code changes** (stop-then-start: one fetcher per
  state directory). The script prints the log path; status:
  `curl -s http://127.0.0.1:<admin_port>/status`; `/relays` lists every relay with its state.
- Config is the JSON file the restart script passes (`PRIMAL_FETCHER_CONFIG`), every key required (README table).
  The shadow and production configs differ only in ports, directories and the pushgateway job.
- The per-relay state directory names and the archive line format are contracts with the Julia
  code that consumed/produced them (`Resume`, `Julia_json`, `Processor`): change them only together
  with `maintanance.sh` / `pg-dedup-archive-funcs.sql` and the importer.
- `bin/firehose_tap.exe HOST PORT SECONDS` is the comparison tool (lines, EVENTs, distinct ids
  per second) — run it against two firehoses at once to compare fetchers.
- Never point two fetchers at the same `state_dir`/`archive_dir`.
