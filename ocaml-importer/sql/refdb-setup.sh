#!/usr/bin/env bash
# Rebuild the standalone reference database (primal_importer_ref, used occasionally for tests) as
# a schema-only clone of the live primal1 PUBLIC schema. The importer's inline SQL targets
# primal1's base tables by name, so the reference DB must mirror that schema.
#
# Connection parameters are HARDCODED below and cannot be overridden: there are no arguments and
# no environment variables are consulted. It always clones primal1's public schema into
# primal_importer_ref on 127.0.0.1:54017. The target (the reference DB) is dropped and recreated
# each run; it can never touch the live source, which is only read via pg_dump.
#
# Only the `public` schema is cloned, with subscriptions and publications excluded, so the clone
# pulls in none of primal1's replication config, extensions, or other (pg_cron/age/plv8/...)
# schemas — just the tables/types/functions the importer needs. Schema only: no data is copied.
# This is the explicit counterpart to sql/refdb-truncate.sh.
set -euo pipefail

# Hardcoded source (read-only, cloned FROM) and target (reference DB, rebuilt each run).
FROM_HOST=127.0.0.1  FROM_PORT=54017  FROM_USER=pr  FROM_DB=primal1
TO_HOST=127.0.0.1    TO_PORT=54017    TO_USER=pr    TO_DB=primal_importer_ref

echo "rebuilding $TO_DB on $TO_HOST:$TO_PORT (drop + recreate)"
psql -h "$TO_HOST" -p "$TO_PORT" -U "$TO_USER" -d postgres -c "drop database if exists \"$TO_DB\" with (force)"
psql -h "$TO_HOST" -p "$TO_PORT" -U "$TO_USER" -d postgres -c "create database \"$TO_DB\""

echo "cloning public schema-only from $FROM_DB ($FROM_HOST:$FROM_PORT) into $TO_DB"
pg_dump --schema-only --no-owner --no-privileges --no-subscriptions --no-publications -n public \
  -h "$FROM_HOST" -p "$FROM_PORT" -U "$FROM_USER" -d "$FROM_DB" \
  | grep -vE "^(CREATE SCHEMA public;|COMMENT ON SCHEMA public)" \
  | psql -h "$TO_HOST" -p "$TO_PORT" -U "$TO_USER" -d "$TO_DB" -v ON_ERROR_STOP=1
echo "reference DB '$TO_DB' ready (public schema cloned from '$FROM_DB')"
