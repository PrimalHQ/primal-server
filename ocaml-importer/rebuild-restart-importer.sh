#!/usr/bin/env bash
# Rebuild the importer with dune and, if the build succeeds, (re)start main.exe as a transient
# systemd --user service logging to $HOME/var/primalserver/ocaml-importer.log.
#
# Why a systemd service (not the old `setsid ... &`): it puts main.exe in its OWN cgroup with
# memory accounting (so its RSS is attributed to it, not lumped into the shared tmux scope that the
# OOM killer previously blamed), and it AUTO-RESTARTS the importer if it dies — including a SIGKILL
# from the OOM killer. A `systemd-run --scope` cannot do the restart (scopes have no Restart=), so
# we use a service. The log is appended (not truncated per restart) so an OOM death and the restart
# that follows stay in one file; this script truncates it once, at the manual restart.
#
# "restart": any importer already running (the service and/or a stray process from an older launch)
# is stopped first, so we never end up with two importers consuming the same firehose into the same
# DB. Process matching is by the full exe path, never the bare name "main.exe" — other unrelated
# main.exe binaries run on this box (e.g. ocaml-handlers) and must not be touched.
#
# The build/run use the project flake's dev shell (nix develop "path:$P"), so main.exe inherits
# the C-library paths from flake.nix. main.exe reads ALL of its settings from the JSON config file
# passed as its sole argument (see $CONFIG below); the environment is no longer consulted at
# runtime. Edit that file directly to change a setting, then re-run this script.
set -euo pipefail

# Project dir = this script's directory; derive everything else from it.
P="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
EXE="$P/_build/default/bin/main.exe"
# All runtime settings come from this JSON file; override the path with IMPORTER_CONFIG.
CONFIG="${IMPORTER_CONFIG:-$HOME/work/itk/primal/primal-importer-config.json}"
LOG="$HOME/var/primalserver/ocaml-importer.log"
PIDFILE="$HOME/var/primalserver/ocaml-importer.pid"
UNIT=primal-ocaml-importer          # transient systemd --user unit name (-> $UNIT.service)
NIX="$(command -v nix || echo /run/current-system/sw/bin/nix)"  # abs path: user manager PATH lacks nix

# 1. Rebuild everything. On failure, stop here WITHOUT touching the running importer, so a broken
#    build leaves the current (working) process undisturbed. Build output goes to this terminal.
echo "building $P (dune build @all) ..." >&2
nix develop "path:$P" -c dune build @all

# 1b. The config file is required. Check it now — before touching the running importer — so a
#     missing config leaves the current process undisturbed (same policy as a broken build).
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config file not found: $CONFIG" >&2
  echo "       create it (see README -> Configuration for the keys/defaults) or set IMPORTER_CONFIG" >&2
  echo "       to an existing file." >&2
  exit 1
fi

# 2. Stop the running importer. First stop the service (this also cancels its auto-restart while we
#    swap the binary; otherwise Restart=always would relaunch the OLD exe the instant we kill it),
#    then reap any stray process from an older/pre-systemd launch (graceful TERM, then KILL).
#    reset-failed clears a prior failed/OOM-killed unit so systemd-run can reuse the unit name.
systemctl --user stop "$UNIT.service" 2>/dev/null || true
systemctl --user reset-failed "$UNIT.service" 2>/dev/null || true
mapfile -t old < <(pgrep -f -- "$EXE" || true)
if ((${#old[@]})); then
  echo "stopping stray importer procs: ${old[*]}" >&2
  kill -TERM "${old[@]}" 2>/dev/null || true
  for _ in $(seq 1 50); do
    pgrep -f -- "$EXE" >/dev/null || break
    sleep 0.2
  done
  if pgrep -f -- "$EXE" >/dev/null; then
    echo "still alive after TERM; sending KILL" >&2
    pkill -KILL -f -- "$EXE" 2>/dev/null || true
    sleep 0.5
  fi
fi

# 2b. Keep the user manager (and thus the service + its auto-restart) alive across logout, matching
#     the durability of the old setsid launch. Idempotent; ignore failure (may need polkit).
loginctl enable-linger "${USER:-$(id -un)}" 2>/dev/null || true

# 3. Truncate the log and clear the PID file, then launch as a transient systemd --user service in
#    its own cgroup. Restart=always brings it back after ANY exit, including an OOM SIGKILL;
#    OOMPolicy=kill makes a cgroup-level OOM take down and FAIL the unit so that restart fires;
#    StartLimitIntervalSec=0 disables systemd's "give up after N fast restarts" limiter (RestartSec
#    throttles the loop instead) so an OOM crash-loop always keeps trying. MemoryAccounting=yes so
#    `systemctl --user status $UNIT` shows the live RSS. Runs under `nix develop` for flake C-libs;
#    main.exe is a child in the same cgroup. --collect unloads the unit once it is stopped.
: >"$LOG"
: >"$PIDFILE"
systemd-run --user --collect --unit="$UNIT" \
  --description="Primal OCaml importer (ocaml-importer/bin/main.exe)" \
  -p Restart=always -p RestartSec=5 -p OOMPolicy=kill -p StartLimitIntervalSec=0 \
  -p LimitNOFILE=65536 \
  -p MemoryAccounting=yes -p MemoryHigh=9G -p MemoryMax=10G \
  -p "StandardOutput=append:$LOG" -p "StandardError=append:$LOG" \
  -p "WorkingDirectory=$P" \
  -- "$NIX" develop "path:$P" -c "$EXE" "$CONFIG"

# 4. Wait for main.exe (spawned by `nix develop`) to appear, record its PID, confirm the unit is up.
pid=""
for _ in $(seq 1 150); do
  pid="$(pgrep -n -f -- "$EXE" || true)"
  [[ -n "$pid" ]] && { echo "$pid" >"$PIDFILE"; break; }
  sleep 0.2
done

if [[ -z "$pid" ]] || ! systemctl --user is-active --quiet "$UNIT.service"; then
  echo "ERROR: importer did not start; see $LOG and: systemctl --user status $UNIT" >&2
  exit 1
fi

echo "importer started: unit $UNIT.service, main.exe pid $pid" >&2
echo "log:    $LOG" >&2
echo "status: systemctl --user status $UNIT   (shows RSS via MemoryAccounting)" >&2
echo "stop:   systemctl --user stop $UNIT" >&2
