#!/bin/sh
# Run a python playwright script with the nix-provided Chromium (nixos-25.11 binary cache):
#   tools/playwright.sh tools/webapp-walk.py wss://stage.primal.net/v1 stage "/home,/reads,/explore"
# webapp-walk.py loads primal.net with localStorage.cacheServer set to the given cache URL, scrolls
# each page, records every WebSocket frame (frames-TAG.jsonl), the console (console-TAG.txt), a
# screenshot and the rendered text, and prints per-request summaries and rendered element counts.
NIXPKGS='(import (builtins.getFlake "nixpkgs") {})'
export PLAYWRIGHT_BROWSERS_PATH="$(nix eval --raw --impure --expr "$NIXPKGS.playwright-driver.browsers")"
export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1
exec nix shell --impure --expr "[ ($NIXPKGS.python3.withPackages (p: [p.playwright])) ]" -c python3 "$@"
