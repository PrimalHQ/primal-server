#!/usr/bin/env bash
# Truncate the reference / cache database back to schema-only (delete all rows, keep every
# table). Run this after any binary that imports real data into the PG* DB (bin/main against the
# live firehose, bin/importcheck, etc.) so the reference DB used for compile-time [%pgsql]
# checking does not accumulate production events.
#
# This is the explicit counterpart to sql/refdb-setup.sh. Connection comes from PG* env vars
# (set by the nix devShell). It truncates every table in the current schema; it does NOT drop the
# database or alter the schema, so the next `dune build` still type-checks.
set -euo pipefail

HOST="${PGHOST:-127.0.0.1}"
PORT="${PGPORT:-54017}"
USER="${PGUSER:-pr}"
DB="${PGDATABASE:-primal_importer_ref}"

# Safety guard: never truncate a known live/production database, even if PG* happen to point at
# one (e.g. while pointing bin/zapcheck/bin/compare at the Julia box). The production DB names are
# refused outright by name; extend the list with REFDB_PROTECTED_EXTRA="name1 name2" if needed.
PROTECTED_DBS="primal1 primal ${REFDB_PROTECTED_EXTRA:-}"
for prot in $PROTECTED_DBS; do
  if [ "$DB" = "$prot" ]; then
    echo "ERROR: refusing to truncate '$DB' on $HOST:$PORT — it is a protected production database." >&2
    echo "       This script only resets the reference DB (default: primal_importer_ref)." >&2
    exit 1
  fi
done

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
