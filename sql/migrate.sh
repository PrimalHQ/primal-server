#!/usr/bin/env bash
# Versioned SQL migration runner for the Primal OCaml daemons — the single owner of
# public.schema_migrations (a table of that name left by another tool: see --take-over).
#
#   sql/migrate.sh [--dry-run | --status | --record VERSION | --take-over] [MIGRATIONS_DIR]
#
# Applies every MIGRATIONS_DIR/NNNN_name.sql (lexical order) not yet recorded, each file with
# `psql -v ON_ERROR_STOP=1 -f` — statement by statement, no wrapping transaction, so
# `create index concurrently` works. Every file runs under PGOPTIONS lock_timeout (default 5s so
# DDL fails fast instead of queueing behind a long query while the running daemons serve); a
# file that needs longer declares it in a header comment:   -- lock_timeout: 120s
#
#   --dry-run          list the pending files, apply nothing
#   --status           applied count + pending files (exit 1 when something is pending)
#   --record VERSION   record a file as applied without running it (a change made by hand)
#   --take-over        a foreign public.schema_migrations (version not text: the Ecto/sqlx layout)
#                      is renamed to schema_migrations_legacy_<date> instead of aborting
#
# The connection comes from the standard PG* variables (the dev shell points them at the local
# primal1). Apply a migration to the database the [%pgsql] checks use before building code that
# needs it (the checks see only what that database has), and to each database the daemons run on.
# Version prefixes are per-project ranges (migrations/README.md).
set -euo pipefail

mode=apply; record_version=""; take_over=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) mode=dry; shift ;;
    --status) mode=status; shift ;;
    --record) mode=record; record_version="${2:?--record needs a version}"; shift 2 ;;
    --take-over) take_over=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) break ;;
  esac
done
dir="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/migrations}"

if ! command -v psql >/dev/null 2>&1; then
  echo "migrate: psql not in PATH; run inside the dev shell (nix develop path:nix)" >&2
  exit 1
fi
# "already exists, skipping" notices are the idempotent files doing their job: keep them out of the output
export PGOPTIONS="${PGOPTIONS:-} -c client_min_messages=warning"
q() { psql -X -v ON_ERROR_STOP=1 -q -At "$@"; }
where="db ${PGDATABASE:-?} on ${PGHOST:-?}:${PGPORT:-?}"
applied_by="$(hostname -s 2>/dev/null || hostname):${USER:-?}"

# the version table: ours has a text version; anything else is another tool's
shape="$(q -c "select data_type from information_schema.columns where table_schema = 'public' and table_name = 'schema_migrations' and column_name = 'version'")"
if [[ -n "$shape" && "$shape" != "text" ]]; then
  if ((take_over)); then
    legacy="schema_migrations_legacy_$(date -u +%Y%m%d)"
    echo "migrate: public.schema_migrations has a '$shape' version column (not ours); renaming it to $legacy" >&2
    q -c "alter table public.schema_migrations rename to $legacy"
  else
    echo "migrate: public.schema_migrations exists with a '$shape' version column — another tool's table ($where). Re-run with --take-over to rename it aside." >&2
    exit 1
  fi
fi
q -c "create table if not exists public.schema_migrations (
  version text primary key, applied_at timestamptz not null default now(),
  applied_by text, checksum text, duration_ms integer)"
q -c "alter table public.schema_migrations add column if not exists applied_by text, add column if not exists checksum text, add column if not exists duration_ms integer"

applied="$(q -c "select version from public.schema_migrations")"
shopt -s nullglob
files=("$dir"/[0-9][0-9][0-9][0-9]_*.sql)
pending=()
for f in "${files[@]}"; do
  v="$(basename "$f" .sql)"
  grep -qx "$v" <<<"$applied" || pending+=("$f")
done

case "$mode" in
  status)
    echo "migrate: $(grep -c . <<<"$applied" || true) applied, ${#pending[@]} pending ($where, $dir)"
    for f in "${pending[@]}"; do echo "  pending: $(basename "$f" .sql)"; done
    [[ ${#pending[@]} -eq 0 ]] ;;
  dry)
    for f in "${pending[@]}"; do echo "would apply: $(basename "$f" .sql)"; done
    echo "migrate: ${#pending[@]} migration(s) pending ($where)" ;;
  record)
    f="$dir/$record_version.sql"
    [[ -f "$f" ]] || { echo "migrate: no such migration file: $f" >&2; exit 1; }
    sum="$(sha256sum "$f" | cut -c1-16)"
    q -c "insert into public.schema_migrations (version, applied_by, checksum, duration_ms) values ('$record_version', '$applied_by (recorded, applied by hand)', '$sum', null) on conflict (version) do nothing"
    echo "migrate: recorded $record_version ($where)" ;;
  apply)
    n=0
    for f in "${pending[@]}"; do
      v="$(basename "$f" .sql)"
      lt="$(sed -nE '1,10s/^-- *lock_timeout: *([0-9]+[a-z]*).*/\1/p' "$f" | head -1)"
      sum="$(sha256sum "$f" | cut -c1-16)"
      echo "applying: $v (lock_timeout ${lt:-5s})"
      t0=$(date +%s%3N)
      PGOPTIONS="${PGOPTIONS:-} -c lock_timeout=${lt:-5s}" psql -X -v ON_ERROR_STOP=1 -q -f "$f"
      q -c "insert into public.schema_migrations (version, applied_by, checksum, duration_ms) values ('$v', '$applied_by', '$sum', $(( $(date +%s%3N) - t0 )))"
      n=$((n+1))
    done
    echo "migrate: $n migration(s) applied ($where, $dir)" ;;
esac
