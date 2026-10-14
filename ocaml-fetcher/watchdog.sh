#!/usr/bin/env bash
# External liveness watchdog for primal-fetcher: the daemon's admin /status must answer and its
# message counter must move. Two consecutive failures (checks run every 2 minutes) restart the
# fetcher's systemd user unit (primal-ocaml-fetcher.service). It is external because a stalled
# process can stop answering on its admin port as well (a dead SOCKS proxy once froze every
# domain, the admin port included), and then no in-process watchdog could fire.
#
# Install as a systemd user timer every 2 minutes, e.g.
#   systemd-run --user --unit=primal-fetcher-watchdog --on-calendar='*:0/2' \
#     --description='primal-fetcher watchdog' \
#     -p "Environment=PATH=$HOME/.nix-profile/bin:/run/current-system/sw/bin:/usr/bin:/bin" \
#     -p "Environment=PRIMAL_FETCHER_CONFIG=/path/to/primal-fetcher-config.json" \
#     <checkout>/ocaml-fetcher/watchdog.sh
# A timer unit gets a minimal PATH: set one that has bash, curl and python3, or the check never runs.
#
# Environment:
#   PRIMAL_FETCHER_CONFIG  the fetcher's config (only admin_port is read)
#   PRIMAL_FETCHER_ADMIN   admin status URL (default from the config's admin_port)
#   PRIMAL_CONFIG_DIR      where the config is looked up when PRIMAL_FETCHER_CONFIG is unset
#   PRIMAL_VAR_DIR         where fetcher-watchdog.state and fetcher-watchdog.log are written
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# Defaults when the environment sets nothing: the config in PRIMAL_CONFIG_DIR (default two
# directories above the repo root), the state and log in PRIMAL_VAR_DIR (default $HOME/var/primalserver).
CONFIG_DIR="${PRIMAL_CONFIG_DIR:-$(cd -- "$ROOT/../.." && pwd -P)}"
VAR_DIR="${PRIMAL_VAR_DIR:-$HOME/var/primalserver}"
CONFIG="${PRIMAL_FETCHER_CONFIG:-$CONFIG_DIR/primal-fetcher-config.json}"
UNIT=primal-ocaml-fetcher
STATE="$VAR_DIR/fetcher-watchdog.state"
LOG="$VAR_DIR/fetcher-watchdog.log"
port="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["admin_port"])' "$CONFIG")"
url="${PRIMAL_FETCHER_ADMIN:-http://127.0.0.1:$port/status}"
now="$(date '+%Y-%m-%d %H:%M:%S')"
st="$(curl -s --max-time 15 "$url" 2>/dev/null || true)"
count="$(printf '%s' "$st" | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["counters"]["message_count"])
except Exception: print("")' 2>/dev/null)"
prev_count=""; prev_fail=0
[[ -f "$STATE" ]] && read -r prev_count prev_fail < "$STATE"
fail=0
if [[ -z "$count" ]]; then fail=1; reason="status not answering"
elif [[ -n "$prev_count" && "$count" == "$prev_count" ]]; then fail=1; reason="message_count unchanged ($count)"
fi
if (( fail )); then
  if (( prev_fail >= 1 )); then
    echo "$now RESTART: $reason twice in a row" >> "$LOG"
    systemctl --user restart "$UNIT.service" >> "$LOG" 2>&1
    echo "${count:-} 0" > "$STATE"
  else
    echo "$now warning: $reason" >> "$LOG"
    echo "${count:-} 1" > "$STATE"
  fi
else
  echo "$count 0" > "$STATE"
fi
