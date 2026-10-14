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
| `selfhost/` | `primal.sh`, PostgreSQL (`postgres.nix`), config templates, content files and relay list for a private server (below) |

Each directory has a `README.md` with the details. `ocaml-plan.md` is the record of the port.

### Self-hosting a private Primal server

`selfhost/primal.sh` runs a complete private server on one machine. It needs only
[nix](https://nixos.org/download) (with flakes) and keeps all its state in `var/`, which git ignores:

    selfhost/primal.sh init     # PostgreSQL 16 in var/pg, the cache and membership DBs, configs in var/config
    selfhost/primal.sh build    # builds primal-fetcher, primal-importer and primal-api into var/bin
    selfhost/primal.sh start    # starts PostgreSQL and the three daemons in the background

Then open a Primal app and, under network settings, set the caching service to
`ws://127.0.0.1:8801`. Other commands: `status`, `stop`, `restart`, `logs [fetcher|importer|api]`,
`psql`. `init` is safe to re-run: it applies new migrations and rewrites the configs.

What runs:

| Process | Does | Port |
|---|---|---|
| PostgreSQL 16 (`selfhost/postgres.nix`) | the cache DB `primal1` and the membership DB, created from `ocaml-common/schema/` | 127.0.0.1:54317 |
| `primal-fetcher` | subscribes to the relays in `selfhost/relays.txt`, adds the ones it learns from relay lists, and serves the new events as a firehose | 8820 (admin 8821) |
| `primal-importer` | imports the firehose into the cache DB: events, profiles, follows, reactions, zaps, notifications, counters | 8830 (import listener) |
| `primal-api` | the WebSocket API the apps use, plus internal HTTP (link previews, nostr.json) | 8801 (HTTP 8802, 8803, admin 8811) |

Settings, as environment variables:
- `PRIMAL_LISTEN_HOST=0.0.0.0` serves the API to other machines. Put TLS in front of it with a reverse proxy.
- `PRIMAL_API_PORT` and `PRIMAL_PG_PORT` move the API and the database.
- `PRIMAL_RELAYS_FILE` takes another relay list; set it empty for the full lists in `ocaml-fetcher/relays/`.
- `PRIMAL_VAR` moves the state directory.

The configs come from the templates in `selfhost/config/` and are written to `var/config/`, where
every key can be changed. Each daemon's README lists the keys. The minimal setup leaves out what
needs more infrastructure:
- the jobs daemon (`ocaml-jobs`: trending, scores, DVM feeds, media);
- media and S3;
- proxies;
- push notifications;
- metrics.

The first `build` downloads the OCaml toolchain and takes a few minutes. Events start arriving
within seconds of `start`.

### Build

    nix develop path:./ocaml-common -c dune build @all
    nix develop path:./ocaml-common -c dune test

The `[%pgsql]` statements are type-checked at compile time against a database made from the
baseline schemas (`ocaml-common/schema/README.md`), for instance the one `selfhost/primal.sh init`
creates. The dev shell sets `PG*` itself, so override them inside it:
`nix develop path:./ocaml-common -c env PGPORT=54317 PGUSER=$USER dune build @all`.

### Run

Every daemon reads one JSON config, given as its argument; `<exe> --check-config <file>` checks it
without starting anything. `ocaml-common/sql/migrate.sh` applies the schema migrations.

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
