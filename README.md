<br />
<div align="center">
    <img src="https://primal.net/assets/logo_fire-409917ad.svg" alt="Logo" width="80" height="80">
</div>

### Overview

Primal Server includes caching, membership, discovery and media caching services for Nostr. It connects to the specified set of relays, collects all events in real time, stores them locally, and makes them available to nostr clients through a web socket-based API.

### Usage

Start postgres in the background:

    nix develop -c sh -c '$start_postgres'

Running the server:

    nix develop -c sh -c '$start_primal_server'

To connect to postgres from REPL:

    run(`$(ENV["connect_to_postgres"])`)

To safely stop the server process:

    Fetching.stop(); close(cache_storage); exit()

To stop postgres:

    nix develop -c sh -c '$stop_postgres'

### API requests

Read `app.jl` for list of all supported arguments.

Examples:

    ["REQ", "amelx49c18", {"cache": ["net_stats"]}]
    ["CLOSE", "amelx49c18"]

    ["REQ", "p0xren2axa", {"cache": ["feed", {"pubkey": "64-hex digits of pubkey id"}]}]

    ["REQ", "vqvv4vc6us", {"cache": ["thread_view", {"event_id": "64-hex digits of event id"}]}]

    ["REQ", "ay4if6pykg", {"cache": ["user_infos", {"pubkeys": ["64-hex digits of pubkey id"]}]}]

    ["REQ", "2t6z17orjp", {"cache": ["events", {"event_ids": ["64-hex digits of event id"]}]}]

    ["REQ", "1uddc0a2fv", {"cache": ["user_profile", {"pubkey": "64-hex digits of pubkey id"}]}]

