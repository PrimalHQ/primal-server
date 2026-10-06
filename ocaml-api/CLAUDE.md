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
- Parity check after handler changes: same data, `primalctl replay <corpus.jsonl> --a ws://127.0.0.1:9009
  --b ws://<julia-host>:8831 --all --report /tmp/r.jsonl` (9009 = the shadow `primal-api-ext-shadow-config.json`
  over the Julia host's database; start it with `systemd-run --user` as the README shows). The corpus is
  the stage request log `$PRIMAL_VAR_DIR/metrics-wsconn.log` (every request is recorded there) or a
  hand-made JSONL; `primalctl sign <nsec-file> <kind> <content>` makes the signed `event_from_user` the
  membership funcalls need. The gate is ≥ 99.5 % identical per native funcall; known drifts are the
  trending feeds' follower-count batches and `get_recommended_reads` (random). Julia's live node can be
  stale relative to the source (hot-loading), so check the source before mirroring an observed quirk.
- Per-request replays cannot see transport bugs (the httpun-ws frame-queue bug hid behind 100 % identical
  answers). For anything user-visible, run the headless-browser walk: `tools/playwright.sh
  tools/webapp-walk.py wss://stage.primal.net/v1 TAG "/home,/reads,..."` (`NSEC_FILE=` for a logged-in
  session), compare two runs with `tools/webapp-compare.py`, time single requests with
  `tools/websockets.sh tools/ws-direct.py`.
- `rebuild-restart-api.sh` SIGUSR1s every `primal_apid` process it finds, the shadow included, and its last
  line ends the calling shell: run it detached (`nohup ... &`) and restart the shadow afterwards.
- New config keys are required keys: add them to `primal-api-config.json` AND `primal-api-ext-shadow-config.json`
  before rolling (`request_concurrency`, `anon_feed_cache_s` since 2026-10-06). `log_not_handled` is on for
  stage: every request forwarded to Julia is a `not handled:` line in the API log.
- Julia's `1<<62` is `max_int` here: `1 lsl 62` overflows OCaml's 63-bit int to a negative number.
- The 3b handlers follow app.jl / app_ext.jl, not the ocaml-handlers SQL: several of those SQL
  functions are wrong (README "Notes"). Julia-raised errors are NOTICE "error".
