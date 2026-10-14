# PostgreSQL 16 with the extensions the baseline schemas use (schema/), from the same
# nixpkgs as the dev shell (nix/flake.lock). Built by `selfhost/primal.sh init`:
#   nix build -f selfhost/postgres.nix -o var/postgres
let
  lock = builtins.fromJSON (builtins.readFile ../nix/flake.lock);
  pkgs = import (builtins.fetchTree lock.nodes.nixpkgs.locked) { };
in
pkgs.postgresql_16.withPackages (ps: with ps; [ pgvector pg_cron plv8 pg_hint_plan pgsql-http pg_relusage ])
