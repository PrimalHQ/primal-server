# primal-importer

An OCaml 5 / Eio reimplementation of the core **event-import pipeline** of the Primal
Nostr cache server (the Julia `primal-server/src/cache_storage.jl` import path, started by
`start_media_importer.jl`). It reads fetched Nostr events from a firehose, verifies and
parses them, and writes them into PostgreSQL via inline `[%pgsql]` queries that are
**type-checked against the live schema at compile time**.

Module and function names mirror the Julia source so the two codebases navigate the same
way (`import_event`, `import_contact_list`, `event_pubkey_action`, `ext_text_note`, …).

This project is **standalone** — it shares no code with `ocaml-handlers`. It is Eio-native
(no Lwt).

---

## Building and the dev shell

Everything runs inside the project's Nix flake. Because this directory is **untracked by
git**, refer to the flake with the `path:` scheme (the plain `.#` form will not see the
files):

```sh
P=/home/pr/work/itk/primal/primal-net-server/primal-server/ocaml-importer

nix develop "path:$P"                       # interactive dev shell
nix develop "path:$P" -c dune build @all    # build everything
nix develop "path:$P" -c dune test          # run the unit tests (alcotest)
nix develop "path:$P" -c dune exec bin/main.exe   # run a binary
```

The dev shell exports the `PG*` variables (see below) that point the `[%pgsql]` ppx at a
**reference database** used purely for compile-time schema checking. `dune build` *fails*
if any inline SQL does not match that schema.

### One-time reference DB setup

The reference DB must exist before the first build. Create/load it from the importer
schema:

```sh
nix develop "path:$P" -c sql/refdb-setup.sh
```

This creates `primal_importer_ref` (if missing) on `127.0.0.1:54017` and loads
`sql/importer_schema.sql`. The build, and several of the dev binaries below, only need the
schema — not data.

### Resetting the reference DB to schema-only

Binaries that import real data (`bin/main` against the live firehose, `bin/importcheck`, …)
write into the cache DB — which defaults to this reference DB. To clear that data back to
schema-only (every table truncated, schema preserved so `dune build` still type-checks),
run the explicit counterpart of the setup script:

```sh
nix develop "path:$P" -c sql/refdb-truncate.sh
```

It targets the `PG*` database and never drops or alters the schema. Run it after any live
import session. As a safety guard it **only accepts the database named exactly
`primal_importer_ref`**. Any other name (every production DB, such as `primal1` or
`primal`) is refused even if `PG*` are pointed there.

---

## Configuration (environment variables)

All configuration is read from the environment; there are no config files. Binaries that
take positional CLI arguments are noted in the per-binary section.

### Database connections

The importer talks to up to three logical databases. On a single-box staging setup they
can all be the same Postgres — the membership and compare connections **default to the
cache connection**, so only the `PG*` set is required.

