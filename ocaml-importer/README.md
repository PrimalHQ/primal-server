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
P=$HOME/work/itk/primal/primal-net-server/primal-server/ocaml-importer

nix develop "path:$P"                       # interactive dev shell
nix develop "path:$P" -c dune build @all    # build everything
nix develop "path:$P" -c dune test          # run the unit tests (alcotest)
nix develop "path:$P" -c dune exec bin/main.exe   # run a binary
```

The dev shell exports the `PG*` variables (see below). By default they point the `[%pgsql]`
ppx — and the binaries at runtime — at the **live `primal1` database** (compile-time schema
checking and runtime now both use the live DB). `dune build` *fails* if any inline SQL does
not match that live schema.

### Reference DB (occasional, for tests)

A standalone reference DB (`primal_importer_ref`) is no longer required for the build — it
is only used occasionally for tests. There is no bundled schema file; instead it is rebuilt
as a **schema-only clone of the live `primal1` public schema** (the importer's inline SQL
targets primal1's base tables by name, so the reference DB must mirror that schema). It takes
**no arguments**; the connection is **hardcoded** (`pg_dump` from `primal1` into
`primal_importer_ref`, both on `127.0.0.1:54017`, user `pr`) and cannot be overridden:

```sh
nix develop "path:$P" -c sql/refdb-setup.sh
```

Each run **drops and recreates** the reference DB, then clones only primal1's `public` schema
with `--no-subscriptions --no-publications` — so it pulls in none of primal1's replication
config, extensions, or other schemas (`pg_cron`/`age`/`plv8`/…), just the tables/types the
importer needs. The target is always the reference DB, so it can never clobber the live source
(read-only via `pg_dump`). No data is copied.

### Resetting the reference DB to schema-only

Binaries that import real data (`bin/importcheck`, …) can be pointed at the reference DB to
keep test data out of the live DB. To clear it back to schema-only (every table truncated,
schema preserved so `dune build` still type-checks), run the explicit counterpart of the
setup script:

```sh
nix develop "path:$P" -c sql/refdb-truncate.sh
```

It takes **no arguments**. The connection is **hardcoded** to `primal_importer_ref` on
`127.0.0.1:54017` (user `pr`) and cannot be overridden — not even via `PG*` env vars (the
dev shell points those at the live DB; the script passes its connection to `psql` explicitly).
It can therefore *only* ever truncate the reference DB and can never touch a live/production DB
(e.g. `primal1`, `primal`). It never drops or alters the schema.

---

## Configuration (JSON file)

`bin/main` (the importer) reads **all** of its settings from a single JSON config file passed
as its sole command-line argument; the environment is **not** consulted at runtime. The file
lives at `$HOME/work/itk/primal/primal-importer-config.json` (outside the repo — it is a
deployment artifact); `rebuild-restart-importer.sh` passes that path automatically (override with
`IMPORTER_CONFIG`). Edit the file directly to change a setting, then restart.

The JSON keys mirror the variables below with the `IMPORTER_`/`PRIMALSERVER_` prefixes dropped
(e.g. `IMPORTER_WORKERS` → `num_workers`, `PRIMALSERVER_FIREHOSE_HOST` → `firehose_host`,
`IMPORTER_VERIFY` → `verification_enabled`); the DB connections become the nested `cache_db` /
`membership_db` objects (`{host, port, user, database}`); and the derive-only inputs (`NODE_IDX`,
`PRIMALSERVER_REPORT_NODE_IDX`, `PRIMALSERVER_STORAGE_PATH`) are not stored — their resolved
outputs (`firehose_port`, `pushgateway_job`, `pushgateway_stats_file`) appear directly. `proxy`
and `humaness_threshold` are `null` when unset; pubkey lists are lowercase-hex string arrays.
Every key is **required** — the file is authoritative, so a missing key is an error rather than a
silent fallback. The defaults below are the values `bin/main` shipped with (also encoded in
`Config.from_env`, which the dev tools read); use them to author or repair the file by hand.

The **dev tools** (`bin/compare`, etc.) still read the environment (`PG*` / `COMPARE_*`); only
`bin/main` is config-file driven. The tables below give each option's env name (as read by the
dev tools) and default. Binaries that take positional CLI arguments are noted in the per-binary
section.

### Database connections

The importer talks to up to three logical databases. On a single-box staging setup they
can all be the same Postgres — the membership and compare connections **default to the
cache connection**, so only the `PG*` set is required.

| Variable | Default | Purpose |
|---|---|---|
| `PGHOST` | `127.0.0.1` | Cache / local DB host (Julia `:p0`). The DB the importer writes to. |
| `PGPORT` | `54017` | Cache DB port. |
| `PGUSER` | `pr` | Cache DB user. |
| `PGDATABASE` | `primal1` | Cache DB name; the **live** DB used for both compile-time `[%pgsql]` checks and runtime (dev shell sets this). The code fallback when unset is `primal_importer_ref`. |
| `PGMEMBERSHIPHOST` | `192.168.11.7` (dev shell); code fallback `= PGHOST` | Membership DB host (Julia `:membership`): `filterlist`, `human_override`, and the notification-gate tables `app_settings` / `notification_settings` (see [Notifications](#notifications)). The dev shell sets this to the real membership DB so the serving-layer notification gates are active; the code fallback when unset is the cache connection. |
| `PGMEMBERSHIPPORT` | `5432` (dev shell); fallback `= PGPORT` | Membership DB port. |
| `PGMEMBERSHIPUSER` | `primal` (dev shell); fallback `= PGUSER` | Membership DB user. |
| `PGMEMBERSHIPDATABASE` | `primal` (dev shell); fallback `= PGDATABASE` | Membership DB name. |
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
| `IMPORTER_HUMANESS_THRESHOLD` | *(computed)* | `ext_is_human` passes when `pubkey_trustrank.rank >` this threshold. Unset, it is computed once at startup as the rank of the 50,000th-highest-ranked pubkey in `pubkey_trustrank` (mirroring Julia `TrustRank.load`; `0.0` if the table is empty). Set it to pin an explicit override. |
| `IMPORTER_IMPORT_REPORTING` | `false` | Process NIP-56 kind-1984 reports into the membership `filterlist`. |
| `IMPORTER_REPORTING_WHITELIST` | *(empty)* | Comma-separated **hex** pubkeys allowed to file reports (only honored when `IMPORTER_IMPORT_REPORTING=true`). |
| `IMPORTER_EVENT_SYNC` | `true` | Enable the event syncer (pull recent events from peer nodes into the import queue — see [Event syncer](#event-syncer)). |
| `IMPORTER_EVENT_SYNC_REMOTES` | `192.168.40.7,192.168.42.7,192.168.43.7,192.168.44.7` | Comma-separated peer Postgres hosts to pull from (same port/credentials as the local cache DB). |
| `IMPORTER_EVENT_SYNC_INTERVAL` | `60` | Seconds between sync cycles. |
| `IMPORTER_EVENT_SYNC_OVERLAP` | `600` | Seconds of lookback behind the local max `created_at` each cycle (the 10-minute self-healing window). |
| `IMPORTER_PUSHGATEWAY` | `true` | Publish the cumulative imported-event count (`cache_any`) to a Prometheus pushgateway (see [Pushgateway](#pushgateway)). |
| `IMPORTER_PUSHGATEWAY_HOST` | `127.0.0.1` | Pushgateway host. |
| `IMPORTER_PUSHGATEWAY_PORT` | `9091` | Pushgateway port. |
| `IMPORTER_PUSHGATEWAY_JOB` | `primalnode<report-node>` | Pushgateway `job` label (Prometheus exposes it as `exported_job`). |
| `IMPORTER_STATS_FILE` | `<storage>/primalnode<report-node>/cache/db/stats.json` | Julia stats file the `cache_any` total is loaded from and persisted to. |
| `IMPORTER_PUSHGATEWAY_INTERVAL` | `15` | Seconds between pushes. |
| `PRIMALSERVER_REPORT_NODE_IDX` | `18` | Reporting node identity for the two defaults above (distinct from the firehose node `NODE_IDX`). |
| `PRIMALSERVER_STORAGE_PATH` | `$HOME/var/primalserver` | Storage root for the default `IMPORTER_STATS_FILE`. |

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
directly: `_build/default/bin/<name>.exe [args]`). `bin/main` takes a required JSON config
path (see [Configuration](#configuration-json-file)); the dev tools read their DB connection
and config from the environment variables above.

### `main` — the importer

The production entry point. Takes the JSON config file as its sole argument (see
[Configuration](#configuration-json-file)). Wires the firehose client, the spam
detector, the LNURL zapper verifier, the worker-domain pool, the [event syncer](#event-syncer),
and a periodic scheduled-hooks runner, then imports forever (reconnecting to the firehose on
drop). Imports also produce in-DB [notifications](#notifications). It prints a one-line
per-second stats summary (receive/import/dup/reject rates, queue depth, busy workers).

During development, don't run this by hand — use `rebuild-restart-importer.sh` (see
[Development loop](#development-loop)) so a fresh build is always the one running and you can
watch the live DB.

```sh
# run the importer with all settings from the JSON file (firehose, workers, DBs, proxy, …)
nix develop "path:$P" -c dune exec bin/main.exe -- $HOME/work/itk/primal/primal-importer-config.json

