#!/usr/bin/env bash
# A private, self-hosted Primal server on one machine: PostgreSQL, primal-fetcher (relays ->
# firehose), primal-importer (firehose -> cache DB), primal-api (the WebSocket API that Primal
# apps connect to) and primal-jobs (TrustRank, trending/explore, the derived tables). Everything
# it creates lives in var/ (gitignored); needs only nix (flakes).
#
#   selfhost/primal.sh init     PostgreSQL (nix) in var/pg, the cache and membership DBs from
#                               ocaml-common/schema, TrustRank seeds (selfhost/trust-seeds.txt),
#                               migrations, configs in var/config
#   selfhost/primal.sh build    the four daemons (dune, in the ocaml-common dev shell; the
#                               [%pgsql] checks run against var/pg), copied to var/bin
#   selfhost/primal.sh start    PostgreSQL and the daemons in the background (logs in var/log);
#                               the first start runs bootstrap before primal-jobs
#   selfhost/primal.sh bootstrap  the follow graph around the TrustRank seeds, from relays
#   selfhost/primal.sh stop | status | psql [args] | logs [name]
#
# Settings (environment): PRIMAL_VAR (default <repo>/var), PRIMAL_PG_PORT (54317),
# PRIMAL_API_PORT (8801; the other daemons' ports are 8802-8840), PRIMAL_LISTEN_HOST (127.0.0.1;
# 0.0.0.0 to serve other machines), PRIMAL_RELAYS_FILE (selfhost/relays.txt; empty = the full
# lists in ocaml-fetcher/relays), NIX (the nix binary).
set -euo pipefail
# nix-built binaries carry their own library paths; an inherited one (nix-ld hosts) breaks them
unset LD_LIBRARY_PATH

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
VAR=${PRIMAL_VAR:-$ROOT/var}
PG_PORT=${PRIMAL_PG_PORT:-54317}
API_PORT=${PRIMAL_API_PORT:-8801}
LISTEN_HOST=${PRIMAL_LISTEN_HOST:-127.0.0.1}
RELAYS_FILE=${PRIMAL_RELAYS_FILE-$ROOT/selfhost/relays.txt}
PG_USER=$(id -un)
NIX=${NIX:-nix}
NIXF=(--extra-experimental-features "nix-command flakes")
PGBIN=$VAR/postgres/bin
DAEMONS=(fetcher importer api jobs)

declare -A PORT=([API_HTTP]=8802 [API_MODERATION]=8803 [API_ADMIN]=8811 [FIREHOSE]=8820 [FETCHER_ADMIN]=8821 [IMPORTER]=8830 [JOBS_ADMIN]=8840)
declare -A EXE=([fetcher]=ocaml-fetcher/bin/primal_fetcherd.exe [importer]=ocaml-importer/bin/main.exe [api]=ocaml-api/bin/primal_apid.exe [jobs]=ocaml-jobs/bin/primal_jobsd.exe)

say() { printf '\033[1m%s\033[0m\n' "$*" >&2; }
die() { say "error: $*"; exit 1; }

