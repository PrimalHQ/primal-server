#!/usr/bin/env bash
# Cutover A (ocaml-plan.md §13, Phase 3c): primal-api takes the public cache-API port 9001 on this
# host. ws-connector binds 9001 with SO_REUSEPORT, so a primal-api generation can bind it alongside;
# the kernel balances new connections between both until ws-connector is stopped.
#
#   1. config: public_ws_port 9006 -> 9001, request_log -> metrics-wsconn.log (backup kept)
#   2. ./rebuild-restart-api.sh   (new generation on 9001, old 9006 generation drained)
#   3. verify 9001 answers from primal-api
#   4. then stop ws-connector yourself:  kill -TERM <pid of 'ws-connector ... --port 9001'>
#      (it runs in tmux pane 0:19.1 from the ws-connector checkout; TERM sets shutting_down,
#       existing clients reconnect and land on primal-api)
#
# Rollback: restore the config backup, ./rebuild-restart-api.sh (primal-api back on 9006), and in
# the ws-connector checkout relaunch:
#   ./ws-connector --servername wscm --content-moderation-root <content-moderation checkout> \
#     run --handler-executable ./ws-handlers --importer-executable ./ws-importer --port 9001 \
#     --backend-addr ws://127.0.0.1:8817 --log-request $PRIMAL_VAR_DIR/metrics-wsconn.log \
#     --log-not-handled --log-handled
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# Deployment layout (every script in this repo): the daemons' JSON configs live outside the checkout
# in PRIMAL_CONFIG_DIR (default: two directories above the repo root, i.e. next to the parent repo);
# logs, pid and state files in PRIMAL_VAR_DIR (default $HOME/var/primalserver).
CONFIG_DIR="${PRIMAL_CONFIG_DIR:-$(cd -- "$ROOT/../.." && pwd -P)}"
VAR_DIR="${PRIMAL_VAR_DIR:-$HOME/var/primalserver}"
CFG=${PRIMAL_API_CONFIG:-$CONFIG_DIR/primal-api-config.json}
ts=$(date +%Y%m%d%H%M%S)
cp "$CFG" "$CFG.bak-$ts-pre-cutover"
python3 - "$CFG" "$VAR_DIR" <<'EOF'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c["public_ws_port"] = 9001
c["request_log"] = sys.argv[2] + "/metrics-wsconn.log"
with open(p, "w") as f:
    json.dump(c, f, indent=2); f.write("\n")
print("config: public_ws_port=9001 request_log=" + c["request_log"])
EOF
"$HERE/rebuild-restart-api.sh"
sleep 2
echo "--- listeners on 9001 (expect primal_apid.exe next to ws-connector until you stop it):"
ss -ltnp | grep ':9001 ' || true
echo "--- primal-api status:"
curl -s http://127.0.0.1:14006/status; echo
echo "--- one request through 9001 (server_name):"
"$HERE/../_build/default/ocaml-api/bin/primalctl.exe" req ws://127.0.0.1:9001 server_name || true
echo
echo "Now stop ws-connector:  kill -TERM \$(pgrep -f 'ws-connector.*--port 9001')"
echo "and confirm nothing relaunches it:  sleep 5; ss -ltnp | grep ':9001 '"