# to change a setting (e.g. explicit firehose port, LNURL proxy, trustrank seeding), edit the JSON
# file — proxy: "socks5h://192.168.41.2:1080", disable_trustrank: true, firehose_port: 9017 — and
# restart.
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

## Development loop

`rebuild-restart-importer.sh` (repo: `ocaml-importer/`) is the standard way to run `main`
while developing: it rebuilds everything with dune and, **only if the build succeeds**,
(re)starts `main.exe` as a detached background process, replacing any importer already running
from this project's binary. stdout+stderr (including the per-second stats line and
`event_syncer:` lines) go to `$HOME/var/primalserver/ocaml-importer.log` (truncated each run);
the pid and log path are printed to stderr.

```sh
./rebuild-restart-importer.sh
# tail -f $HOME/var/primalserver/ocaml-importer.log
```

**Use it after any change to importer code or SQL.** Because `main` writes to the live `primal1`
DB, keeping a freshly-built `main` always running lets you verify in real time that a change
produces the right rows — edit, `./rebuild-restart-importer.sh`, then watch the log and query the
DB (e.g. `event`, `event_stats_1_1b380f4869`, `pubkey_notifications_1_e5459ab9dd`). Runtime env
overrides propagate, e.g. `PRIMALSERVER_PROXY=socks5h://… ./rebuild-restart-importer.sh`.

