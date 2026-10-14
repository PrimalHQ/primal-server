# primal_common

Shared OCaml 5 / Eio library for the Primal daemons in this workspace (`ocaml-api`,
`ocaml-importer`, `ocaml-fetcher`, `ocaml-jobs`) and for the private `ocaml-ext`. Library name
`primal_common`; modules are flat (`Postgres`, `Nostr`, `Http`, …) whatever their subdirectory
(`include_subdirs unqualified`), and consumers compile with `-open Primal_common`. No Lwt.

This directory also holds the workspace's dev shell (`flake.nix`), the SQL migrations (`sql/`)
and the baseline database schemas (`schema/`). The retired Julia/Rust implementation is in the git
tag `julia-final`.

## Layout (`lib/`)

| Dir | Modules | Notes |
|---|---|---|
| `core/` | `Hex_util`, `Str_util`, `Utils`, `Pgj` | `Pgj`: the processing graph's typed JSON (`{"_ty", "_v"}` values, binary cache files, node ids) |
| `nostr/` | `Nostr` (event, tags, NIP-01 id, verify, `create` = sign with a secret key), `Kind` (Primal's synthetic event kinds), `Bech32` (bech32/bech32m, lud06, NIP-19 encode/decode, `encode_naddr`), `Secp256k1` (C stubs on libsecp256k1: BIP340 verify and sign, x-only pubkey, ECDH), `Nip44` (NIP-44 v2 encryption), `Dvm_client` (NIP-90 job request, first result within a timeout) | signing creates a secp256k1 context per call |
| `pg/` | `Postgres` (Eio adapter for PGOCaml, the `[%pgsql]` target, bounded lazy pool, raw `query`), `Pg_types` (enum mappings), `Pg_listen` (`LISTEN` over the raw wire protocol, trust auth only) | a connection serves one fiber at a time and is domain-bound |
| `pg_cache/` | `Filterlist` | `[%pgsql]` against the cache DB |
| `moderation/` | `Cmr` (content-moderation rules: compile from a user's settings and lists, write the `cmr_*` tables) | parameterized by the cache and membership connections and an event lookup; used by the importer and the API |
| `net/` | `Http` (URL parsing, `resolve` with a 120 s DNS cache, `is_public_ip`, TLS, SOCKS5, `https_get`, `request` with redirects, `plain_request`), `Dns_eio` (cancellable pure-Eio DNS), `Socks5`, `Ws_client` (RFC 6455 client), `Http_server` (HTTP/1.1 + WebSocket server on httpun/httpun-ws, bounded outbound queue per WebSocket), `Listen` (SO_REUSEPORT sockets shared across domains), `Relay_broadcast` (send an event to relays, collect their `OK`), `S3` (SigV4: head, get, upload, copy, delete, presigned GET), `Pushgateway` (Prometheus pushgateway POST, `stats.json` helpers), `Zlib_util` | |
| `runtime/` | `Lifecycle` (Starting → Serving → Draining → Stopped; stop signals, readiness), `Worker_pool` (bounded cross-domain queue → N domains), `Phases` (fiber phase slots for stall reports), `Procinfo` (RSS, formatting) | |
| `notifications/` | `Notifications` (type codes, arities) | |
| `text/` | `Langid` (language identification by script and trigram profiles; `Langid_data` is generated), `Link_preview` (title, description and image from a page's `<head>`, oEmbed) | |

`Http.is_public_ip` is for connections whose target comes from untrusted input (the media role's
downloads): it rejects private, loopback, link-local, CGNAT, documentation, multicast and reserved
addresses.

## Build and test

The repo is one dune workspace (`dune-workspace` at the repo root); `_build/` is at the root. This
directory's flake is the toolchain for all of it (OCaml 5.3 from nixos-25.11, dune, the libraries,
libsecp256k1, zlib, `postgresql_16`, `jq`):

```sh
C=$(git rev-parse --show-toplevel)/ocaml-common
nix develop "path:$C" -c dune build @all      # from any project directory
nix develop "path:$C" -c dune test
```

The tests (`test/test_common.ml`, alcotest) are pure logic plus a loopback WebSocket server; they
need no database at run time, but building the library does (below). So does `nix build` of
`packages.default`.

`patches/` holds fixes to third-party packages, applied in `flake.nix` with `overrideAttrs`:
`httpun-ws-frame-queue.patch` (httpun-ws 0.2.0, same code on master) makes the server deliver every
frame of its parsed-frame queue per socket read. Without it, a client write carrying three or more
WebSocket frames leaves the third and later ones unanswered until the peer sends more bytes; test
"ws burst" fails without the patch.

## The `[%pgsql]` databases

Every `[%pgsql]` statement is type-checked at compile time by pgocaml_ppx against a live database
named by the standard `PG*` variables:

- The dev shell sets `PGHOST`, `PGPORT`, `PGDATABASE` (`primal1`, the cache DB) and `PGUSER` to a
  local Postgres (values in `flake.nix`). They override the outer environment, so to use another
  server set them inside the shell: `nix develop "path:$C" -c env PGPORT=5432 dune build @all`.
- Membership-DB statements live in their own dune directories (`ocaml-api/lib_membership`,
  `ocaml-jobs/lib_membership`), whose `(env ...)` stanza sets `PGDATABASE=primal_membership_ref`
  on the same server.
- The media role's SQL is dynamic (`Postgres.query`), so no media DB is needed at build time.

Create the databases from the baseline schemas (`schema/README.md`): `primal1` from
`schema/cache.sql`, then `sql/migrate.sh` for the migrations added since; `primal_membership_ref`
from `schema/membership.sql`. Alternatively, `sql/membership-refdb-setup.sh` drops and re-clones
`primal_membership_ref` on the dev shell's local server from the `public` schema of a live
membership DB (`PRIMAL_MEMBERSHIP_HOST`; schema only, read-only on the source).

A statement can only reference what that database has, so apply a migration (`sql/migrate.sh`,
`sql/migrations/README.md`) before building code that depends on it.

At run time the daemons take their connections from their configs, not from `PG*`.
`Postgres.cache_conninfo` and `membership_conninfo` (`PG*`, `PGMEMBERSHIP*`) are for the dev
tools; the dev shell sets `PGMEMBERSHIPPORT`, `PGMEMBERSHIPDATABASE` and `PGMEMBERSHIPUSER` and
leaves `PGMEMBERSHIPHOST` to the environment.

## Running

Each daemon takes one JSON config file as its argument; `<exe> --check-config <file>` parses it
and exits. Deployment (service units, configs, secrets, running `sql/migrate.sh`) is managed
outside this repo.

Headless browser for end-to-end checks of the API against the real webapp: `nix shell
nixpkgs#chromium` and `python3.withPackages (p: [p.playwright])` with `PLAYWRIGHT_BROWSERS_PATH`
set to `playwright-driver.browsers` (both from the nixos-25.11 binary cache). The webapp takes its
cache server from `localStorage.cacheServer` (e.g. `wss://stage.primal.net/v1`), so a page script
that sets it in `add_init_script`, loads primal.net/home, scrolls and records every WebSocket frame
(zlib `EVENTS` frames decompress with `zlib.decompress`) sees exactly what a user's browser sees.

## Conventions

- Every SQL statement goes through `[%pgsql]`. Raw `Postgres.query` only where the ppx cannot check
  the statement (tables of a database it is not checked against, dynamic SQL), with a comment
  saying why.
- Cancellation: re-raise `Eio.Cancel.Cancelled` before any catch-all handler.
- Connect under a scoped switch (see `Postgres.connect`): a failed connect on a long-lived switch
  leaks an fd.
- `Postgres.use` returns a connection to its pool only after success or a `PostgreSQL_Error`;
  after any other exception it closes the connection and the slot reconnects lazily.
- Keep the library generic: nothing daemon-specific (handlers, job loops, counters records);
  parameterize instead (as `Worker_pool` is over the per-domain state).
- The system CA bundle is parsed once per process and cached (`Http.authenticator`), not per
  connection; `Http.init_tls ()` loads it on the main domain before other domains start.
- `Ws_client` replaces its read buffer with a fresh 4 KB one after a frame over 64 KB when nothing
  is buffered, so a long-lived relay connection does not keep its largest frame's buffer.
