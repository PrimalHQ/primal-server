# primal-importer

OCaml 5 / Eio daemon that imports Nostr events from the fetcher's firehose into the Primal cache
DB. It verifies each event, stores it, and maintains the derived tables: stats, followers,
notifications, scores and replaceable events. All SQL is inline `[%pgsql]`, type-checked against a
cache DB schema at compile time. Shared modules are in `../common` (`primal_common`). This
library (`primal_importer`) is also linked by `jobs`. The earlier Julia implementation is in
git tag `julia-final`.

## Running

```sh
primal_importerd.exe <config.json>                  # run
primal_importerd.exe --check-config <config.json>   # parse the config, print "config ok", exit 0
```

Every setting comes from the JSON file; the environment is not read. A config error exits 2.

- **Supervision:** run it with automatic restart (systemd `Restart=always`). Two watchdogs exit 1
  after dumping every fiber's phase:
  - workers are busy but no job has completed for 180 s;
  - all four zap verifiers have been stuck for 600 s (e.g. a DNS lookup that never returns).
- **Shutdown:** there is no signal handler; SIGTERM ends the process at once. The worker queue,
  pending zap retries and unsent pushes are lost. On start, the event syncer re-pulls from peers
  starting `event_sync_overlap` seconds before the local maximum `imported_at`; re-imports count
  as duplicates.
- **Logs:** stdout/stderr. One status line per second:
  `recv/imp/dup/rej/err` per second, queue depth and max queue wait, busy workers, LNURL ok/fail/timeout,
  zap verified/retry/unverified/dropped (cumulative), pushes sent, total imported, RSS/heap,
  firehose reconnects. A `STUCK` suffix names fibers that have been in one non-idle phase over 30 s
  (`w0..`, `zv0..`, `firehose`, `event-syncer`, `backfill`, `sched-hooks`).
- **No admin port.** Metrics go to a Prometheus pushgateway.
- **DB connections:** each fiber or domain that queries has its own cache-DB and membership-DB
  connections. Each connection has `statement_timeout = 30s` and
  `application_name = 'primal-ocaml-importer'`. On a lost connection a fiber retries every 2 s. The
  job that hit the error is not retried; the event syncer brings it back if a peer imported it.

Fibers and domains:

| | Does |
|---|---|
| firehose reader | Connects to `firehose_host:firehose_port` and sends `STREAM-NEW-EVENTS\n`. It reads lines `[ts, {"relay": ..}, ["EVENT", subid, event]]` onto the worker queue and reconnects 1 s after EOF or an empty line. |
| `num_workers` domains | Take jobs from a queue of `queue_capacity`. A full queue blocks the producer; nothing is dropped. Each runs the spam detector on firehose lines, then `import_event`. |
| 4 zap-verifier domains | LNURL verification of zap receipts, off the import path. |
| event syncer / backfill | Feed peer events into the same queue. |
| hooks loop, every 60 s | Due `scheduled_hooks`, then `expire_scores`. |
| import listener | Synchronous imports for the API. |
| push sender / push intake | Device push notifications. |
| pushgateway, reporter | Metrics; the status line and stall watchdog. |

## Import pipeline

`import_event`:

1. **Gates.** A failure counts as `rejected`:
   - with `verification_enabled`: `created_at` < now + 300 and a valid BIP340 signature;
   - not in `deleted_events`;
   - an accepted kind;
   - the author not import-blocked in the filterlist.

   Unparsable firehose lines and lines over 2,000,000 bytes are rejected too.
2. **Claim.** `insert into event ... on conflict (id) do nothing returning id`. If no row comes
   back the event is a `duplicate` and nothing else runs, so side effects happen once across
   workers.
3. **Common writes:**
   - `event_created_at`;
   - for a new pubkey: `pubkey_ids`, `pubkey_followers_cnt` and `pubkey_zapped` (zero rows), and
     `pubkey_trustrank` = 1.0 if `disable_trustrank`;
   - `pubkey_events` (with `is_reply`) for kinds 1, 6, 20, 1068, 6969, 34235 and 34236;
   - an `event_stats` row for the note kinds 1, 20, 1068, 1111, 6969, 30023, 34235 and 34236.
4. **Per-kind dispatch** (below).
5. **Replaceable events:** kinds 10000–19999 go to `replaceable_events`; 30000–39999 with a `d` tag
   go to `parametrized_replaceable_events`.
