#!/usr/bin/env bash
# Truncate the reference / cache database back to schema-only (delete all rows, keep every
# table). Run this after any binary that imports real data into the reference DB (bin/main against
# the live firehose, bin/importcheck, etc.) so the DB used for compile-time [%pgsql] checking does
# not accumulate production events.
#
# This is the explicit counterpart to sql/refdb-setup.sh. The connection is taken entirely from
# command-line arguments (NOT environment variables, NOT defaults): all of -h/-p/-U/-d are
# required. It truncates every table in the current schema; it does NOT drop the database or alter
# the schema, so the next `dune build` still type-checks.
set -euo pipefail

HOST=
PORT=
USER=
DB=

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") -h HOST -p PORT -U USER -d DBNAME

Truncate every table in the reference database back to schema-only.

All options are required (there are no defaults):
  -h HOST     PostgreSQL host
  -p PORT     PostgreSQL port
  -U USER     PostgreSQL user
  -d DBNAME   database to truncate
  --help      show this help and exit

As a safety guard, DBNAME must be exactly 'primal_importer_ref'; any other name
(e.g. a production DB such as primal1 or primal) is refused.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|-p|-U|-d)
      if [ $# -lt 2 ]; then
        echo "ERROR: option $1 requires an argument" >&2
        usage
        exit 2
      fi
      case "$1" in
        -h) HOST="$2" ;;
        -p) PORT="$2" ;;
        -U) USER="$2" ;;
        -d) DB="$2" ;;
      esac
      shift 2
      ;;
    --help|-\?)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$1'" >&2
      usage
      exit 2
      ;;
  esac
done

# All connection arguments are mandatory — no defaults.
missing=
[ -n "$HOST" ] || missing="$missing -h"
[ -n "$PORT" ] || missing="$missing -p"
[ -n "$USER" ] || missing="$missing -U"
[ -n "$DB" ]   || missing="$missing -d"
if [ -n "$missing" ]; then
  echo "ERROR: missing required argument(s):$missing" >&2
  usage
  exit 2
fi

# Safety guard: only ever truncate the reference database, named exactly 'primal_importer_ref'.
# Any other name (every production DB, e.g. primal1 / primal) is refused outright, even if -d
# points at it.
if [ "$DB" != "primal_importer_ref" ]; then
  echo "ERROR: refusing to truncate '$DB' on $HOST:$PORT — only the reference DB 'primal_importer_ref' may be reset." >&2
  echo "       This guards against wiping a live/production database (e.g. primal1, primal)." >&2
  exit 1
fi

echo "truncating all tables in $DB on $HOST:$PORT (schema preserved)"
psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -v ON_ERROR_STOP=1 <<'SQL'
do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = current_schema() loop
    execute format('truncate table %I cascade', r.tablename);
  end loop;
end $$;
SQL
echo "reference DB '$DB' truncated to schema-only"
