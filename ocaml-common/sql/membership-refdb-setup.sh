#!/usr/bin/env bash
# Rebuild the local schema-only clone of the MEMBERSHIP database (primal_membership_ref), used by
# the PGOCaml [%pgsql] ppx to type-check membership-table queries at compile time. Membership
# tables (app_settings, memberships, filterlist, media_uploads, ...) do not exist in primal1, so the
# dune directories holding membership queries set PGDATABASE=primal_membership_ref in their
# (env ...) stanza and the ppx checks against this clone.
#
# The source host comes from PRIMAL_MEMBERSHIP_HOST (required); the rest is fixed: source port
# 5432, user and database `primal` (read-only via pg_dump), target primal_membership_ref on the dev
# shell's local Postgres (127.0.0.1:54017, user pr). The target is dropped and recreated each run;
# the source is never written. Schema only: no data is copied. Re-run whenever the membership
# schema changes. (schema/membership.sql is the baseline alternative to cloning a live DB.)
set -euo pipefail

FROM_HOST="${PRIMAL_MEMBERSHIP_HOST:?set PRIMAL_MEMBERSHIP_HOST to the membership Postgres host}"  FROM_PORT=5432   FROM_USER=primal  FROM_DB=primal
TO_HOST=127.0.0.1       TO_PORT=54017    TO_USER=pr        TO_DB=primal_membership_ref

echo "rebuilding $TO_DB on $TO_HOST:$TO_PORT (drop + recreate)"
psql -h "$TO_HOST" -p "$TO_PORT" -U "$TO_USER" -d postgres -c "drop database if exists \"$TO_DB\" with (force)"
psql -h "$TO_HOST" -p "$TO_PORT" -U "$TO_USER" -d postgres -c "create database \"$TO_DB\""

echo "cloning public schema-only from $FROM_DB ($FROM_HOST:$FROM_PORT) into $TO_DB"
# --no-subscriptions/--no-publications: none of the replication config; extensions the membership
# DB uses but the clone lacks are tolerated (ON_ERROR_STOP off for the restore, errors are listed).
pg_dump --schema-only --no-owner --no-privileges --no-subscriptions --no-publications -n public \
  -h "$FROM_HOST" -p "$FROM_PORT" -U "$FROM_USER" -d "$FROM_DB" \
  | grep -vE "^(CREATE SCHEMA public;|COMMENT ON SCHEMA public)" \
  | psql -h "$TO_HOST" -p "$TO_PORT" -U "$TO_USER" -d "$TO_DB" -q 2>&1 \
  | grep -E "^ERROR" | sort | uniq -c || true
echo "reference DB '$TO_DB' ready (public schema cloned from '$FROM_DB')"