6. **Deferred hooks:** this event's `event_hooks` rows run, then are deleted.

Steps 4–6 log exceptions (`import_event: <step>: ...`). The event stays imported and isn't retried.

**Accepted kinds:** 0–7, 20, 1018, 1068, 1111, 1311, 1984, 6969, 9735, 9802, 10000–19999, and
30000–39999 except 30382/30383. Kinds without a branch below are only stored.

The SQL writes the version-hashed base tables (e.g. `event_stats_1_1b380f4869` behind the view
`event_stats`); the names here are the logical ones.

| Kind | Handling |
|---|---|
| 0 metadata | If newer: `meta_data`, `user_search` (human authors; `to_tsvector('simple', ..)` per name field), `pubkey_ln_address` from `lud16`. |
| 3 contacts | If newer: `contact_lists` and the change in `pubkey_followers`. For a trusted author, also `pubkey_followers_cnt` and NEW_USER_FOLLOWED_YOU. Always: the author's relays (kind-10002 `r` tags, else the contact list's relay map) are upserted into `fetcher_relays`. |
| 1, 20, 1068, 6969, 1111 | Spam content-hash check. Mentioned events get a YOUR_POST_WAS_MENTIONED_IN_POST hook and, if the note isn't hidden, `reposts` +1 and a repost score. Media queueing. Hashtags (kind 1, human authors): `event_hashtags`, `hashtags.score` +1, and a scheduled −1 after 4 h. For a reply: the parent is the last `reply`-marked `e`/`a` tag, else the first `root`, else the last unmarked one. It writes `event_replies`, `event_pubkey_actions.replied`, `event_thread_parents`, the parent's `replies` (trusted author, not hidden) and a reply score. Then the reply notifications. |
| 4 DM | Unless the sender is hidden: `pubkey_directmsgs`, and upserts of `pubkey_directmsgs_cnt` for `(receiver, NULL)` and `(receiver, sender)` (needs the unique index `(receiver, sender) NULLS NOT DISTINCT`). NEW_DIRECT_MESSAGE. |
| 5 deletion | `e` tags of the author's own events: `deleted_events` and a delete from `event`. For a repost, `reposted`, its action ref and `reposts` are reverted. `a` tags: the addressed event and its `parametrized_replaceable_events` row, and for 30023 its `reads`/`reads_versions` rows. |
| 6 repost | First `e` tag: `reposts` +1 (not hidden), `event_pubkey_actions.reposted`, repost score, YOUR_POST_WAS_REPOSTED. |
| 7 reaction | Each `e` tag. Content empty or starting with `+`, 🤙 or ❤ counts as a like: `likes` +1 (not hidden), `event_pubkey_actions.liked`, like score, and the target's media re-queued. YOUR_POST_WAS_LIKED for any reaction. |
| 9735 zap | `zap_receipt_invoices` (needs receiver, sender and a bolt11). The amount comes from the `lnbc` bolt11; it must be positive and ≤ 1,100,000 sats, with `description` and `p` tags. After verification: `zaps` +1, `event_pubkey_actions.zapped`, zap score. If the sender (the description's pubkey) is human, also `satszapped`, `og_zap_receipts`, YOUR_POST_WAS_ZAPPED and `pubkey_zapped`. |
| 9802 highlight | YOUR_POST_WAS_HIGHLIGHTED on each `e`/`a` target. |
| 1984 report | With `import_reporting`, from a `reporting_whitelist` pubkey: `spam`/`impersonation` `p` and `e` tags (and the reported event's author) are blocked in the membership filterlist. |
| 10000 mute list | `mute_list`; content-moderation rules. |
| 10002 relays | `relay_list_metadata` if newer; `fetcher_relays`. |
| 10003 bookmarks | If newer: `bookmarks`, `pubkey_bookmarks`; YOUR_POST_WAS_BOOKMARKED for new `e` tags. |
| 10555 | `live_event_pubkey_filterlist` replaced. |
| 30000 lists | `d` = `mute` → `mute_list_2`, `mutelists` → `mute_lists`, `allowlist` → `allow_list` (each followed by content-moderation rules); any other `d` → `parameterized_replaceable_list`. |
| 30023 long-form | Media queueing (content URLs, `image` tags). |
| 30311 live event | Status `live`: the hosts (`p` tags with role `host`, participant proof valid or absent) replace `live_event_participants`; `ended`: removed. Then `pg_notify('cache_storage', {"type":"live_event",..})`. |
| 34235/34236 video | Media queueing (content, `imeta` urls, `url`/`thumb`/`image` tags). |
| 39089 follow pack | `follow_lists` for the `d` identifier, replaced. |

- **Mentions** come from kinds 1, 6 and 30023: `#[n]` references, `e`/`a` tags marked `mention`
  (an `a` resolves to the current event), and NIP-19 references in the content.
- **Hidden** means spam-blocked in the cache DB's `filterlist`. Blocks are written to the
  membership DB's filterlist.
- **Human:** the membership `human_override` row if there is one, else `pubkey_trustrank.rank` above
  the threshold. The threshold is `humaness_threshold`, or computed at startup as the rank of the
  50,000th-ranked pubkey (0.0 if the table is empty) and logged.
- **Trusted:** rank > 0. It gates follower counts, `replies` and notification counters.

`pubkey_trustrank` comes from the jobs daemon's TrustRank; on a DB without it, set
`disable_trustrank`.

**Deferred hooks and scores.** Stat bumps, scores and notifications for an event not stored yet
wait in `event_hooks` (`event_stats_cb`, `score_event_cb`, `notifications_cb`) until it arrives.

`score_event_cb`: base like 1, repost 7, zap 5, reply 1/5/10 by the scored event's content length
(≤ 20, ≤ 100, longer); increment `1e10 * base / 91` for a human initiator, else 0, and 0 if the
initiator already has more than one action of that kind on the event. A positive increment adds to
`score`; an engagement under 24 h old also adds to `score24h` with a `score_expiry` row due 24 h
after it.

The hooks loop runs two jobs; exactly one importer per cache DB may enable each.
`expire_scores_enabled` subtracts the due `score_expiry` sums from `score24h` and deletes those
rows. `scheduled_hooks_enabled` claims due `scheduled_hooks` with `DELETE .. RETURNING` (20,000 per
batch, up to 50 batches per round) and sums the hashtag decrements (`expire_hashtag_score_cb`, the
only kind) per hashtag.

**Spam detection** (firehose lines only; the event is imported either way) clusters signed kind-1
notes of 3+ words by authors with under 50 followers: over 90% shared words and a word count within
10%. Every 1200 s the authors of clusters with ≥ 10 notes are blocked as spam in the membership
filterlist. A note that matches such a cluster is blocked at once, its author too (flushed at most
every 10 s), and its content SHA-256 goes into `spam_note_content_hash`. A later kind-1 note with a
stored hash gets its author blocked, unless the author is unblocked or has 50+ followers.

**Media queueing** happens only with `download_media` / `download_previews`, on the host where the
jobs daemon's media role runs. It covers content URLs of authors with rank > 0 or a human
override, and inserts a pending `processing_nodes` row (an existing node is reset to pending):

| URL | Nodes |
|---|---|
| image: `.png .gif .jpg .jpeg .webp` | `import_media_pn` (all variants), `import_media_fast_pn` |
| video: `.mp4 .mov .3gp` | `import_media_pn` (original), `import_media_fast_pn` |
| other (`download_previews`) | `import_preview_pn` |

## Zap verification

Receipts by `trusted_zappers`, and all receipts when `verify_zappers` is false, are applied
immediately. The rest go to a queue of 2,048 (new jobs are dropped at 2,000) for the four verifier
domains:

- **Check:** the URL comes from the zapped user's kind-0 (`lud16` `name@domain` →
  `https://domain/.well-known/lnurlp/name`, else `lud06`). It is fetched through `proxy` (SOCKS5,
  the proxy resolves the host), 10 s limit, fetches over 5 s logged. Verified if the response's
  `nostrPubkey` is the receipt's author.
- **Cache:** answers 1 h, failures and answers without a pubkey 10 min; a host is skipped for 5 min
  after 3 consecutive failures.
- **Outcomes:** deferred (no kind-0 yet, fetch failed, host skipped) is retried after 90 s, 7 min,
  30 min and 90 min (at most 20,000 pending); a wrong or missing pubkey is final; a verified zap
  whose DB writes fail is dropped, never retried, so nothing counts twice. Give-ups count in
  `importer_zap_dropped_total`.

## Notifications

Notifications are stored in `pubkey_notifications`. `pubkey_notification_cnts.type<N>` is bumped
when the recipient and every pubkey argument are trusted; a type without a column is logged.

Types: NEW_USER_FOLLOWED_YOU, YOUR_POST_WAS_ZAPPED / LIKED / REPOSTED / REPLIED_TO /
MENTIONED_IN_POST / HIGHLIGHTED / BOOKMARKED, YOU_WERE_MENTIONED_IN_POST, REPLY_TO_REPLY and
NEW_DIRECT_MESSAGE.

**Always dropped:** USER_UNFOLLOWED_YOU, self-notifications, a hidden event argument, a non-human
initiator. **Recipient gates**, on when the membership DB has `app_settings` (checked at startup,
logged as gates ON/OFF), drop it when:

- the recipient isn't an app user;
- a mention's event mentions over 10 pubkeys (`ignore_events_with_too_many_mentions`, default on);
- the recipient's kind-10000 mute list matches (`e`, `p`, `t`, `word`);
- `notificationsAdditional` says so: `only_show_reactions_from_users_i_follow` (default off),
  `only_show_dm_notifications_from_users_i_follow` (default on), `include_deep_replies` (default
  on, for REPLY_TO_REPLY);
- `notification_settings.enabled = false` for the type.

**Replies** (notes and comments):

- the parent's author gets YOUR_POST_WAS_REPLIED_TO;
- each `p` mention gets YOU_WERE_MENTIONED_IN_POST;
- REPLY_TO_REPLY goes to the ancestors' authors (thread chain from `thread_view_parent_posts`, 3–15
  events) and to the pubkeys the ancestors mention (2–15 events), skipping pubkeys this event has
  already notified.

