#!/usr/bin/env bash
# Rebuild and roll the Blossom server (primal-jobs with roles ["blossom"]) as the Rust run.sh did:
# the new generation binds the same port with SO_REUSEPORT, then the old one gets SIGTERM and
# finishes its in-flight uploads (the daemon waits up to 60 s for its roles) before exiting.
#   PRIMAL_BLOSSOM_CONFIG  config file (default $PRIMAL_CONFIG_DIR/primal-blossom-config.json)
#   PRIMAL_EXE             binary (default this workspace's primal_jobsd.exe; the ocaml-ext build also works)
#   PRIMAL_BUILD_PGHOST    host for the [%pgsql] checks (see rebuild-restart-jobs.sh)
#   PRIMAL_MALLOC_ARENA_MAX glibc arena cap (default 2)
set -euo pipefail
ts() { date +%H:%M:%S; }
P="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$P/.." && pwd -P)"
COMMON="$ROOT/ocaml-common"
EXE="${PRIMAL_EXE:-$ROOT/_build/default/ocaml-jobs/bin/primal_jobsd.exe}"
CONFIG="${PRIMAL_BLOSSOM_CONFIG:-$PRIMAL_CONFIG_DIR/primal-blossom-config.json}"
LOG="$PRIMAL_VAR_DIR/ocaml-blossom.log"
UNIT_PREFIX=primal-ocaml-blossom
NIX="$(command -v nix || echo /run/current-system/sw/bin/nix)"
echo "$(ts) building (dune build @all) ..." >&2
(cd "$ROOT" && "$NIX" develop "path:$COMMON" -c env ${PRIMAL_BUILD_PGHOST:+PGHOST=$PRIMAL_BUILD_PGHOST} dune build @all)
[[ -x "$EXE" ]] || { echo "ERROR: $EXE not built" >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "ERROR: config file not found: $CONFIG" >&2; exit 1; }
admin_port="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["admin_port"])' "$CONFIG")"
mapfile -t old_pids < <(pgrep -f -- "$EXE $CONFIG" || true)
mapfile -t old_units < <(systemctl --user list-units --plain --no-legend "$UNIT_PREFIX-*.service" 2>/dev/null | awk '{print $1}' || true)
echo "$(ts) old generation pids: ${old_pids[*]:-none}" >&2
loginctl enable-linger "${USER:-$(id -un)}" 2>/dev/null || true
mkdir -p "$(dirname "$LOG")"
unit="$UNIT_PREFIX-$(date +%Y%m%d%H%M%S)"
systemd-run --user --collect --unit="$unit" --description="Primal Blossom server (primal-jobs role blossom)" \
  -p RestartSec=5 -p OOMPolicy=kill -p StartLimitIntervalSec=0 -p LimitNOFILE=65536 \
  -p MemoryAccounting=yes -p MemoryHigh="${PRIMAL_BLOSSOM_MEMHIGH:-20G}" -p MemoryMax="${PRIMAL_BLOSSOM_MEMMAX:-24G}" \
  -p "Environment=MALLOC_ARENA_MAX=${PRIMAL_MALLOC_ARENA_MAX:-2}" \
  -p "StandardOutput=append:$LOG" -p "StandardError=append:$LOG" -p "WorkingDirectory=$P" \
  -- "$NIX" develop "path:$COMMON" -c "$EXE" "$CONFIG"
new_pid=""
for _ in $(seq 1 150); do
  for p in $(pgrep -f -- "$EXE $CONFIG" || true); do printf '%s\n' "${old_pids[@]:-}" | grep -qx "$p" || new_pid="$p"; done
  [[ -n "$new_pid" ]] && break; sleep 0.2
done
ready=0
if [[ -n "$new_pid" ]]; then
  for _ in $(seq 1 100); do
    st="$(curl -s --max-time 2 "http://127.0.0.1:$admin_port/status" || true)"
    if [[ "$st" == *"\"pid\":$new_pid,"* && "$st" == *"\"state\":\"serving\""* ]]; then ready=1; break; fi
    kill -0 "$new_pid" 2>/dev/null || break; sleep 0.3
  done
fi
if (( ! ready )); then
  echo "ERROR: new generation did not become ready; stopping unit $unit, old generation untouched" >&2
  systemctl --user stop "$unit.service" 2>/dev/null || true; exit 1
fi
echo "$(ts) new generation ready: unit $unit.service pid $new_pid" >&2
if ((${#old_pids[@]})); then
  echo "$(ts) stopping old generation(s): ${old_pids[*]} (SIGTERM, in-flight requests finish)" >&2
  kill -TERM "${old_pids[@]}" 2>/dev/null || true
  for _ in $(seq 1 160); do alive=0; for p in "${old_pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done; (( alive )) || break; sleep 0.5; done
  for p in "${old_pids[@]}"; do kill -0 "$p" 2>/dev/null && { echo "pid $p still alive; SIGKILL" >&2; kill -KILL "$p" 2>/dev/null || true; }; done
fi
for u in "${old_units[@]:-}"; do [[ -n "$u" && "$u" != "$unit.service" ]] && { systemctl --user stop "$u" 2>/dev/null || true; systemctl --user reset-failed "$u" 2>/dev/null || true; }; done
echo "$(ts) blossom running: unit $unit.service pid $new_pid; log $LOG" >&2
