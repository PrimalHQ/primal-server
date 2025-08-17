{ pkgs ? import <nixpkgs> { } }:

with pkgs;

mkShell {
  buildInputs = [
    rustup
    gcc

    glibc.dev

    pkg-config
    openssl
    krb5
  ];

  rustup_init = pkgs.writeShellScript "rustup_init.sh" ''
    set -xe

    export RUSTUP_HOME=`pwd`/.rustup 
    rustup default stable
    rustup toolchain install nightly-x86_64-unknown-linux-gnu
    rustup component add rust-analyzer
  '';

  cargo = pkgs.writeShellScript "cargo.sh" ''
    set -e

    export NIX_LD=${glibc}/lib/ld-linux-x86-64.so.2

    export LIBCLANG_PATH=${libclang.lib}/lib
    export BINDGEN_EXTRA_CLANG_ARGS="$NIX_CFLAGS_COMPILE"

    export RUSTUP_HOME=`pwd`/.rustup 

    RUST_BACKTRACE=1 RUSTFLAGS="$RUSTFLAGS -Awarnings" cargo "$@"
  '';

  rust_analyzer = pkgs.writeShellScript "rust_analyzer.sh" ''
    set -e

    export NIX_LD=${glibc}/lib/ld-linux-x86-64.so.2

    export RUSTUP_HOME=$1/.rustup 

    shift

    rust-analyzer "$@"
  '';

  shellHook = ''
    export RUSTUP_HOME=`pwd`/.rustup 
  '';
}