## Event syncer

On a timer (`IMPORTER_EVENT_SYNC_INTERVAL`, default 60 s) `main` pulls the most recent events
from each peer node's `event` table (`IMPORTER_EVENT_SYNC_REMOTES`) and feeds them into the same
import queue as the firehose, so events any single node missed still land locally. Each cycle the
lower bound is `min(now, local max created_at) − IMPORTER_EVENT_SYNC_OVERLAP` (default 10 min): a
fixed lookback behind the newest event already held. Re-importing already-seen events is cheap and
safe (`store_event` is an atomic `ON CONFLICT` claim, so they count as duplicates), which makes
the sync self-healing across restarts and firehose gaps. The window query is index-backed
(`event(created_at)`), and queue backpressure throttles the pull to the workers' import rate.
Mirrors Julia's `EventSyncer`. Disable with `IMPORTER_EVENT_SYNC=false`.

## Pushgateway

On a timer (`IMPORTER_PUSHGATEWAY_INTERVAL`, default 15 s) `main` POSTs the counter `cache_any` to a
Prometheus pushgateway under `job=primalnode<report-node>`
(`http://IMPORTER_PUSHGATEWAY_HOST:IMPORTER_PUSHGATEWAY_PORT/metrics/job/<job>`, default
`127.0.0.1:9091`), matching the Grafana panel
`rate(cache_any{exported_job="primalnode18"}[$__rate_interval])`.

`cache_any` is the always-increasing total of imported events. To stay monotonic across the Julia →
OCaml cutover and across restarts, it is **persisted in the same `stats.json` Julia uses**
(`src/cache_storage.jl` `load_stats`/`save_stats`; `est.commons.stats[:any]`, surfaced as
`cache_any` by `App.network_stats`). On startup `main` reads the `"any"` baseline from
`IMPORTER_STATS_FILE`; each cycle it publishes `baseline + (events imported this session)` and
writes that total back to the file (atomic tmp + rename, other keys preserved verbatim). Reloading
our own last write as the next baseline means restarts neither reset nor double-count. Because it is
a monotonic counter, Prometheus derives the import rate via `rate()`.

