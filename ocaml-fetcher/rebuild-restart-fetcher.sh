#!/usr/bin/env bash
# Rebuild primal-fetcher and restart it as a transient systemd --user service (stop-then-start:
# one fetcher per state directory — two would fight over the resume files and double the firehose).
#   PRIMAL_FETCHER_CONFIG  config file (default $PRIMAL_CONFIG_DIR/primal-fetcher-config.json, see below)
#   PRIMAL_BUILD_PGHOST  host whose DBs the [%pgsql] checks run against (a host whose local schema differs, e.g. the media host)
#   PRIMAL_FETCHER_MEMHIGH / PRIMAL_FETCHER_MEMMAX  systemd MemoryHigh / MemoryMax (default 10G / 12G; above
#                       MemoryHigh the kernel throttles every allocation — the 2026-10-07 'freeze' at 63k known relays)
#   PRIMAL_MALLOC_ARENA_MAX  glibc malloc arena cap (default 2: with the glibc default of 8 x cores the
#                       fetcher sat at 7.5 GB RSS for 16.6k relays, with 2 arenas at 3.6 GB; see README)
set -euo pipefail
ts() { date +%H:%M:%S; }
P="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$P/.." && pwd -P)"
# Deployment layout (every script in this repo): the daemons' JSON configs live outside the checkout
# in PRIMAL_CONFIG_DIR (default: two directories above the repo root, i.e. next to the parent repo);
# logs, pid and state files in PRIMAL_VAR_DIR (default $HOME/var/primalserver).
CONFIG_DIR="${PRIMAL_CONFIG_DIR:-$(cd -- "$ROOT/../.." && pwd -P)}"
VAR_DIR="${PRIMAL_VAR_DIR:-$HOME/var/primalserver}"
COMMON="$ROOT/ocaml-common"
EXE="${PRIMAL_EXE:-$ROOT/_build/default/ocaml-fetcher/bin/primal_fetcherd.exe}"
CONFIG="${PRIMAL_FETCHER_CONFIG:-$CONFIG_DIR/primal-fetcher-config.json}"
LOG="$VAR_DIR/ocaml-fetcher.log"
UNIT=primal-ocaml-fetcher
NIX="$(command -v nix || echo /run/current-system/sw/bin/nix)"
echo "$(ts) building (dune build @all) ..." >&2
(cd "$P" && "$NIX" develop "path:$COMMON" -c env ${PRIMAL_BUILD_PGHOST:+PGHOST=$PRIMAL_BUILD_PGHOST} dune build @all)
[[ -x "$EXE" ]] || { echo "ERROR: $EXE not built" >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "ERROR: config file not found: $CONFIG" >&2; exit 1; }
admin_port="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["admin_port"])' "$CONFIG")"
systemctl --user stop "$UNIT.service" 2>/dev/null || true
systemctl --user reset-failed "$UNIT.service" 2>/dev/null || true
mapfile -t old < <(pgrep -f -- "$EXE" || true)
if ((${#old[@]})); then kill -TERM "${old[@]}" 2>/dev/null || true; sleep 4; fi
loginctl enable-linger "${USER:-$(id -un)}" 2>/dev/null || true
mkdir -p "$(dirname "$LOG")"
systemd-run --user --collect --unit="$UNIT" --description="Primal fetcher daemon (ocaml-fetcher/bin/primal_fetcherd.exe)" \
  -p Restart=always -p RestartSec=5 -p OOMPolicy=kill -p StartLimitIntervalSec=0 -p LimitNOFILE=262144 \
  -p MemoryAccounting=yes -p "MemoryHigh=${PRIMAL_FETCHER_MEMHIGH:-10G}" -p "MemoryMax=${PRIMAL_FETCHER_MEMMAX:-12G}" \
  -p "Environment=MALLOC_ARENA_MAX=${PRIMAL_MALLOC_ARENA_MAX:-2}" \
  -p "StandardOutput=append:$LOG" -p "StandardError=append:$LOG" -p "WorkingDirectory=$P" \
  -- "$NIX" develop "path:$COMMON" -c "$EXE" "$CONFIG"
for _ in $(seq 1 100); do
  st="$(curl -s --max-time 2 "http://127.0.0.1:$admin_port/status" || true)"
  [[ "$st" == *'"state":"serving"'* ]] && { echo "$(ts) primal-fetcher running" >&2; echo "log: $LOG" >&2; exit 0; }
  sleep 0.3
done
echo "ERROR: primal-fetcher did not become ready; see $LOG" >&2; exit 1