**Device push** (`push_notifications_enabled`): each notification that passes the gates is logged
to `t_push_notifications_log` and, unless over 30 min old, rendered according to the recipient's
`pushNotifications` settings (NEW_FOLLOWS, ZAPS, REACTIONS, REPOSTS, REPLIES, MENTIONS,
DIRECT_MESSAGES; default on). A push whose initiator is filterlist-blocked or has no kind-0 name is
dropped. One payload is queued per membership `notification_tokens` row.

A fiber runs `push_notification_sender_bin` (JSON lines on stdin/stdout). Every
`push_notifications_period` seconds it sends the queue in chunks of 50 per platform
(`{"type":"push_notifications","platform":..,"notifications":[..]}`), waits up to 10 s per response
and logs it as `notification_result`; after 60 s idle it sends `{"type":"ping"}`. Any failure
respawns the sender after 1 s and loses the batch in flight. `push_notifications_log` echoes the
traffic to stdout.

**Push intake** (with push on and `push_intake_ports` non-empty) listens on each port at
`push_intake_host` for one JSON object per line, with no reply. Each line is logged to
`t_push_notifications_log`; lines over 30 min old are dropped. Only `wallet-transaction` is
handled (`pubkey`, `created_at`, `amount_sats`, `tx_network`, `tx_state`, `tx_type`, `note`, optional
counterparty `pubkey_2`), as "N sats received", "Payment received" or "Transaction confirmed". It
is sent if:

