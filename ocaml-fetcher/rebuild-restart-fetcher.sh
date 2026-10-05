#!/usr/bin/env bash
# Rebuild primal-fetcher and restart it as a transient systemd --user service (stop-then-start:
# one fetcher per state directory — two would fight over the resume files and double the firehose).
#   PRIMAL_FETCHER_CONFIG  config file (default $PRIMAL_CONFIG_DIR/primal-fetcher-config.json)
#   PRIMAL_MALLOC_ARENA_MAX  glibc malloc arena cap for the daemon (memory experiment; unset = glibc default of 8 x cores)
set -euo pipefail
ts() { date +%H:%M:%S; }
P="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$P/.." && pwd -P)"
COMMON="$ROOT/ocaml-common"
EXE="${PRIMAL_EXE:-$ROOT/_build/default/ocaml-fetcher/bin/primal_fetcherd.exe}"
CONFIG="${PRIMAL_FETCHER_CONFIG:-$PRIMAL_CONFIG_DIR/primal-fetcher-config.json}"
LOG="$PRIMAL_VAR_DIR/ocaml-fetcher.log"
UNIT=primal-ocaml-fetcher
NIX="$(command -v nix || echo /run/current-system/sw/bin/nix)"
echo "$(ts) building (dune build @all) ..." >&2
(cd "$P" && "$NIX" develop "path:$COMMON" -c dune build @all)
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
  -p MemoryAccounting=yes -p MemoryHigh=10G -p MemoryMax=12G \
  ${PRIMAL_MALLOC_ARENA_MAX:+-p "Environment=MALLOC_ARENA_MAX=$PRIMAL_MALLOC_ARENA_MAX"} \
  -p "StandardOutput=append:$LOG" -p "StandardError=append:$LOG" -p "WorkingDirectory=$P" \
  -- "$NIX" develop "path:$COMMON" -c "$EXE" "$CONFIG"
for _ in $(seq 1 100); do
  st="$(curl -s --max-time 2 "http://127.0.0.1:$admin_port/status" || true)"
  [[ "$st" == *'"state":"serving"'* ]] && { echo "$(ts) primal-fetcher running" >&2; echo "log: $LOG" >&2; exit 0; }
  sleep 0.3
done
echo "ERROR: primal-fetcher did not become ready; see $LOG" >&2; exit 1
