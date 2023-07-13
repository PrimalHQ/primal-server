{ pkgs ? import <nixpkgs> { } }:

with pkgs;

mkShell {
  buildInputs = [
    julia_18
    secp256k1
    gcc
    postgresql
    ephemeralpg
  ];

  start_julia = ''
    julia --project -t8 -L pkg.jl
  '';

  start_primal_server = pkgs.writeShellScript "start_primal_server.sh" ''
          set -ex
          if ! [ -f pgurl ]; then
            mkdir -p $(pwd)/primal-caching-service/var
            pg_ctl -w -D $(pwd)/primal-caching-service/var/pg/1*.* stop || true
            pgurl=$(pg_tmp -w 0 -k -d $(pwd)/primal-caching-service/var/pg)
            echo "$pgurl" > pgurl
          else
            pgurl=$(cat pgurl)
          fi
          echo pgurl: $pgurl
          export PRIMALSERVER_RELAYS='few-relays.txt'
          export PRIMALSERVER_PGCONNSTR="$pgurl"
          export PRIMALSERVER_AUTO_FETCH_USER_METADATA="1"
          export LD_LIBRARY_PATH=".:$(pwd)/primal-caching-service:$LD_LIBRARY_PATH"
          julia --project -t8 -L pkg.jl -L load.jl -L start.jl
  '';

  stop_postgres = pkgs.writeShellScript "stop_postgres.sh" ''
          set -ex
          pg_ctl -w -D $(pwd)/primal-caching-service/var/pg/1*.* stop || true
          rm -fv pgurl
  '';

  connect_to_pg = pkgs.writeShellScript "connect_to_pg.sh" ''
    psql $(cat pgurl)
  '';

  shellHook = ''
    export LD_LIBRARY_PATH=${secp256k1}/lib:.
    cd primal-caching-service
    make
    cd ..
  '';
}
