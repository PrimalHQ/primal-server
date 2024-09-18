{ pkgs ? import <nixpkgs> { } }:

with pkgs;

mkShell {
  buildInputs = [
    julia
    secp256k1
    gcc
    gawk
    postgresql_15
    # ephemeralpg

    glibc.dev
    cargo
    cargo-pgrx
    rustfmt
    rustc
  ];

  # start_julia = ''
  #   julia --project -t8 -L pkg.jl
  # '';

  # start_primal_server = pkgs.writeShellScript "start_primal_server.sh" ''
  #   set -ex
  #   export PRIMALSERVER_RELAYS='few-relays.txt'
  #   export PRIMALSERVER_PGCONNSTR="$(cat pgurl)"
  #   export PRIMALSERVER_AUTO_FETCH_MISSING_EVENTS="1"
  #   export LD_LIBRARY_PATH=".:$(pwd):$LD_LIBRARY_PATH"
  #   julia --project -t8 -L pkg.jl -L load.jl -L start.jl
  # '';

  setup_postgres = pkgs.writeShellScript "setup_postgres.sh" ''
    set -ex

    PGDIR="$1"
    echo $PGDIR > pgdir
    mkdir -p $PGDIR

    PGDATA="$2"
    echo $PGDATA > pgdata
    mkdir -p $PGDATA

    cd $PGDIR
    drv=$(nix-store --query --deriver ${postgresql_15})
    export SHELL=${bashInteractive}/bin/bash
    nix develop $drv --unpack
    cd postgresql-*
    nix develop $drv --configure
    nix develop $drv --build
    nix develop $drv --install

    mkdir -p $PGDATA
    initdb -D $PGDATA
    cp -v ${./pg_primal/postgresql.conf} $PGDATA
  '';

  setup_pg_primal = pkgs.writeShellScript "setup_pg_primal.sh" ''
    set -ex
    PGDIR="$(cat pgdir)"
    pg_config=$(find $PGDIR -name pg_config | grep outputs/out)
    cd pg_primal
    cargo-pgrx pgrx install -c $pg_config
  '';

  start_postgres = pkgs.writeShellScript "start_postgres.sh" ''
    set -ex
    pg_ctl -w -D $(cat pgdata) start
  '';

  stop_postgres = pkgs.writeShellScript "stop_postgres.sh" ''
    set -ex
    pg_ctl -w -D $(cat pgdata) stop -m i
  '';

  connect_to_postgres = pkgs.writeShellScript "connect_to_postgres.sh" ''
    psql $(cat pgurl)
  '';

  shellHook = ''
    export LD_LIBRARY_PATH=${secp256k1}/lib:$PWD:.
    export NIX_LD=${glibc}/lib/ld-linux-x86-64.so.2
    export LIBCLANG_PATH=${libclang.lib}/lib
    export BINDGEN_EXTRA_CLANG_ARGS="$NIX_CFLAGS_COMPILE"
    make
  '';
}