- the receiver's `WALLET_TRANSACTIONS` push setting is on;
- the amount is above `show_wallet_push_notifications_above_sats` (the user's, else
  `default_settings_file`'s, else 1);
- the follows-only option allows the counterparty.

**Content moderation rules** (`content_moderation_rules_enabled`): when an app user changes a kind
10000 list or a kind 30000 `mute`/`mutelists`/`allowlist` list:

- their `cmr_*` tables are recomputed (`Cmr` in common) from their settings, merged over
  `default_settings_file` (re-read when its mtime changes);
- each live event they host gets a kind 11000001 `a`-tag event on `pg_notify('primal_events', ..)`.

## Import listener

With `import_listener_enabled`: newline-delimited JSON over TCP, one reply per line.

```
["EVENT", "<subid>", {event}]  -> ["OK", "<id hex>", "imported" | "duplicate" | "rejected" | "error"]
["IMPORT", [{event}, ...]]     -> ["OK", {"imported": n, "duplicates": n, "rejected": n, "errors": n}]
anything else                  -> ["NOTICE", "unsupported message" | "invalid event" | "invalid json"]
```

Requests are served one at a time. For each event:

1. `human_override` upsert (source `import_events`) in the membership DB;
2. `import_event`;
3. the per-event DAG indexers (`lib/dag_index.ml`):
   - `basic_tags`, plus `reads_interactions` for kind 1/6/7 `e` tags on stored article versions;
   - `zap_receipts`;
   - `poll_stats`/`poll_user_votes` (with `poll_vote_import_enabled`);
   - `event_mentions`;
4. for kind 1, the `root`/`reply` targets are sent in the background to the author's relays,
   through `proxy`, with `relay_broadcast_timeout` per relay.

## Event syncer

With `event_sync_enabled`, the syncer pulls each peer in `event_sync_remotes` (its connection is
`cache_db` with that host) by `imported_at`:

- It starts at min(now, local max `imported_at`) − `event_sync_overlap`, then follows each peer's
  highest `imported_at` seen; up to 200,000 rows per pull.
- A cycle's events are queued in `created_at` order (parents first). The next cycle comes after
  1 s if a pull was full, else after `event_sync_interval`. A failing peer is reconnected next
  cycle.
- Synced events skip signature verification and the spam detector.

`event_sync_backfill` (normally `null`) replays one peer's rows with `imported_at` in
`[from_ts, to_ts)`, in pages of `batch` keyed on `(imported_at, id)`. Each page waits for the queue
to be under half full, and the cursor is saved to `state_file` after each, so a restart resumes;
errors retry after 30 s. After `backfill: done`, set the key back to `null`.

## Metrics

Every `pushgateway_interval` seconds the importer POSTs to `/metrics/job/<pushgateway_job>`:

| Metric | |
|---|---|
| `cache_any` (counter) | Events imported, ever: the `"any"` value of `pushgateway_stats_file` at start plus this run's imports, written back each cycle (atomically, other keys kept), so restarts don't reset it. |
| `importer_queue_depth`, `importer_busy_workers` | Gauges. |
| `importer_errors_total` | Exceptions while processing jobs. |
| `importer_lnurl_{ok,fail,timeout}_total` | LNURL fetches. |
| `importer_zap_{verified,retry,unverified,dropped}_total` | `dropped`: zaps that stay uncounted. |
| `push_notification_latest`, `push_notification_sent` | After the first push; `sent` counts since the previous POST. |
| `notification_latest` | Time of the last stored notification (after the first). |

Push and file errors are logged and skipped.

## Configuration

One JSON object. **Every key is required**; *nullable* keys take `null`. Unknown keys are
ignored. Pubkeys are 64-char hex; entries that don't decode are dropped. In parentheses: the
values of `Config.from_env` (a dev-tool helper), which are not fallbacks.

| Key | Type | Meaning |
|---|---|---|
| `firehose_host`, `firehose_port` | string, int | The fetcher's firehose. |
| `num_workers`, `queue_capacity` | int | Worker domains (4); worker queue size (10000). |
| `verification_enabled` | bool | Check `created_at` and signatures (firehose and listener). |
| `cache_db`, `membership_db` | object | `{host, port, user, database}`; no password key. |
| `proxy` | string, nullable | SOCKS5 for LNURL and relay broadcasts: `socks5h://h:p`, `socks5://h:p` or `h:p`. Ignored without a valid port. |
| `verify_zappers` | bool | LNURL-verify zap receipts. |
| `trusted_zappers` | pubkey[] | Receipt authors that skip verification. |
| `disable_trustrank` | bool | New pubkeys get rank 1.0 (everyone human). |
| `humaness_threshold` | number, nullable | Fixed threshold; `null` = computed at startup. |
| `import_reporting`, `reporting_whitelist` | bool, pubkey[] | Act on kind-1984 reports from these pubkeys. |
| `download_media`, `download_previews` | bool | Queue media / preview processing nodes. |
| `event_sync_enabled`, `event_sync_remotes` | bool, string[] | Event syncer; peer cache-DB hosts. |
| `event_sync_interval`, `event_sync_overlap` | number, int | Seconds between cycles (60); initial lookback (600). |
| `event_sync_backfill` | object, nullable | `{remote, from_ts, to_ts, batch, state_file}`. |
| `scheduled_hooks_enabled`, `expire_scores_enabled` | bool | One importer per cache DB. |
| `content_moderation_rules_enabled` | bool | Recompute `cmr_*` on list changes. |
| `default_settings_file` | string, nullable | The app's `default-settings.json`. |
| `import_listener_enabled`, `import_listener_host`, `import_listener_port` | bool, string, int | Host `0.0.0.0`, `127.0.0.1`/`localhost` or an IP. |
| `relay_broadcast_timeout` | number | Seconds per relay (15). |
| `poll_vote_import_enabled` | bool | Poll indexers in the listener. |
| `push_notifications_enabled` | bool | Device push. |
| `push_notification_sender_bin` | string | The push-notification-sender binary. |
| `push_notifications_period`, `push_notifications_log` | number, bool | Seconds between batches (5); echo the sender traffic. |
| `push_intake_host`, `push_intake_ports` | string, int[] | Intake listeners; `[]` = off. |
| `pushgateway_enabled`, `pushgateway_host`, `pushgateway_port` | bool, string, int | |
| `pushgateway_job` | string | `job` label (`exported_job` in Prometheus). |
| `pushgateway_stats_file` | string | JSON file holding the `cache_any` total. |
| `pushgateway_interval` | number | Seconds (15). |

## Layout

- `bin/primal_importerd.ml`: the daemon (config, fibers, reconnects).
- `tools/`: dev tools (below).
- `lib/cache_storage.ml`: `import_event`, per-kind dispatch, event and scheduled hooks,
  `expire_scores`. `lib/cache_storage_ext.ml`: what dispatch calls (humanness, mentions, hashtags,
  media, zaps, scores, notifications and gates, reports, live events, lists, moderation rules).
- `lib/config.ml`, `firehose_client.ml`, `dag_index.ml`, `import_listener.ml`, `event_syncer.ml`,
  `spam_detection.ml`, `zap_verifier.ml`, `lnurl.ml`, `push_notifications.ml`, `push_intake.ml`,
  `pushgateway_run.ml`: the parts named above. `lib/stats.ml`: counters, status line, watchdog.
- `test/events.jsonl`: sample events (`importcheck`'s default input).

## Build and test

One dune workspace for the repo (`_build/` at its root), built from `common`'s flake:

```sh
cd "$(git rev-parse --show-toplevel)"
nix develop path:$PWD/nix -c dune build @all       # fails on any [%pgsql] mismatch
nix develop path:$PWD/nix -c dune build importer/bin/primal_importerd.exe
nix develop path:$PWD/nix -c dune test             # workspace tests; none in importer
```

- **`[%pgsql]` checks** need a DB with the cache schema at `PGHOST`/`PGPORT`/`PGUSER`/`PGDATABASE`.
  Build one from `schema/cache.sql` and `sql/migrate.sh` (see
  `schema/README.md`). A query that needs a new table, column or unique index needs
  its migration applied there first.
- **Membership tables** (`app_settings`, `notification_settings`, `notification_tokens`) are read
  with raw `Postgres.query`, so they are unchecked.
- **Tests:** `importer` has no unit tests; `dune test` covers common's shared modules.

**Dev tools.** They connect with `PG*` and use that DB for the membership tables too, except
`zapbackfill`, which takes the cache-DB host as an argument and the membership DB from
`PGMEMBERSHIP*`. `importcheck`, `scorecheck` and `zapbackfill` (without `-n`) write.

| Tool | |
|---|---|
| `importcheck [file.jsonl]` | Imports one event per line (default `test/events.jsonl`); prints counts. |
| `scorecheck` | Synthetic note and like from a trusted pubkey; checks `score`, `score24h`, `score_expiry`; cleans up. |
| `zapcheck [N]` | LNURL-verifies the last N zap receipts in the DB; proxy from `PRIMALSERVER_PROXY`. |
| `zapbackfill <host> <from> <to> [-n] [-e]` | Re-applies zap effects for receipts imported in a window. It skips receipts already in `og_zap_receipts`. `-n`: dry run; `-e`: only receipts that dedup can decide. Read the header first: replays can double-count. |
| `lnurlprobe [rounds] [url ...]` | Times the DNS, connect, TLS, write and read phases of an LNURL fetch. |

A scratch cache DB for these tools is made from `schema/cache.sql` (`selfhost/primal.sh init`
creates one).
