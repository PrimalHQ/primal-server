#!/usr/bin/env bash
# Truncate the reference / cache database back to schema-only (delete all rows, keep every table).
# Run this after any binary that imports real data into the reference DB so the DB used for
# compile-time [%pgsql] checking does not accumulate production events.
#
# The connection parameters are HARDCODED below and cannot be overridden: there are no arguments
# and no environment variables are consulted. This script can therefore ONLY ever truncate
# primal_importer_ref on 127.0.0.1:54017 and can never be pointed at a live/production database
# (e.g. primal1 / primal) — not even when PG* env vars are set (the dev shell sets PGDATABASE to
# the live DB), because the connection is passed to psql explicitly via -h/-p/-U/-d.
#
# It truncates every table in the current schema; it does NOT drop the database or alter the
# schema, so the next `dune build` still type-checks.
set -euo pipefail

# Hardcoded — the only database this script is permitted to truncate.
HOST=127.0.0.1
PORT=54017
USER=pr
DB=primal_importer_ref

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