| Variable | Default | Purpose |
|---|---|---|
| `PGHOST` | `127.0.0.1` | Cache / local DB host (Julia `:p0`). The DB the importer writes to. |
| `PGPORT` | `54017` | Cache DB port. |
| `PGUSER` | `pr` | Cache DB user. |
| `PGDATABASE` | `primal_importer_ref` | Cache DB name. Also the compile-time reference DB. |
| `PGMEMBERSHIPHOST` | = `PGHOST` | Membership DB host (Julia `:membership`): `filterlist`, `human_override`. |
| `PGMEMBERSHIPPORT` | = `PGPORT` | Membership DB port. |
| `PGMEMBERSHIPUSER` | = `PGUSER` | Membership DB user. |
| `PGMEMBERSHIPDATABASE` | = `PGDATABASE` | Membership DB name. |
| `COMPARE_HOST` | `192.168.44.7` | Remote DB host for `bin/compare` (the Julia importer's Postgres). |
| `COMPARE_PORT` | = `PGPORT` | Remote DB port. |
| `COMPARE_USER` | = `PGUSER` | Remote DB user. |
| `COMPARE_DATABASE` | = `PGDATABASE` | Remote DB name (e.g. `primal1` on the Julia box). |

### Importer runtime (used by `bin/main`)

| Variable | Default | Purpose |
|---|---|---|
| `NODE_IDX` (or `PRIMALSERVER_NODE_IDX`) | `17` | Node index; only used to derive the default firehose port. |
| `PRIMALSERVER_FIREHOSE_HOST` | `127.0.0.1` | Firehose TCP host. |
| `PRIMALSERVER_FIREHOSE_PORT` | `9000 + NODE_IDX` (→ `9017`) | Firehose TCP port. |
| `IMPORTER_WORKERS` | `4` | Number of worker **domains** (parallel import lanes). |
| `IMPORTER_QUEUE_CAPACITY` | `10000` | Bounded firehose→workers queue size (backpressure; never drops). |
| `IMPORTER_VERIFY` | `true` | Verify each event's BIP340 signature before import. |
| `VERIFY_ZAPPERS` | `true` | Verify zap receipts via LNURL (see proxy below). When `false`, all zappers pass. |
| `PRIMALSERVER_PROXY` | *(none)* | SOCKS5 proxy for LNURL egress, e.g. `socks5h://192.168.41.2:1080` (a bare `host:port` also works). `socks5h://` resolves DNS at the proxy. |
| `IMPORTER_DISABLE_TRUSTRANK` | `false` | When `true`, seed `pubkey_trustrank = 1.0` for every new pubkey so `ext_is_human` is true for everyone (use when no TrustRankMaker feeds this DB). |
| `IMPORTER_HUMANESS_THRESHOLD` | `0.0` | `ext_is_human` passes when `pubkey_trustrank.rank >` this threshold. |
| `IMPORTER_IMPORT_REPORTING` | `false` | Process NIP-56 kind-1984 reports into the membership `filterlist`. |
| `IMPORTER_REPORTING_WHITELIST` | *(empty)* | Comma-separated **hex** pubkeys allowed to file reports (only honored when `IMPORTER_IMPORT_REPORTING=true`). |

Booleans accept `1/true/yes/on` and `0/false/no/off`.

> **Note on trustrank-gated data.** `og_zap_receipts`, the `replies` stat counter, and the
> per-event score require trustrank data (`pubkey_trustrank`), which is produced by the
> separate Julia TrustRankMaker. A bare reference DB has none, so those stay empty even
> though zap verification itself works — set `IMPORTER_DISABLE_TRUSTRANK=true` to exercise
> those paths locally.

---

## Binaries

Build any of them with `dune build bin/<name>.exe` and run with
`nix develop "path:$P" -c dune exec bin/<name>.exe [args]` (or run the built artifact
directly: `_build/default/bin/<name>.exe [args]`). All read their DB connection and config
from the environment variables above.

### `main` — the importer

The production entry point. No CLI arguments. Wires the firehose client, the spam
detector, the LNURL zapper verifier, the worker-domain pool, and a periodic
scheduled-hooks runner, then imports forever (reconnecting to the firehose on drop).

```sh
# default: firehose 127.0.0.1:9017, 4 workers, writes to PG* DB
nix develop "path:$P" -c dune exec bin/main.exe

# example: explicit firehose + LNURL proxy + trustrank seeding
PRIMALSERVER_FIREHOSE_PORT=9017 \
PRIMALSERVER_PROXY=socks5h://192.168.41.2:1080 \
IMPORTER_DISABLE_TRUSTRANK=true \
nix develop "path:$P" -c dune exec bin/main.exe
```

> Writes to the cache DB (`PG*`), which defaults to the reference DB. After live runs
> against the real firehose, truncate it back to schema-only.

### `compare [window_seconds] [margin_seconds]` — parity check

Diffs recent rows between the **local** cache DB (`PG*`) and a **remote** DB (`COMPARE_*`,
the Julia importer). Windows on each event's `created_at` in `[now-window, now-margin]`
(intrinsic and identical across both importers; the margin skips the leading edge where
one side may still be catching up). Reports per-table local/remote counts plus
only-local / only-remote / mismatch with sample diffs.

- `window_seconds` — default `3600`
- `margin_seconds` — default `60`

```sh
# compare the last 7 minutes (excluding the most recent minute) against primal1
COMPARE_HOST=192.168.44.7 COMPARE_DATABASE=primal1 \
nix develop "path:$P" -c dune exec bin/compare.exe 420 60
```

Tables compared: `events`, `event_stats` (likes…satszapped; score/score24h excluded as
time-decayed), `pubkey_events`, `event_replies`, `event_pubkey_actions`, `meta_data`,
`contact_lists`, `og_zap_receipts`, `parametrized_replaceable_events`.

### `zapcheck [N]` — LNURL zapper verification check

Exercises `Lnurl.verify` against the most recent `N` real kind-9735 zap receipts in the DB
pointed to by `PG*` (point these at a DB that has metadata + zaps, e.g. the Julia box).
Uses `PRIMALSERVER_PROXY` for egress. Reports how many verified.

- `N` — default `20`

```sh
PGHOST=192.168.44.7 PGDATABASE=primal1 \
PRIMALSERVER_PROXY=socks5h://192.168.41.2:1080 \
nix develop "path:$P" -c dune exec bin/zapcheck.exe 20
```

### `importcheck [path-to-events.jsonl]` — replay events from a file

Imports events (one JSON event object per line) into the cache DB through the full
`import_event` path (signature verification on). Reports `imported/total` and the resulting
`events` row count.

- `path` — default `test/events.jsonl`

```sh
nix develop "path:$P" -c dune exec bin/importcheck.exe /path/to/events.jsonl
```

### `dbcheck` — adapter smoke test

Connects to the cache DB with the Eio-native PGOCaml adapter and runs `select 1`. No args.
Use it to confirm DB connectivity / credentials.

```sh
nix develop "path:$P" -c dune exec bin/dbcheck.exe
```

### `scorecheck` — score_event_cb firing check

Imports a synthetic note and a like from a trusted pubkey and asserts that
`event_stats.score` / `score24h` / `score_expiry` land. No args. Writes and cleans up test
rows in the cache DB (verification disabled so synthetic unsigned events are accepted).

```sh
nix develop "path:$P" -c dune exec bin/scorecheck.exe
```

### `phase8check` — filterlist / scheduled-hook / reporting check

Focused checks: membership→local `filterlist` write/read roundtrip, a due
`expire_hashtag_score_cb` decrementing a hashtag score, and a whitelisted kind-1984 report
blocking the reported pubkey/event. No args. Uses the cache DB for both roles and cleans up
after itself.

```sh
nix develop "path:$P" -c dune exec bin/phase8check.exe
```

---

## Notes

- `main`, `importcheck`, `scorecheck`, and `phase8check` **write** to the cache DB, which
  by default is the compile-time reference DB (`primal_importer_ref`). After runs that
  import real data, reset it with `sql/refdb-truncate.sh` (see *Resetting the reference DB
  to schema-only* above).
- The unit tests (`dune test`) cover pure logic only (NIP-01 event id, BIP340 schnorr,
  bech32 lud06 / NIP-19, real-event vectors) and need no database beyond the compile-time
  schema check.
