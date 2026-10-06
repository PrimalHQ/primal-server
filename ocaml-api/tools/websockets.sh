#!/bin/sh
# Run a python script with the `websockets` package from nix (ws-direct.py, ws-head-of-line.py):
#   tools/websockets.sh tools/ws-direct.py reads,notifs ws://127.0.0.1:9001 ws://<julia-host>:8831
exec nix shell --impure --expr 'let pkgs = import (builtins.getFlake "nixpkgs") {}; in [ (pkgs.python3.withPackages (p: [p.websockets])) ]' -c python3 "$@"
