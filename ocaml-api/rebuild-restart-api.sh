#!/usr/bin/env bash
# Rolling rebuild-and-restart of primal-api (ocaml-plan.md §6): build; start a NEW generation as its
# own transient systemd --user unit next to the running one (SO_REUSEPORT: both hold the ports and
# the kernel balances new connections); verify the new one answers; then SIGUSR1 the old generations
# so they stop accepting, finish in-flight requests, drain their WebSockets within the configured
# grace, and exit. In-flight requests finish on the old version; new connections go to the new one.
# A broken build, a missing config or a new generation that does not become ready leaves the
# running one untouched.
#
#   PRIMAL_API_CONFIG  config file (default $PRIMAL_CONFIG_DIR/primal-api-config.json, see below)
#   PRIMAL_EXE         binary to run (default this workspace's build; ocaml-ext overrides it)
set -euo pipefail
ts() { date +%H:%M:%S; }

P="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$P/.." && pwd -P)"
# Deployment layout (every script in this repo): the daemons' JSON configs live outside the checkout
# in PRIMAL_CONFIG_DIR (default: two directories above the repo root, i.e. next to the parent repo);
# logs, pid and state files in PRIMAL_VAR_DIR (default $PRIMAL_VAR_DIR).
CONFIG_DIR="${PRIMAL_CONFIG_DIR:-$(cd -- "$ROOT/../.." && pwd -P)}"
VAR_DIR="${PRIMAL_VAR_DIR:-$PRIMAL_VAR_DIR}"
COMMON="$ROOT/ocaml-common"
EXE="${PRIMAL_EXE:-$ROOT/_build/default/ocaml-api/bin/primal_apid.exe}"
CONFIG="${PRIMAL_API_CONFIG:-$CONFIG_DIR/primal-api-config.json}"
LOG="$VAR_DIR/ocaml-api.log"
PIDFILE="$VAR_DIR/ocaml-api.pid"
UNIT_PREFIX=primal-ocaml-api
NIX="$(command -v nix || echo /run/current-system/sw/bin/nix)"

# 1. Build (the whole workspace: ocaml-common + ocaml-api). Failure leaves the running daemon alone.
echo "$(ts) building $P (dune build @all) ..." >&2
(cd "$P" && "$NIX" develop "path:$COMMON" -c dune build @all)
[[ -x "$EXE" ]] || { echo "ERROR: $EXE not built" >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "ERROR: config file not found: $CONFIG" >&2; exit 1; }

admin_port="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["admin_port"])' "$CONFIG")"
drain_grace="$(python3 -c 'import json,sys;c=json.load(open(sys.argv[1]));print(int(c["drain_grace_s"]+c["drain_ws_max_s"]))' "$CONFIG")"

# 2. Remember the old generations BEFORE starting the new one (afterwards pgrep would match both).
mapfile -t old_pids < <(pgrep -f -- "$EXE" || true)
mapfile -t old_units < <(systemctl --user list-units --plain --no-legend "$UNIT_PREFIX-*.service" 2>/dev/null | awk '{print $1}' || true)

# 3. Start the new generation.
echo "$(ts) old generation pids: ${old_pids[*]:-none}" >&2
loginctl enable-linger "${USER:-$(id -un)}" 2>/dev/null || true
mkdir -p "$(dirname "$LOG")"
unit="$UNIT_PREFIX-$(date +%Y%m%d%H%M%S)"
systemd-run --user --collect --unit="$unit" \
  --description="Primal API daemon (ocaml-api/bin/primal_apid.exe)" \
  -p RestartSec=5 -p OOMPolicy=kill -p StartLimitIntervalSec=0 \
  -p LimitNOFILE=65536 \
  -p MemoryAccounting=yes -p MemoryHigh=12G -p MemoryMax=14G \
  -p "StandardOutput=append:$LOG" -p "StandardError=append:$LOG" \
  -p "WorkingDirectory=$P" \
  -- "$NIX" develop "path:$COMMON" -c "$EXE" "$CONFIG"

# 4. Verify: the new pid appears and /status answers FROM THE NEW PID (the admin port is shared via
#    SO_REUSEPORT during the overlap, so poll until the new generation itself is seen ready).
new_pid=""
for _ in $(seq 1 150); do
  for p in $(pgrep -f -- "$EXE" || true); do
    if ! printf '%s\n' "${old_pids[@]:-}" | grep -qx "$p"; then new_pid="$p"; fi
  done
  [[ -n "$new_pid" ]] && break
  sleep 0.2
done
ready=0
if [[ -n "$new_pid" ]]; then
  for _ in $(seq 1 100); do
    st="$(curl -s --max-time 2 "http://127.0.0.1:$admin_port/status" || true)"
    if [[ "$st" == *"\"pid\":$new_pid,"* && "$st" == *"\"state\":\"serving\""* ]]; then ready=1; break; fi
    kill -0 "$new_pid" 2>/dev/null || break
    sleep 0.3
  done
fi
if (( ! ready )); then
  echo "ERROR: new generation did not become ready; stopping unit $unit, old generation untouched" >&2
  systemctl --user stop "$unit.service" 2>/dev/null || true
  echo "see $LOG" >&2
  exit 1
fi
echo "$new_pid" >"$PIDFILE"
echo "$(ts) new generation ready: unit $unit.service pid $new_pid" >&2

# 5. Drain the old generations: SIGUSR1, wait up to grace + margin, then SIGKILL stragglers and
#    clean up their units. Any stray process from an older launch is included (matched by exe path).
if ((${#old_pids[@]})); then
  echo "$(ts) draining old generation(s): ${old_pids[*]} (grace ${drain_grace}s)" >&2
  kill -USR1 "${old_pids[@]}" 2>/dev/null || true
  for _ in $(seq 1 $(( (drain_grace + 15) * 2 ))); do
    alive=0
    for p in "${old_pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
    (( alive )) || break
    sleep 0.5
  done
  for p in "${old_pids[@]}"; do
    if kill -0 "$p" 2>/dev/null; then echo "pid $p still alive after grace; SIGKILL" >&2; kill -KILL "$p" 2>/dev/null || true; fi
  done
fi
for u in "${old_units[@]:-}"; do
  [[ -n "$u" && "$u" != "$unit.service" ]] && { systemctl --user stop "$u" 2>/dev/null || true; systemctl --user reset-failed "$u" 2>/dev/null || true; }
done

echo "$(ts) primal-api running: unit $unit.service pid $new_pid" >&2
echo "log:    $LOG" >&2
echo "status: curl -s http://127.0.0.1:$admin_port/status ; systemctl --user status $unit" >&2
echo "drain:  kill -USR1 $new_pid  (or curl -X POST http://127.0.0.1:$admin_port/drain)" >&2
