# CLAUDE.md — ocaml-api

The Primal cache API daemon (`primal_apid`) and `primalctl`; `README.md` has the protocol, funcalls,
HTTP routes, config keys and operation.

- Build/test with the shared flake: `nix develop "path:$(git rev-parse --show-toplevel)/ocaml-common" -c dune build @all`
  (`dune test ocaml-api`). `_build/` is at the repo root.
- Run it locally with `selfhost/primal.sh` (Postgres, fetcher, importer and api; `restart` after a rebuild).
  Never start a second `primal_apid` on the same ports by hand: generations share them (SO_REUSEPORT) and
  only a drained old generation should leave. Status: `curl -s http://127.0.0.1:<admin_port>/status`.
- Config: one JSON file, all keys required except `ext` (README table); `--check-config` validates it.
  A new key means updating every config that uses this binary, including `selfhost/config/primal-api.json`.
- Handlers return values (`Response`/`Http_server.resp`); the kernel writes frames. A new funcall goes into
  the closed `Funcall.t` variant so the dispatcher's exhaustive match forces a handler. Errors raised in a
  handler become NOTICE "error"; unknown funcalls get a NOTICE.
- Never re-serialize frames you forward; zlib framing applies to native responses only.
- Per-connection fibers run on the domain that accepted the connection; do not share Eio sockets
  or PGOCaml connections across domains.
- For anything user-visible, check with the real web app as well: `tools/playwright.sh tools/webapp-walk.py
  <ws url> TAG "/home,/reads,..."` (`NSEC_FILE=` for a logged-in session), compare two runs with
  `tools/webapp-compare.py`, time single requests with `tools/websockets.sh tools/ws-direct.py`.
  `primalctl replay` compares two servers' answers over a request log.
- `1 lsl 62` overflows OCaml's 63-bit int; use `max_int` for "unbounded".
- This repo is public: no deployment details (hosts, IPs, internal ports, paths) in files or commit messages.
