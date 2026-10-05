#!/usr/bin/env bash
# External liveness watchdog for primal-fetcher: the daemon's admin /status must answer and its
# message counter must move. Two consecutive failures (checks run every 2 minutes) restart the unit.
# Why external: on 2026-10-05 00:53–04:52 the whole process froze (every domain, the admin port
# included) after the SOCKS proxy died, so no in-process watchdog could have fired.
#   install (user timer, every 2 min):
#     systemd-run --user --unit=primal-fetcher-watchdog --on-calendar='*:0/2' --description='primal-fetcher watchdog' \
#       <checkout>/ocaml-fetcher/watchdog.sh
#   PRIMAL_FETCHER_ADMIN  admin status URL (default from the config's admin_port)
set -u
CONFIG="${PRIMAL_FETCHER_CONFIG:-$PRIMAL_CONFIG_DIR/primal-fetcher-config.json}"
UNIT=primal-ocaml-fetcher
STATE="$PRIMAL_VAR_DIR/fetcher-watchdog.state"
LOG="$PRIMAL_VAR_DIR/fetcher-watchdog.log"
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
