# python3 and CA certificates for selfhost/bootstrap.py, from the dev shell's nixpkgs
# (nix/flake.lock). Built by `selfhost/primal.sh bootstrap` into var/python.
let
  lock = builtins.fromJSON (builtins.readFile ../nix/flake.lock);
  pkgs = import (builtins.fetchTree lock.nodes.nixpkgs.locked) { };
in
pkgs.buildEnv { name = "primal-selfhost-python"; paths = [ pkgs.python3 pkgs.cacert ]; }
