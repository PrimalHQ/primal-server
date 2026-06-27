#!/usr/bin/env bash
# Create and load the reference database used by the PGOCaml [%pgsql] ppx for compile-time
# schema checking. Connection comes from PG* env vars (set by the nix devShell).
set -euo pipefail

HOST="${PGHOST:-127.0.0.1}"
PORT="${PGPORT:-54017}"
USER="${PGUSER:-pr}"
DB="${PGDATABASE:-primal_importer_ref}"
HERE="$(cd "$(dirname "$0")" && pwd)"

exists=$(psql -h "$HOST" -p "$PORT" -U "$USER" -d postgres -tAc \
  "select 1 from pg_database where datname = '$DB'")
if [ "$exists" != "1" ]; then
  echo "creating database $DB"
  psql -h "$HOST" -p "$PORT" -U "$USER" -d postgres -c "create database \"$DB\""
fi

psql -h "$HOST" -p "$PORT" -U "$USER" -d "$DB" -v ON_ERROR_STOP=1 -f "$HERE/importer_schema.sql"
echo "reference DB '$DB' ready on $HOST:$PORT"
