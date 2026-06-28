#!/usr/bin/env bash
# Create the standalone reference database (primal_importer_ref, used occasionally for tests) by
# cloning the schema of the live primal1 database. Because the importer's inline SQL targets
# primal1's base tables by name, the reference DB must be a schema clone of primal1.
#
# The connection parameters are HARDCODED below and cannot be overridden: there are no arguments
# and no environment variables are consulted. It always clones the schema of primal1 into
# primal_importer_ref on 127.0.0.1:54017. The target is always the reference DB, so it can never
# clobber the live source (which is only read, via pg_dump).
#
# There is no bundled schema file: the schema is taken from the source database via
# `pg_dump --schema-only` and loaded into the target database (created if missing). It copies no
# data. This is the explicit counterpart to sql/refdb-truncate.sh.
set -euo pipefail

# Hardcoded source (schema cloned FROM here, read-only) and target (reference DB created/loaded).
FROM_HOST=127.0.0.1  FROM_PORT=54017  FROM_USER=pr  FROM_DB=primal1
TO_HOST=127.0.0.1    TO_PORT=54017    TO_USER=pr    TO_DB=primal_importer_ref

# Create the target database if it does not already exist.
exists=$(psql -h "$TO_HOST" -p "$TO_PORT" -U "$TO_USER" -d postgres -tAc \
  "select 1 from pg_database where datname = '$TO_DB'")
if [ "$exists" != "1" ]; then
  echo "creating database $TO_DB on $TO_HOST:$TO_PORT"
  psql -h "$TO_HOST" -p "$TO_PORT" -U "$TO_USER" -d postgres -c "create database \"$TO_DB\""
fi

# Clone the schema (no data) from the source DB into the target DB.
echo "cloning schema-only from $FROM_DB ($FROM_HOST:$FROM_PORT) into $TO_DB ($TO_HOST:$TO_PORT)"
pg_dump --schema-only --no-owner --no-privileges \
  -h "$FROM_HOST" -p "$FROM_PORT" -U "$FROM_USER" -d "$FROM_DB" \
  | psql -h "$TO_HOST" -p "$TO_PORT" -U "$TO_USER" -d "$TO_DB" -v ON_ERROR_STOP=1
echo "reference DB '$TO_DB' ready on $TO_HOST:$TO_PORT (schema cloned from '$FROM_DB')"
