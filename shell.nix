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
    cp -v ${./sql/postgresql.conf} $PGDATA/postgresql.conf
  '';

  setup_pg_primal = pkgs.writeShellScript "setup_pg_primal.sh" ''
    set -ex
    PGDIR="$(cat pgdir)"
    PGBINDIR="$(find $PGDIR/ -type d -name outputs | grep -v tmp_install)/out/bin"
    pg_config="$(find $PGBINDIR -name pg_config)"
    cd pg_primal
    cargo-pgrx pgrx install -c $pg_config
  '';

  setup_pg_cron = pkgs.writeShellScript "setup_pg_cron.sh" ''
    PGDIR="$(cat pgdir)"
    PGOUTS="$(find $PGDIR/ -type d -name outputs | grep -v tmp_install)"
    set -ex
    cp -v ${pkgs.postgresql15Packages.pg_cron}/lib/* $PGOUTS/lib/lib/
    cp -v ${pkgs.postgresql15Packages.pg_cron}/share/postgresql/extension/* $PGOUTS/out/share/postgresql/extension/
  '';

  start_postgres = pkgs.writeShellScript "start_postgres.sh" ''
    PGDIR="$(cat pgdir)"
    PGBINDIR="$(find $PGDIR/ -type d -name outputs | grep -v tmp_install)/out/bin"
    export PATH="$PGBINDIR:$PATH"
    set -ex
    pg_ctl -w -D $(cat pgdata) start
    createdb -h127.0.0.1 -p54017 primal1
  '';

  stop_postgres = pkgs.writeShellScript "stop_postgres.sh" ''
    PGDIR="$(cat pgdir)"
    PGBINDIR="$(find $PGDIR/ -type d -name outputs | grep -v tmp_install)/out/bin"
    export PATH="$PGBINDIR:$PATH"
    set -ex
    pg_ctl -w -D $(cat pgdata) stop -m i
  '';

  connect_to_postgres = pkgs.writeShellScript "connect_to_postgres.sh" ''
    psql -h127.0.0.1 -p54017 primal1
  '';

  shellHook = ''
    export LD_LIBRARY_PATH=${secp256k1}/lib:$PWD:.
    export NIX_LD=${glibc}/lib/ld-linux-x86-64.so.2
    export LIBCLANG_PATH=${libclang.lib}/lib
    export BINDGEN_EXTRA_CLANG_ARGS="$NIX_CFLAGS_COMPILE"
    make
  '';
}
