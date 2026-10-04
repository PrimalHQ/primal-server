# CLAUDE.md — ocaml-api

The Primal cache API daemon (`primal_apid`) and `primalctl`; see `README.md` and `../ocaml-plan.md` §5.

- Build/test from any project dir with the shared flake:
  `nix develop "path:$(git rev-parse --show-toplevel)/ocaml-common" -c dune build @all`
  (`dune test`). `_build/` is at the repo root.
- **Always use `./rebuild-restart-api.sh` after code changes.** It does a rolling restart (new
  generation first, old one drained with SIGUSR1); never launch `primal_apid.exe` by hand next to a
  running generation on the same port. Log: `$PRIMAL_VAR_DIR/ocaml-api.log`; status:
  `curl -s http://127.0.0.1:14006/status`.
- Config is `$PRIMAL_CONFIG_DIR/primal-api-config.json`, every key required (README table).
- Protocol parity rules: never re-serialize upstream frames; `set_primal_protocol` is answered
  locally and not forwarded; zlib only for native responses; NOTICE texts must match Julia's.
- Handlers return values (`Response`/`Http_server.resp`); the kernel writes frames. When adding a
  funcall, add it to the closed `Funcall.t` variant (Phase 3) so the dispatcher's exhaustive match
  forces a handler or an explicit proxy arm.
- Per-connection fibers run on the domain that accepted the connection; do not share Eio sockets
  or PGOCaml connections across domains.
