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
    python3

    glibc.dev
    cargo
    cargo-pgrx
    rustfmt
    rustc
    lldb
  ];

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
    cp -r $PGDIR/postgresql-15.8/outputs/out/* $PGDIR/postgresql-15.8/outputs/lib/
    cd pg_primal
    cargo-pgrx pgrx init --pg15 $pg_config
    cargo-pgrx pgrx install -c $pg_config
  '';

  setup_pg_extensions = pkgs.writeShellScript "setup_pg_extensions.sh" ''
    PGDIR="$(cat pgdir)"
    PGOUTS="$(find $PGDIR/ -type d -name outputs | grep -v tmp_install)"
    set -ex
    for d in \
      ${pkgs.postgresql15Packages.pg_cron} \
      ${pkgs.postgresql15Packages.pgsql-http} \
      ${pkgs.postgresql15Packages.pgvector} \
    ; do
      chmod u+w -R $PGOUTS/
      cp -v $d/lib/* $PGOUTS/lib/lib/
      cp -v $d/share/postgresql/extension/* $PGOUTS/out/share/extension/
    done
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

  init_postgres_schema = pkgs.writeShellScript "init_postgres_schema.sh" ''
    set -x
    psql -h127.0.0.1 -p54017 primal1 < sql/schemas/membership.sql
    psql -h127.0.0.1 -p54017 primal1 < sql/schemas/cache.sql
    psql -h127.0.0.1 -p54017 primal1 < sql/app.sql
    psql -h127.0.0.1 -p54017 primal1 < sql/utils.sql
  '';

  connect_to_postgres = pkgs.writeShellScript "connect_to_postgres.sh" ''
    psql -h127.0.0.1 -p54017 primal1
  '';

  patch_pgwire = pkgs.writeShellScript "patch_pgwire.sh" ''
    cd ws-connector/pgwire && patch -p1 < ../pgwire.patch
  '';

  build_wsconn = pkgs.writeShellScript "build_wsconn.sh" ''
    cd ws-connector && RUSTFLAGS="-Awarnings --cfg tokio_unstable --cfg tokio_taskdump" cargo build "$@"
  '';

  start_primal_server = pkgs.writeShellScript "start_primal_server.sh" ''
    julia --project -t6 -L pkg.jl -L start.jl
  '';

  shellHook = ''
    export LD_LIBRARY_PATH=${secp256k1}/lib:$PWD:.
    export NIX_LD=${glibc}/lib/ld-linux-x86-64.so.2
    export LIBCLANG_PATH=${libclang.lib}/lib
    export BINDGEN_EXTRA_CLANG_ARGS="$NIX_CFLAGS_COMPILE"
    make
  '';
}
