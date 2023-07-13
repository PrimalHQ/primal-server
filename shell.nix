{ pkgs ? import <nixpkgs> { } }:

with pkgs;

mkShell {
  buildInputs = [
    julia_18
    secp256k1
    gcc
    postgresql
    ephemeralpg
    gawk
  ];

  start_julia = ''
    julia --project -t8 -L pkg.jl
  '';

  start_postgres = pkgs.writeShellScript "start_postgres.sh" ''
    set -ex
    PGVER=$(pg_ctl -V | awk '{print $NF}')
    PGHOST="$(pwd)/primal-caching-service/var/pg"
    if ! [ -f pgurl ]; then
      mkdir -p $(pwd)/primal-caching-service/var
      pg_tmp -w 0 -k -d $(pwd)/primal-caching-service/var/pg || true
      echo "postgresql:///test?host=$(echo $PGHOST | sed 's:/:%2F:g')" > pgurl
    fi
    echo "pgurl: $(cat pgurl)"
  '';

  stop_postgres = pkgs.writeShellScript "stop_postgres.sh" ''
    set -ex
    pg_ctl -w -D $(pwd)/primal-caching-service/var/pg/1*.* stop
    rm -fv pgurl
  '';

  connect_to_postgres = pkgs.writeShellScript "connect_to_pg.sh" ''
    psql $(cat pgurl)
  '';

  start_primal_server = pkgs.writeShellScript "start_primal_server.sh" ''
    set -ex
    export PRIMALSERVER_RELAYS='few-relays.txt'
    export PRIMALSERVER_PGCONNSTR="$(cat pgurl)"
    export PRIMALSERVER_AUTO_FETCH_MISSING_EVENTS="1"
    export LD_LIBRARY_PATH=".:$(pwd)/primal-caching-service:$LD_LIBRARY_PATH"
    julia --project -t8 -L pkg.jl -L load.jl -L start.jl
  '';

  shellHook = ''
    export LD_LIBRARY_PATH=${secp256k1}/lib:.
    cd primal-caching-service
    make
    cd ..
  '';
}