The **reporting node** (`PRIMALSERVER_REPORT_NODE_IDX`, default 18) is intentionally separate from
the **firehose node** (`NODE_IDX`, default 17): on this box only the node-17 firehose (port 9017)
exists, but the importer replaces the production node-18 Julia importer, so its metrics/stats are
published as node 18.

Pushes and file writes are best-effort — a failure (gateway down/timeout, unwritable file) is
logged and skipped, never fatal (Julia uses `retry=false` under `errormonitor`). Mirrors Julia's
`PushGatewayExporter.set!` (`src/pushgateway_exporter.jl`). Disable with `IMPORTER_PUSHGATEWAY=false`.

## Notifications

Imports produce in-DB notifications, mirroring Julia `notification` / `notifications_cb` /
`import_reply_notifications` (`src/cache_storage_ext.jl`, `src/notifications.jl`):

- Rows land in `pubkey_notifications_1_e5459ab9dd` (per-type counters in
  `pubkey_notification_cnts_1_d78f6fcade`, bumped only for trusted users).
- Types wired: follow (`NEW_USER_FOLLOWED_YOU`), reactions (`YOUR_POST_WAS_LIKED`), reposts,
  zaps, replies + reply-to-reply + mentions (via `import_reply_notifications`, including thread
  chains from `thread_view_parent_posts`), post-mentioned-in-post, highlights, bookmarks, and
  DMs. Deferred types fire through the `Notifications_cb` event hook once the referenced post is
  present.
- Gating reproduces the full Julia `notification()` filter set. Always-on: skip self-notifications
  and references to hidden events, drop `USER_UNFOLLOWED_YOU`. The **serving-layer gates** —
  recipient must be a Primal app user (`app_settings`), `notification_settings` per-type enable,
  mute-list (event/pubkey/hashtag/word), hellthread mention cap, and the
  `only_show_*_from_users_i_follow` / `include_deep_replies` settings (via `app_settings` +
  `pubkey_followers`) — read tables that live only in the membership DB. They are queried **raw**
  (`Postgres.query`, not `[%pgsql]`, since `app_settings` is absent from primal1) and the whole set
  is **gated on `app_settings` being present** in the membership connection, detected once at
  startup (`init_notification_gating`; the banner logs `gates ON/OFF`). The dev shell points
  `mem_dbh` at the real membership DB (`PGMEMBERSHIP*` in `flake.nix`), so the gates are **ON** by
  default and notifications track the Julia importer (the recipient gate alone collapses repost
  notifications from ~12× the Julia rate down to ~1×). Pointed at primal1 instead (no
  `app_settings`), the gates go inert and the importer over-generates (notifications for every
  recipient, not just app users).
- **Side effect:** with `mem_dbh` on the real membership DB, the spam detector writes its
  `filterlist` blocks (comment-tagged `spam-detector: …`) and `import_reporting` writes there too —
  i.e. the importer contributes to the production membership filterlist, as the Julia importer does.
- **Push notifications** (`lib/push_notifications.ml`) mirror the Julia stub and are **disabled**
  at runtime (`enabled = false`, matching `PUSH_NOTIFICATIONS_ENABLED`); there is no APNS/FCM/
  web-push backend to port. The token-registration helpers parse and verify input but do not
  persist.

---

## Notes

- `main`, `importcheck`, `scorecheck`, and `phase8check` **write** to the cache DB, which by
  default (`PGDATABASE`) is now the **live `primal1` DB**. Point `PG*` at the reference DB
  (`primal_importer_ref`) for test runs you don't want landing in the live DB, then reset it
  with `sql/refdb-truncate.sh` (see *Resetting the reference DB to schema-only* above).
- The unit tests (`dune test`) cover pure logic only (NIP-01 event id, BIP340 schnorr,
  bech32 lud06 / NIP-19, real-event vectors) and need no database beyond the compile-time
  schema check.
