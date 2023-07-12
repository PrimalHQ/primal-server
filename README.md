<br />
<div align="center">
    <img src="https://primal.net/assets/logo_fire-409917ad.svg" alt="Logo" width="80" height="80">
</div>

### Overview

Primal Server includes membership, discovery and media caching services for Nostr.

### Usage

Running the server if you have nix package manager installed:

    nix develop -c sh -c '$start_primal_server'

To connect to postgres:

    run(`$(ENV["connect_to_pg"])`)

To safely stop the server process:

    Fetching.stop(); close(cache_storage); exit()

### API requests

Read `primal-caching-service/src/app.jl` and `ext/App.jl` for list of all supported arguments.
