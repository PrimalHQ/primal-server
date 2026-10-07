# primal_common

Shared OCaml 5 / Eio foundation for every Primal daemon in this repo (`ocaml-importer`, and the
`ocaml-api`, `ocaml-fetcher`, `ocaml-jobs` projects of `ocaml-plan.md`) and for the private
`ocaml-ext` in the parent repo. Library name `primal_common`; modules are flat (`Postgres`,
`Nostr`, `Http`, …) regardless of subdirectory. No Lwt anywhere.

## Layout (`lib/`)

| Dir | Modules | Notes |
|---|---|---|
| `core/` | `Hex_util`, `Str_util`, `Utils` | |
| `nostr/` | `Nostr` (event, tags, NIP-01 id, BIP340 verify, `create` = sign with a secret key), `Bech32` (bech32, lud06, NIP-19 decode, `encode_naddr`), `Secp256k1` (+ C stubs on libsecp256k1 `schnorrsig_verify`, `schnorrsig_sign32`, x-only pubkey) | signing creates a context per call (rare: DVM job requests, service events) |
| `moderation/` | `Cmr` (content-moderation rule compiler + cmr_* import, Julia app.jl:358/488) | parameterized by the cache/membership connections and an event lookup; used by the importer (list changes) and the API (`set_app_settings`, `search_filterlist`) |
| `pg/` | `Postgres` (Eio adapter for PGOCaml, `[%pgsql]` target, bounded lazy pool), `Pg_types` (enum mappings), `Pg_listen` (raw-protocol `LISTEN`) | one connection = one fiber at a time; connections are domain-bound |
| `pg_cache/` | `Filterlist` | `[%pgsql]`-checked against the cache DB (`primal1`) |
| `net/` | `Http` (HTTPS GET, TLS, SOCKS5, pure-Eio DNS), `Ws_client` (RFC 6455 client), `Dns_eio`, `Socks5`, `Pushgateway` (POST + stats.json helpers) | |
| `runtime/` | `Worker_pool` (bounded cross-domain queue → N domains), `Phases` (fiber phase slots), `Procinfo` (RSS, formatting) | |
| `notifications/` | `Notifications` (type codes, arities) | |

## Build

Everything in the repo's dune workspace (root `dune-workspace` next to `ocaml-common/`) builds
from this project's flake:

```sh
C=$(git rev-parse --show-toplevel)/ocaml-common
nix develop "path:$C" -c dune build @all      # from any project dir; _build is at the repo root
nix develop "path:$C" -c dune test            # alcotest, pure logic only
```

The dev shell exports `PG*` → `primal1` for the `[%pgsql]` ppx. Membership-table queries are checked
against the local clone `primal_membership_ref` (`sql/membership-refdb-setup.sh`) via a per-directory
dune `(env ...)`. `sql/migrate.sh` applies versioned migrations (`sql/migrations/README.md`).

Deployment layout, shared by every `rebuild-restart-*.sh`: the daemons' JSON configs live outside the
checkout in `PRIMAL_CONFIG_DIR` (default two directories above the repo root, next to the parent repo),
logs, pid and state files in `PRIMAL_VAR_DIR` (default `$HOME/var/primalserver`); each script also takes
its own `PRIMAL_*_CONFIG` override.

`patches/` holds fixes to third-party OCaml packages applied in `flake.nix` through `overrideAttrs`:
`httpun-ws-frame-queue.patch` (httpun-ws 0.2.0, same code on master): the server delivered only the head of
its parsed-frame queue per socket read, so a client write carrying three or more WebSocket frames left the
third and later ones unanswered until the peer's next bytes; `test/test_common.ml` "ws burst" fails without it.

Headless browser for end-to-end checks of the API against the real webapp: `nix shell nixpkgs#chromium`
and `python3.withPackages (p: [p.playwright])` with `PLAYWRIGHT_BROWSERS_PATH` set to
`playwright-driver.browsers` (both from the nixos-25.11 binary cache); the webapp takes its cache server
from `localStorage.cacheServer` (`wss://stage.primal.net/v1` → the stage host), so a page script that sets it in
`add_init_script`, loads primal.net/home, scrolls, and records every WebSocket frame (zlib `EVENTS`
frames decompress with `zlib.decompress`) sees exactly what a user's browser sees.

## Conventions

- Every SQL statement goes through `[%pgsql]`; `Postgres.query` (raw) only for tables the ppx
  cannot see, with a comment saying why.
- Cancellation hygiene: re-raise `Eio.Cancel.Cancelled` before any catch-all handler.
- Connect under a scoped switch (see `Postgres.connect`): a failed connect on a long-lived switch
  leaks an fd.
- Config is a JSON file per daemon, every key required; secrets are file paths.

### Notes added with the fetcher (Phase 7)

- `Http.tls_wrap` parses the system CA bundle once per process (`Http.authenticator`, forced by
  `Http.init_tls ()` at daemon start); `Ca_certs.authenticator ()` per connection was most of a
  wss connect's cost.
- `Ws_client` replaces its `Buf_read` with a fresh 4 KB one after a frame over 64 KB when nothing
  is buffered (`shrink`): a long-lived relay connection otherwise keeps its largest frame's buffer.
