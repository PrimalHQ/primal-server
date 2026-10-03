#!/usr/bin/env bash
# Versioned SQL migration runner for the Primal OCaml daemons (replaces the Julia code_load.jl
# path that pushed changed SQL to running servers over the EVAL port).
#
#   sql/migrate.sh [--dry-run] [MIGRATIONS_DIR]
#
# Applies every MIGRATIONS_DIR/NNNN_name.sql (lexical order) not yet recorded in
# public.schema_migrations, each with `psql -v ON_ERROR_STOP=1`, under PGOPTIONS lock_timeout=5s so
# DDL fails fast instead of queueing behind a long-running query while the old daemons still serve.
# The connection comes from the standard PG* variables (the dev shell points them at primal1).
# Default MIGRATIONS_DIR is this script's ../sql/migrations; other projects (ocaml-api/sql,
# ocaml-ext/sql) pass their own directory and share the same version table, so file prefixes must
# be unique across projects — use the ranges documented in migrations/README.md.
set -euo pipefail

dry_run=0
if [[ "${1:-}" == "--dry-run" ]]; then dry_run=1; shift; fi
dir="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/migrations}"

if ! command -v psql >/dev/null 2>&1; then
  echo "migrate: psql not in PATH; run inside the dev shell (nix develop path:ocaml-common)" >&2
  exit 1
fi

export PGOPTIONS="${PGOPTIONS:-} -c lock_timeout=5s"
psql -v ON_ERROR_STOP=1 -q -c "create table if not exists public.schema_migrations (
  version text primary key, applied_at timestamptz not null default now())"

applied="$(psql -At -c "select version from public.schema_migrations")"
shopt -s nullglob
n=0
for f in "$dir"/[0-9][0-9][0-9][0-9]_*.sql; do
  v="$(basename "$f" .sql)"
  if grep -qx "$v" <<<"$applied"; then continue; fi
  n=$((n+1))
  if ((dry_run)); then echo "would apply: $v"; continue; fi
  echo "applying: $v"
  psql -v ON_ERROR_STOP=1 -q -f "$f"
  psql -v ON_ERROR_STOP=1 -q -c "insert into public.schema_migrations (version) values ('$v')"
done
echo "migrate: $n migration(s) $([[ $dry_run == 1 ]] && echo pending || echo applied) from $dir (db ${PGDATABASE:-?} on ${PGHOST:-?}:${PGPORT:-?})"
