{ pkgs ? import <nixpkgs> { } }:

with pkgs;

mkShell {
  buildInputs = [
    julia_18
    secp256k1
    gcc
    postgresql
  ];

  start_julia = ''
    julia --project -t8 -L pkg.jl
  '';
  start_primal_server = ''
    PRIMALSERVER_RELAYS='few-relays.txt' LD_LIBRARY_PATH=".:$(pwd)/primal-caching-service:$LD_LIBRARY_PATH" julia --project -t8 -L pkg.jl -L load.jl -L start.jl
  '';

  shellHook = ''
    export LD_LIBRARY_PATH=${secp256k1}/lib:.
    cd primal-caching-service
    make
    cd ..
  '';
}
