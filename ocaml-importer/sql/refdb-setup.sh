#!/usr/bin/env bash
# Create the standalone reference database (used occasionally for tests) by cloning the schema of
# an existing database. The live primal1 DB is what the build and runtime use directly now (see
# flake.nix); this reference DB is a schema-only copy of an existing DB.
#
# There is no bundled schema file: the schema is taken from the --from-* source database via
# `pg_dump --schema-only` and loaded into the --to-* target database (created if missing).
#
# The connection is taken entirely from command-line arguments (NOT environment variables, NOT
# defaults). All of --from-{host,port,user,db} and --to-{host,port,user,db} are required. This is
# the explicit counterpart to sql/refdb-truncate.sh.
set -euo pipefail

FROM_HOST= FROM_PORT= FROM_USER= FROM_DB=
TO_HOST=   TO_PORT=   TO_USER=   TO_DB=

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") \\
         --from-host H --from-port P --from-user U --from-db D \\
         --to-host   H --to-port   P --to-user   U --to-db   D

Clone the schema of the --from-* (source) database into the --to-* (target) database
via 'pg_dump --schema-only'. The target database is created if it does not exist.

All options are required (there are no defaults):
  --from-host / --from-port / --from-user / --from-db   source DB to copy the schema from
  --to-host   / --to-port   / --to-user   / --to-db     target reference DB to create/load
  --help                                                show this help and exit
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --from-host|--from-port|--from-user|--from-db|--to-host|--to-port|--to-user|--to-db)
      if [ $# -lt 2 ]; then
        echo "ERROR: option $1 requires an argument" >&2
        usage
        exit 2
      fi
      case "$1" in
        --from-host) FROM_HOST="$2" ;;
        --from-port) FROM_PORT="$2" ;;
        --from-user) FROM_USER="$2" ;;
        --from-db)   FROM_DB="$2" ;;
        --to-host)   TO_HOST="$2" ;;
        --to-port)   TO_PORT="$2" ;;
        --to-user)   TO_USER="$2" ;;
        --to-db)     TO_DB="$2" ;;
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
[ -n "$FROM_HOST" ] || missing="$missing --from-host"
[ -n "$FROM_PORT" ] || missing="$missing --from-port"
[ -n "$FROM_USER" ] || missing="$missing --from-user"
[ -n "$FROM_DB" ]   || missing="$missing --from-db"
[ -n "$TO_HOST" ]   || missing="$missing --to-host"
[ -n "$TO_PORT" ]   || missing="$missing --to-port"
[ -n "$TO_USER" ]   || missing="$missing --to-user"
[ -n "$TO_DB" ]     || missing="$missing --to-db"
if [ -n "$missing" ]; then
  echo "ERROR: missing required argument(s):$missing" >&2
  usage
  exit 2
fi

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
