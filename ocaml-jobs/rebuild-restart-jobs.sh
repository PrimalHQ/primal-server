#!/usr/bin/env bash
# Rebuild primal-jobs and restart it as a transient systemd --user service (stop-then-start: the
# roles are singletons, two generations must not run their loops concurrently).
#   PRIMAL_JOBS_CONFIG  config file (default $PRIMAL_CONFIG_DIR/primal-jobs-config.json)
#   PRIMAL_JOBS_MEMMAX  systemd MemoryMax (default 10G; the media role on the media host runs with 30G as primal-media did)
#   PRIMAL_BUILD_PGHOST host whose DBs the [%pgsql] checks run against (a host whose local schema
#                       differs from <stage-host>'s, e.g. the media host, builds with PRIMAL_BUILD_PGHOST=<stage-host>)
set -euo pipefail
ts() { date +%H:%M:%S; }
P="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$P/.." && pwd -P)"
COMMON="$ROOT/ocaml-common"
EXE="${PRIMAL_EXE:-$ROOT/_build/default/ocaml-jobs/bin/primal_jobsd.exe}"
CONFIG="${PRIMAL_JOBS_CONFIG:-$PRIMAL_CONFIG_DIR/primal-jobs-config.json}"
LOG="$PRIMAL_VAR_DIR/ocaml-jobs.log"
UNIT=primal-ocaml-jobs
NIX="$(command -v nix || echo /run/current-system/sw/bin/nix)"
echo "$(ts) building (dune build @all) ..." >&2
(cd "$P" && "$NIX" develop "path:$COMMON" -c env ${PRIMAL_BUILD_PGHOST:+PGHOST=$PRIMAL_BUILD_PGHOST} dune build @all)
[[ -x "$EXE" ]] || { echo "ERROR: $EXE not built" >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "ERROR: config file not found: $CONFIG" >&2; exit 1; }
admin_port="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["admin_port"])' "$CONFIG")"
systemctl --user stop "$UNIT.service" 2>/dev/null || true
systemctl --user reset-failed "$UNIT.service" 2>/dev/null || true
mapfile -t old < <(pgrep -f -- "$EXE" || true)
if ((${#old[@]})); then kill -TERM "${old[@]}" 2>/dev/null || true; sleep 2; fi
loginctl enable-linger "${USER:-$(id -un)}" 2>/dev/null || true
mkdir -p "$(dirname "$LOG")"
systemd-run --user --collect --unit="$UNIT" --description="Primal jobs daemon (ocaml-jobs/bin/primal_jobsd.exe)" \
  -p Restart=always -p RestartSec=5 -p OOMPolicy=kill -p StartLimitIntervalSec=0 -p LimitNOFILE=65536 \
  -p MemoryAccounting=yes -p MemoryHigh="${PRIMAL_JOBS_MEMHIGH:-8G}" -p MemoryMax="${PRIMAL_JOBS_MEMMAX:-10G}" \
  -p "StandardOutput=append:$LOG" -p "StandardError=append:$LOG" -p "WorkingDirectory=$P" \
  -- "$NIX" develop "path:$COMMON" -c "$EXE" "$CONFIG"
for _ in $(seq 1 100); do
  st="$(curl -s --max-time 2 "http://127.0.0.1:$admin_port/status" || true)"
  [[ "$st" == *'"state":"serving"'* ]] && { echo "$(ts) primal-jobs running: $st" >&2; echo "log: $LOG" >&2; exit 0; }
  sleep 0.3
done
echo "ERROR: primal-jobs did not become ready; see $LOG" >&2; exit 1
