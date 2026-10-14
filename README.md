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

One dune workspace, one dune project per daemon:

| Directory | What |
|---|---|
| `common/` | `primal_common`, the shared library: Postgres (`[%pgsql]`), Nostr, HTTP/WebSocket clients and server kernel |
| `api/` | `primal-api`: the WebSocket cache API, the internal HTTP services, admin endpoint; `primalctl` |
| `importer/` | `primal-importer`: imports events from the fetcher's firehose into the cache DB |
| `fetcher/` | `primal-fetcher`: relay connections, the firehose, the relay lists (`relays/`) |
| `jobs/` | `primal-jobs`: DAG runner, TrustRank, analytics, DVM checker, rebroadcasting; the media role (processing graph, uploads, Blossom) |
| `nix/` | the dev shell for the whole workspace (`flake.nix`) and patches to third-party packages |
| `sql/` | the schema migrations (`migrations/`, applied by `migrate.sh`) |
| `schema/` | baseline schemas of the cache, membership and media DBs |
| `selfhost/` | `primal.sh`, PostgreSQL (`postgres.nix`), config templates, content files and relay list for a private server (below) |

Each directory has a `README.md` with the details.

### Self-hosting a private Primal server

`selfhost/primal.sh` runs a complete private server on one machine. It needs only
[nix](https://nixos.org/download) (with flakes) and keeps all its state in `var/`, which git ignores:

    selfhost/primal.sh init     # PostgreSQL 16 in var/pg, the cache and membership DBs, configs in var/config
    selfhost/primal.sh build    # builds primal-fetcher, -importer, -api and -jobs into var/bin
    selfhost/primal.sh start    # starts PostgreSQL and the four daemons in the background

Then open a Primal app and, under network settings, set the caching service to
`ws://127.0.0.1:8801`. Other commands: `status`, `stop`, `restart`, `logs [fetcher|importer|api|jobs]`,
`psql`, `bootstrap`. `init` is safe to re-run: it applies new migrations, adds new seeds and rewrites
the configs.

The first `start` also bootstraps the follow graph, which takes about two minutes. It fetches the
seed accounts' profiles and follow lists from the relays, then the profiles of everyone they follow,
then the follow lists of the 1000 most followed (`selfhost/bootstrap.py`, through the importer's
import listener). TrustRank then ranks them, and the importer restarts once to pick up the ranks.

What runs:

| Process | Does | Port |
|---|---|---|
| PostgreSQL 16 (`selfhost/postgres.nix`) | the cache DB `primal1` and the membership DB, created from `schema/` | 127.0.0.1:54317 |
| `primal-fetcher` | subscribes to the relays in `selfhost/relays.txt`, adds the ones it learns from relay lists, and serves the new events as a firehose | 8820 (admin 8821) |
| `primal-importer` | imports the firehose into the cache DB: events, profiles, follows, reactions, zaps, notifications, counters | 8830 (import listener) |
| `primal-api` | the WebSocket API the apps use, plus internal HTTP (link previews, nostr.json) | 8801 (HTTP 8802, 8803, admin 8811) |
| `primal-jobs` | TrustRank (user scores, from the seeds in `selfhost/trust-seeds.txt`), trending and explore feeds, and the DAG's derived tables (search, mentions, articles, zaps) | admin 8840 |

Settings, as environment variables:
- `PRIMAL_LISTEN_HOST=0.0.0.0` serves the API to other machines. Put TLS in front of it with a reverse proxy.
- `PRIMAL_API_PORT` and `PRIMAL_PG_PORT` move the API and the database.
- `PRIMAL_RELAYS_FILE` takes another relay list; set it empty for the full lists in `fetcher/relays/`.
- `PRIMAL_VAR` moves the state directory.

The configs come from the templates in `selfhost/config/` and are written to `var/config/`, where
every key can be changed. Each daemon's README lists the keys. The setup leaves out what needs more
infrastructure:
- the media pipeline and S3;
- DVM feeds;
- proxies;
- push notifications;
- metrics.

TrustRank spreads trust from the seed accounts over the follow graph; it runs when primal-jobs
starts and then hourly. An event's score counts the reactions, replies, reposts and zaps of
accounts TrustRank ranks above the humaness threshold, so scores and the trending feeds fill in within
minutes of the first start. The explore and trending
feeds are recomputed every 10 minutes.

The first `build` downloads the OCaml toolchain and takes a few minutes. Events start arriving
within seconds of `start`.

### Build

    nix develop path:./nix -c dune build @all
    nix develop path:./nix -c dune test

The `[%pgsql]` statements are type-checked at compile time against a database made from the
baseline schemas (`schema/README.md`), for instance the one `selfhost/primal.sh init`
creates. The dev shell sets `PG*` itself, so override them inside it:
`nix develop path:./nix -c env PGPORT=54317 PGUSER=$USER dune build @all`.

### Run

Every daemon reads one JSON config, given as its argument; `<exe> --check-config <file>` checks it
without starting anything. `sql/migrate.sh` applies the schema migrations.

### API requests

The funcalls are listed in `api/lib/funcall.ml`.

Examples:

    ["REQ", "amelx49c18", {"cache": ["net_stats"]}]
    ["CLOSE", "amelx49c18"]

    ["REQ", "p0xren2axa", {"cache": ["feed", {"pubkey": "64-hex digits of pubkey id"}]}]

    ["REQ", "vqvv4vc6us", {"cache": ["thread_view", {"event_id": "64-hex digits of event id"}]}]

    ["REQ", "ay4if6pykg", {"cache": ["user_infos", {"pubkeys": ["64-hex digits of pubkey id"]}]}]

    ["REQ", "2t6z17orjp", {"cache": ["events", {"event_ids": ["64-hex digits of event id"]}]}]

    ["REQ", "1uddc0a2fv", {"cache": ["user_profile", {"pubkey": "64-hex digits of pubkey id"}]}]
