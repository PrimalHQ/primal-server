<br />
<div align="center">
    <img src="https://primal.net/assets/logo_fire-409917ad.svg" alt="Logo" width="80" height="80">
</div>

### Overview

Primal Server includes membership, discovery and media caching services for Nostr.

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

Read `primal-caching-service/src/app.jl` and `ext/App.jl` for list of all supported arguments.
