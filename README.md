<br />
<div align="center">
    <img src="https://primal.net/assets/logo_fire-409917ad.svg" alt="Logo" width="80" height="80">
</div>

### Overview

Primal Server includes caching, membership, discovery and media caching services for Nostr. It connects to the specified set of relays, collects all events in real time, stores them locally, and makes them available to nostr clients through a web socket-based API.

It is written in OCaml 5 (Eio). The earlier Julia and Rust implementation was retired in October 2026;
its code is in the tag `julia-final`, which the "Julia ..." provenance comments in the OCaml sources
refer to.

### Layout

One dune workspace:

| Directory | What |
|---|---|
| `ocaml-common/` | shared library: Postgres (`[%pgsql]`), Nostr, HTTP/WebSocket clients and server kernel, the dev shell (`flake.nix`), SQL migrations (`sql/`), baseline schemas (`schema/`) |
| `ocaml-api/` | `primal-api`: the WebSocket cache API, the internal HTTP services, admin endpoint; `primalctl` |
| `ocaml-importer/` | `primal-importer`: imports events from the fetcher's firehose into the cache DB |
| `ocaml-fetcher/` | `primal-fetcher`: relay connections, the firehose, the relay lists (`relays/`) |
| `ocaml-jobs/` | `primal-jobs`: DAG runner, TrustRank, analytics, DVM checker, rebroadcasting; the media role (processing graph, uploads, Blossom) |

Each directory has a `README.md` with the details. `ocaml-plan.md` is the record of the port.

### Build

    nix develop path:./ocaml-common -c dune build @all
    nix develop path:./ocaml-common -c dune test

The `[%pgsql]` statements are type-checked at compile time against a database: create one from the
baseline schemas (`ocaml-common/schema/README.md`) and point `PGHOST`/`PGPORT` at it.

### Run

Every daemon reads one JSON config, given as its argument; `<exe> --check-config <file>` checks it
without starting anything. `ocaml-common/sql/migrate.sh` applies the schema migrations. Then open any
Primal application and, on the network settings screen, connect to the API's WebSocket port.

### API requests

The funcalls are listed in `ocaml-api/lib/funcall.ml`.

Examples:

    ["REQ", "amelx49c18", {"cache": ["net_stats"]}]
    ["CLOSE", "amelx49c18"]

    ["REQ", "p0xren2axa", {"cache": ["feed", {"pubkey": "64-hex digits of pubkey id"}]}]

    ["REQ", "vqvv4vc6us", {"cache": ["thread_view", {"event_id": "64-hex digits of event id"}]}]

    ["REQ", "ay4if6pykg", {"cache": ["user_infos", {"pubkeys": ["64-hex digits of pubkey id"]}]}]

    ["REQ", "2t6z17orjp", {"cache": ["events", {"event_ids": ["64-hex digits of event id"]}]}]

    ["REQ", "1uddc0a2fv", {"cache": ["user_profile", {"pubkey": "64-hex digits of pubkey id"}]}]