psql_() { "$PGBIN/psql" -X -q -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" "$@"; }
pg_running() { [ -x "$PGBIN/pg_ctl" ] && "$PGBIN/pg_ctl" -D "$VAR/pg/data" status > /dev/null 2>&1; }
pg_start() {
  pg_running && return 0
  [ -d "$VAR/pg/data" ] || die "no database yet: run selfhost/primal.sh init"
  say "starting PostgreSQL on 127.0.0.1:$PG_PORT"
  "$PGBIN/pg_ctl" -D "$VAR/pg/data" -l "$VAR/log/postgres.log" -w \
    -o "-p $PG_PORT -k $VAR/pg/run -c listen_addresses=127.0.0.1" start > /dev/null
}

# the ocaml-common dev shell, with PG* pointing at var/pg (the shell's own PG* are its defaults)
devshell() {
  "$NIX" "${NIXF[@]}" develop "path:$ROOT/ocaml-common" -c \
    env PGHOST=127.0.0.1 PGPORT="$PG_PORT" PGUSER="$PG_USER" PGDATABASE=primal1 "$@"
}

render_configs() {
  mkdir -p "$VAR/config"
  local f relays=null key
  [ -z "$RELAYS_FILE" ] || relays="\"$RELAYS_FILE\""
  # the jobs daemon's DVM requester key (used only by the DVM roles, which selfhost doesn't run)
  [ -s "$VAR/dvm-requester.key" ] || { (umask 077; od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "$VAR/dvm-requester.key"); }
  key=$(cat "$VAR/dvm-requester.key")
  for f in "$ROOT"/selfhost/config/*.json; do
    sed -e "s|@ROOT@|$ROOT|g" -e "s|@VAR@|$VAR|g" -e "s|@PG_USER@|$PG_USER|g" -e "s|@PG_PORT@|$PG_PORT|g" \
      -e "s|@LISTEN_HOST@|$LISTEN_HOST|g" -e "s|@API_PORT@|$API_PORT|g" \
      -e "s|@API_HTTP_PORT@|${PORT[API_HTTP]}|g" -e "s|@API_MODERATION_PORT@|${PORT[API_MODERATION]}|g" \
      -e "s|@API_ADMIN_PORT@|${PORT[API_ADMIN]}|g" -e "s|@FIREHOSE_PORT@|${PORT[FIREHOSE]}|g" \
      -e "s|@FETCHER_ADMIN_PORT@|${PORT[FETCHER_ADMIN]}|g" -e "s|@IMPORTER_PORT@|${PORT[IMPORTER]}|g" -e "s|@JOBS_ADMIN_PORT@|${PORT[JOBS_ADMIN]}|g" -e "s|@DVM_SECKEY@|$key|g" \
      -e "s|\"@RELAYS_FILE@\"|$relays|g" \
      "$f" > "$VAR/config/$(basename "$f")"
  done
}

load_schema() { # db file
  local errs
  errs=$(psql_ -d "$1" -v ON_ERROR_STOP=0 -f "$2" 2>&1 | grep -c '^psql:.*ERROR' || true)
  say "  $1: $(basename "$2") loaded ($errs statements failed; 'schema public already exists' is one)"
}

cmd_init() {
  mkdir -p "$VAR"/{pg/run,log,run,bin,fetcher/state,fetcher/archive}
  say "building PostgreSQL with the schema's extensions (nix)"
  "$NIX" "${NIXF[@]}" build -f "$ROOT/selfhost/postgres.nix" -o "$VAR/postgres"
  if [ ! -d "$VAR/pg/data" ]; then
    "$PGBIN/initdb" -D "$VAR/pg/data" -U "$PG_USER" --auth=trust --encoding=UTF8 --locale=C > "$VAR/log/initdb.log"
    cat >> "$VAR/pg/data/postgresql.conf" <<EOF

# selfhost/primal.sh
shared_preload_libraries = 'pg_cron'
cron.database_name = 'primal1'
EOF
  fi
  pg_start
  local db file
  for db in primal1 primal_membership_ref; do
    if [ -z "$(psql_ -d postgres -At -c "select 1 from pg_database where datname = '$db'")" ]; then
      psql_ -d postgres -c "create database $db"
      file=$ROOT/ocaml-common/schema/cache.sql; [ "$db" = primal1 ] || file=$ROOT/ocaml-common/schema/membership.sql
      load_schema "$db" "$file"
    fi
  done
  say "TrustRank seeds"
  grep -v -e '^#' -e '^[[:space:]]*$' "$ROOT/selfhost/trust-seeds.txt" | while read -r pk name _; do
    psql_ -d primal_membership_ref -c "insert into verified_users (name, pubkey, default_name, added_at)
      select '$name', decode('$pk', 'hex'), true, now()
      where not exists (select 1 from verified_users where pubkey = decode('$pk', 'hex') and default_name)"
  done
  say "migrations"
  PATH=$PGBIN:$PATH PGHOST=127.0.0.1 PGPORT=$PG_PORT PGUSER=$PG_USER PGDATABASE=primal1 "$ROOT/ocaml-common/sql/migrate.sh"
  render_configs
  say "init done: next selfhost/primal.sh build"
}

cmd_build() {
  pg_start
  say "building the daemons (the first run downloads the OCaml toolchain)"
  (cd "$ROOT" && devshell dune build "${EXE[@]/#/./}")
  local d
  for d in "${DAEMONS[@]}"; do install -m 755 "$ROOT/_build/default/${EXE[$d]}" "$VAR/bin/primal-$d"; done
  render_configs
  for d in "${DAEMONS[@]}"; do "$VAR/bin/primal-$d" --check-config "$VAR/config/primal-$d.json" > /dev/null || die "primal-$d: config check failed"; done
  say "build done: next selfhost/primal.sh start"
}

cmd_bootstrap() {
  running importer || die "primal-importer is not running: selfhost/primal.sh start"
  say "bootstrap: the TrustRank seeds' follow graph from relays (a few minutes)"
  "$NIX" "${NIXF[@]}" build -f "$ROOT/selfhost/python.nix" -o "$VAR/python"
  SSL_CERT_FILE=$VAR/python/etc/ssl/certs/ca-bundle.crt "$VAR/python/bin/python3" -I "$ROOT/selfhost/bootstrap.py" \
    "$ROOT/selfhost/trust-seeds.txt" "${RELAYS_FILE:-$ROOT/selfhost/relays.txt}" 127.0.0.1 "${PORT[IMPORTER]}"
  touch "$VAR/bootstrap.done"
}

running() { [ -f "$VAR/run/$1.pid" ] && kill -0 "$(cat "$VAR/run/$1.pid")" 2> /dev/null; }

start_daemon() {
  setsid "$VAR/bin/primal-$1" "$VAR/config/primal-$1.json" >> "$VAR/log/$1.log" 2>&1 < /dev/null &
  echo $! > "$VAR/run/$1.pid"
  sleep 2
  running "$1" || die "primal-$1 exited at start: see $VAR/log/$1.log"
  say "primal-$1 started (pid $(cat "$VAR/run/$1.pid"), log $VAR/log/$1.log)"
}

stop_daemon() {
  local pid
  running "$1" || return 0
  pid=$(cat "$VAR/run/$1.pid"); kill "$pid"
  for _ in $(seq 60); do kill -0 "$pid" 2> /dev/null || break; sleep 0.5; done
  kill -0 "$pid" 2> /dev/null && kill -9 "$pid"
  rm -f "$VAR/run/$1.pid"; say "primal-$1 stopped"
}

cmd_start() {
  pg_start
  local d fresh=
  for d in "${DAEMONS[@]}"; do
    [ -x "$VAR/bin/primal-$d" ] || die "primal-$d not built: run selfhost/primal.sh build"
    if running "$d"; then say "primal-$d already running"; continue; fi
    if [ "$d" = jobs ] && [ ! -e "$VAR/bootstrap.done" ]; then cmd_bootstrap; fresh=1; fi
    start_daemon "$d"
  done
  if [ -n "$fresh" ]; then
    # the importer reads its humaness threshold from pubkey_trustrank at start: restart it once
    # TrustRank (which runs when primal-jobs starts) has ranked the bootstrapped graph
    say "waiting for the first TrustRank run"
    for _ in $(seq 60); do
      [ "$(psql_ -d primal1 -At -c 'select count(*) > 25 from pubkey_trustrank')" = t ] && break
      sleep 5
    done
    stop_daemon importer; start_daemon importer
  fi
  say "Primal is up: connect a Primal app to ws://$LISTEN_HOST:$API_PORT (network settings, caching service)"
}

cmd_stop() {
  local i
  for ((i = ${#DAEMONS[@]} - 1; i >= 0; i--)); do stop_daemon "${DAEMONS[$i]}"; done
  if pg_running; then "$PGBIN/pg_ctl" -D "$VAR/pg/data" -m fast stop > /dev/null; say "PostgreSQL stopped"; fi
}

cmd_status() {
  local d
  if pg_running; then echo "postgres  running  127.0.0.1:$PG_PORT"; else echo "postgres  stopped"; fi
  for d in "${DAEMONS[@]}"; do
    if running "$d"; then echo "$d  running  pid $(cat "$VAR/run/$d.pid")"; else echo "$d  stopped"; fi
  done
  if pg_running; then
    psql_ -d primal1 -At -c "select 'events: ' || count(*) || ', newest ' || coalesce(to_timestamp(max(created_at))::text, '-') from events where created_at > extract(epoch from now() - interval '1 day')" 2> /dev/null | sed 's/^/last day /'
  fi
}

case "${1:-}" in
  init) cmd_init ;;
  build) cmd_build ;;
  start) cmd_start ;;
  bootstrap) cmd_bootstrap ;;
  stop) cmd_stop ;;
  restart) cmd_stop; cmd_start ;;
  status) cmd_status ;;
  psql) shift; pg_start; exec "$PGBIN/psql" -X -h 127.0.0.1 -p "$PG_PORT" -U "$PG_USER" -d primal1 "$@" ;;
  logs) tail -n 50 -F "$VAR/log/${2:-api}.log" ;;
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
