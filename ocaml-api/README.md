# primal-api

The Primal cache API daemon in OCaml 5 / Eio (`ocaml-plan.md` §5): the WebSocket cache API that
clients reach on port 9001 (and the per-node 8800+N ports), later the HTTP services (14000+N,
24000+N, Blossom 21000+N). It replaces the Rust `ws-connector` and the Julia `CacheServer`,
`InternalServices` and `Blossom`.

**Status (Phase 2):** skeleton. Serves the WebSocket port from N domains, answers
`set_primal_protocol` and `server_name` natively, and proxies every other frame verbatim to the
Julia CacheServer (`upstream_julia_ws`), exactly as ws-connector does (`set_primal_protocol` is
not forwarded; zlib applies to native answers only). Runs as a shadow on port 9006 next to the
production ws-connector on 9001.

## Build / run

```sh
C=$(git rev-parse --show-toplevel)/ocaml-common   # the shared toolchain flake
nix develop "path:$C" -c dune build @all        # whole workspace; _build/ is at the repo root
nix develop "path:$C" -c dune test
./rebuild-restart-api.sh                        # build + rolling restart (see below)
```

Binaries: `_build/default/ocaml-api/bin/primal_apid.exe <config.json>` (the daemon) and
`primalctl.exe` (operator CLI).

## Configuration (`$PRIMAL_CONFIG_DIR/primal-api-config.json`, every key required)

| Key | Example | Purpose |
|---|---|---|
| `servername` | `"wscm"` | answered by `server_name` (ws-connector `--servername`) |
| `public_ws_host` / `public_ws_port` | `"0.0.0.0"` / `9006` | the cache API WebSocket (9001 in production) |
| `admin_host` / `admin_port` | `"127.0.0.1"` / `14006` | admin HTTP (below) |
| `num_domains` | `4` | worker domains; each runs an accept loop on the shared SO_REUSEPORT socket |
| `upstream_julia_ws` | `"ws://127.0.0.1:8817"` | fallback proxy target for everything not handled natively |
| `upstream_connect_timeout_s` | `10.0` | |
| `idle_connection_timeout_s` | `600.0` | close a client idle for 0.95–1.0 × this (ws-connector parity) |
| `ws_max_message_bytes` | `1048576` | inbound message cap (close 1009) |
| `ws_outbound_queue` | `256` | frames queued per connection before the sender blocks |
| `ws_send_stall_s` | `15.0` | a frame not flushed within this closes the socket (WSConnUnblocker parity) |
| `drain_grace_s` / `drain_ws_max_s` | `30.0` / `900.0` | rolling restart: idle WS closed at once, active after grace, all by the hard deadline |
| `status_interval_s` | `10.0` | status line period (0 = off) |
| `log_handled` / `log_not_handled` | `false` | per-request log lines (ws-connector `--log-handled` / `--log-not-handled`) |

## Admin HTTP (127.0.0.1:`admin_port`)

`GET /healthz`, `GET /readyz` (503 unless serving — the load balancer / restart script gate),
`GET /status` (JSON: pid, state, uptime, connections), `GET /metrics` (Prometheus text),
`GET /tasks` (fiber phase registry, the pgwire `select * from tasks` replacement),
`POST /drain` (same as SIGUSR1).

## Rolling restart (`rebuild-restart-api.sh`, ocaml-plan.md §6)

Build → start a NEW generation as transient unit `primal-ocaml-api-<timestamp>` next to the running
one (SO_REUSEPORT: both hold the ports, the kernel balances new connections) → poll `/status` until
the new pid reports `serving` → `SIGUSR1` the old generation(s), which stop accepting, finish
in-flight requests, close idle WebSockets, close the rest after `drain_grace_s` and exit → SIGKILL
stragglers after `drain_grace_s + drain_ws_max_s`. A broken build or a new generation that does not
become ready leaves the old one untouched. Logs append to `$PRIMAL_VAR_DIR/ocaml-api.log`;
`PRIMAL_EXE` / `PRIMAL_API_CONFIG` override the binary and config (used by the private `ocaml-ext`
wrappers).

## primalctl

```sh
primalctl req ws://127.0.0.1:9006 server_name                 # one request, frames printed until EOSE
primalctl req ws://127.0.0.1:9006 user_infos '{"pubkeys":["<hex>"]}' --zlib   # zlib mode (frames inflated)
primalctl status|metrics|drain [http://127.0.0.1:14006]
```

## Layout

`lib/config.ml`, `lib/protocol.ml` (REQ/CLOSE parsing, EVENT/EVENTS/NOTICE/EOSE framing, zlib),
`lib/conn.ml` (one client connection: native dispatch + upstream proxy + idle timer + registry for
drain), `lib/admin.ml`, `lib/stats.ml`, `bin/primal_apid.ml`, `bin/primalctl.ml`. The server kernel
(`Http_server` on httpun-eio/httpun-ws, `Listen`, `Lifecycle`, `Ws_client`, `Zlib_util`) lives in
`../ocaml-common`.

## Notes

- zlib frames inflate to exactly the ws-connector/Julia body but are not byte-identical to
  ws-connector's (flate2 may emit stored blocks; zlib emits compressed ones). Clients only inflate.
- Shadow port 9006 was chosen because 9005 is occupied by the `ocaml-handlers` ws-connector instance.
