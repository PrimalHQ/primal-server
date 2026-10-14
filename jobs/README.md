# jobs: primal-jobs (`primal_jobsd`)

The background jobs daemon. One process runs the roles its config lists; each role is a fiber
running its own loop against the cache DB and the membership DB. The same binary also runs the
media pipeline (the processing-graph executor that imports media, link previews and uploads) and
the Blossom server. OCaml 5 / Eio, configured by one JSON file.

The earlier Julia and Rust implementations are in the git tag `julia-final`.

## Roles

| Role | Does | Writes |
|---|---|---|
| `dag` | Derived tables from newly imported events, in imported-at windows | the DAG output tables, `coverages_1_8656fc443b` |
| `trustrank` | Personalized PageRank over the follow graph | `pubkey_trustrank` (and the view `trusted_users_trusted_followers`) |
| `analytics` | Explore feeds and topics, precalculated | `cache` rows `precalculated_analytics_*` |
| `dvm_checker` | Probes every content-discovery DVM | `dvm_feeds` |
| `dvm_provider` | Primal's own content-discovery DVMs | relay events; membership `dvm_usage` |
| `pg_listener` | Live-event notifications for followers | notifications, `live_event_notification_created` |
| `rebroadcast` | Sends users' events to the relays they asked for | relay events; membership `event_rebroadcasting` |
| `failover` | Promotes the membership DB server named by the discovery document when it is in recovery | (`pg_promote()`) |
| `media` | Executes processing-graph nodes: media, previews, uploads, moderation | media tables, media storage |
| `blossom` | The Blossom HTTP server | blobs, `media_storage`, `media_uploads`, `import_upload_3` nodes |

A role runs only when it is in `roles`. A role name the binary does not know must have been
registered by a private extension build (see [Extensions](#extensions)); otherwise the daemon
refuses to start.

Roles that write shared tables are singletons: run each at most once per database (two `dag` runners
would add the counts twice, two `dvm_provider`s would answer every request twice).

### `dag`

Every `dag_period_s` the runner pushes the window `[since, until]` of `event.imported_at` through
the nodes, in this order:

| Node | Segment step | Lookback | Writes |
|---|---|---|---|
| `basic_tags` | 1 day | | `basic_tags_6_62c3d17c2f`: `p`/`P`/`e` tags with a 64-hex argument (events with under 50 tags); `reads_interactions` for kind 1/6/7 `e` tags pointing at a stored article version |
| `zap_receipts` | 1 day | | kind 9735 through the importer's zap-receipt indexer (`zap_receipts_1_9fe40119b2`) |
| `poll_stats` | 1 day | | poll statistics of polls referenced by kind 1018/9735 events (only with `dag_poll_votes_enabled`) |
| `a_tags` | 90 days, sequential, 8 parallel Postgres workers | | `a_tags_1_7d98c5333f` |
| `reads` | 90 days, 5 phases | | `reads_12_68c6bbfccd`, `reads_versions_12_b537d4df66`: articles (kind 30023 with `d` and `published_at`; language from `Langid`), then their zaps, likes, direct replies and reposts |
| `pubkey_media_cnt` | 90 days | | `pubkey_media_cnt_1_b5e2a488b1` (added to) |
| `pubkey_content_zap_cnt` | 90 days | | `pubkey_content_zap_cnt_1_236df2f369` (added to) |
| `advsearch` | 1 day | 30 days | `advsearch_5_d7da6f551e`: search vectors of content, hashtags, reply target, mentions, media/link filters and URLs (kinds 1, 20, 1068, 1111, 6969, 30023, 34235, 34236; content up to 200 kB) |
| `event_mentions` | 1 day | | kinds 1/6/30023 through the importer's mention indexer |
| `note_length` | 1 day | 15 days | `note_length_1_15d66ffae6` |
| `note_stats` | 1 day | 30 days | `note_stats_1_07d205f278.long_replies`: replies of 600+ characters by authors at or above the humaness threshold |
| `update_user_search` | 1 day | 3 days | user search entries of pubkeys added to `human_override` |

The output tables are asserted at start; a missing one stops the daemon.

**Segments and coverage.** Each node splits its window into segments aligned to its step and skips
what `coverages_1_8656fc443b` already records as covered (coverage names are `postgres-p0-<table>`,
with `/<phase>` for multi-phase nodes). Each segment runs in its own transaction on the DAG's own
connections (statement timeout `dag_statement_timeout_s`, `max_parallel_workers_per_gather` 0 except
`a_tags`), up to `dag_tasks` segments at once in random order, and its coverage is recorded after
the commit. A failing segment ends the run: the remaining nodes are skipped and the next run retries
the same window.

**The window.** At start `since` is the later of `dag_since` and the coverage frontier (the end of
the contiguous coverage of every full-history node, the smallest of them), never before
2023-01-01. The window's length follows the previous run's cost (aiming at 30 s per run, at most
doubling, halved after a failure, 10 s to 1 h) and is then halved until it holds at most 200,000
events, because the nodes load a window's events into memory. `since` advances only after a run in
which every node succeeded. Runs that finish in under a second repeat at once (up to 500 per tick),
so a restart skips covered history quickly. Each run that takes a second or more, fails, or reaches
the present logs its window, the next span and the lag behind now.

**Dry runs.** `dag_dry_run` rolls every segment back and records no coverage. With
`dag_dry_run_window_s` > 0 as well, the role runs every node once over the last that many seconds
(coverage ignored, everything rolled back), logs the result and idles.

**Metrics.** With `pushgateway` set, after each tick: gauges `dag_runner_duration` (seconds) and
`dag_runner_all_ok` (1/0).

### `trustrank`

Every `trustrank_period_s` (the first run after one period, or at once with
`trustrank_run_at_start`):

1. Seeds: membership `verified_users` with `default_name`. Blocked: pubkeys in the membership
   `filterlist` groups `spam` and `csam`.
2. The follow graph is read in one cursor pass over `pubkey_followers` (batches of 200,000; at
   most 80 M edges are kept, self-follows ignored).
3. Personalized PageRank from the seeds: `trustrank_alpha`, `trustrank_iterations`; blocked
   pubkeys get no seed weight and are left out of the result; only ranks > 0 are written.
4. The ranks go, 10,000 rows per insert, into an **unlogged** table. When `trustrank_target_table`
   is `pubkey_trustrank`, it is built as `pubkey_trustrank_new` and swapped in under the live name in
   one transaction, with the view `trusted_users_trusted_followers` recreated; any other name is
   written as a standalone table (for comparisons).
5. The same import runs on each DB in `trustrank_extra_targets` (DBs that read the ranks but hold no
   follow graph); one failing does not stop the others.

Its connections have no statement timeout. The stop is checked during the graph load and between
iterations.

### `analytics`

Every `analytics_period_s`, sixteen explore selectors are computed in-process with the cache API's
own `scored_content` (library `primal_api`, configured by the API config file at
`api_config_path`, on this daemon's `cache_db`/`membership_db`), up to 8 at a time:

| Selector | Timeframe | Notes |
|---|---|---|
| `trending_24h`, `_12h`, `_4h`, `_1h` | trending | `gm_mode` `nogm`; gaming detection |
| `gm_trending_*` | trending | `gm_mode` `gmonly` |
| `classic_trending_*` | trending | no `gm_mode` |
| `mostzapped_*` | most zapped | gaming detection |

Each result keeps only kinds 0, 1, 10000107, 10000119, 10000158, 10000168 and 10000169, and is
stored in `cache` under `precalculated_analytics_<selector><analytics_key_suffix>`.

Gaming detection (when `ollama_host` is set): each kind-1 note of those selectors, with mentions and
URLs removed, goes to Ollama (`gemma3n:e4b`, 10 s timeout) asking whether the author explicitly
begs for zaps, reposts or replies; on "yes" the stored note's content gets the prefix `[G] `. The
report of positives is written as `<pre>...</pre>` to the stdin of `gaming_report_command`, when set.

Then `precalculated_analytics_explore_topics<suffix>`: the 200 most used hashtags of the last 24 h
among authors ranked above the humaness threshold (excluding `nsfw` and `sexpervertsyndicate`), on
its own connection without a statement timeout.

### `dvm_checker`

Every `dvm_check_period_s`, for each content-discovery DVM (a kind-31990 handler with a `k` tag of
5300 seen in the last 90 days): a NIP-90 job request signed with `dvm_requester_seckey` is sent to
`dvm_relays` plus the relay the handler was seen on, through `relay_proxy`, waiting up to
`dvm_timeout_s`; personalized DVMs get `dvm_requester_pubkey` as the user. Up to `dvm_parallel`
checks run at once; with `dvm_randomized_delays` each waits a random 0-80 % of the period first.
`dvm_feeds` is upserted per (pubkey, identifier): the ids of the first 20 notes/articles of the
answer that exist in the cache (newest first), `kind` `notes` or `reads` by majority, `ok` when any
was found; a failed request stores `results` null and `ok` false. The request code
(`Dvm_client`) is shared with the API's `dvm_feed`.

### `dvm_provider`

Primal's own content-discovery DVMs, one per feed of `Dvm_provider.feeds` (25 feeds in the code:
21 active, 4 deleted). Each feed has its own key, sha256(`dvm_provider_keypair_salt` ‖ feed id), so
its pubkey is stable for a given salt. With the salt `null` the role does not start.

- On every connection to a relay of `dvm_provider_relays` (through `relay_proxy`), each feed
  publishes its NIP-89 handler information (kind 31990, `d` = feed id) or, for a deleted feed, a
  kind-5 deletion of it, plus a NIP-65 relay list (kind 10002; private-LAN relay URLs left out).
  All carry `created_at = dvm_provider_announce_created_at`, so they are identical on every
  connection and host: bump it when a feed or the relay list changes.
- One subscription takes the kind-5300 requests addressed (`#p`) to an active feed. It is re-sent
  every minute; a relay silent for 3 minutes is reconnected, and any failure reconnects after 10 s.
- A request with a valid signature is answered once even when several relays deliver it (ids kept
  for an hour). It is recorded in membership `dvm_usage`, then answered with a kind-6300 result
  (tags `e`, `p`, `request`, `status success`; content the `["e", id]` list) holding the kind
  1/30023 ids of the API's `mega_feed_directive {spec, user_pubkey, limit 50}`, run in-process, in
  feed order. The user is the request's `param user` when given, else its author. The result goes
  to `dvm_provider_relays` plus the request's `relays` tag.
- `dvm_provider_dry_run` logs the announcements and answers and publishes or records nothing.
- Verified-only feeds are not supported: an active one stops the daemon at start.

Like `analytics`, it uses the API config at `api_config_path` and the API's DB pools.

### `pg_listener`

`LISTEN cache_storage` on the cache DB (a dedicated connection that reconnects by itself; it
supports trust authentication only). A `{"type": "live_event", "kind", "pubkey", "identifier"}`
payload notifies every follower of the live event's host (its `p` tag marked `host`) with a
"live event happening" notification, through the importer's notification writer. Per follower:
at most once per event (a row in `live_event_notification_created`, so concurrent listeners do not
duplicate), not when the follower blocked the host (`live_event_pubkey_filterlist`), at most once per
host per `pg_listener_rate_limit_s` (in memory), and only when `live_feed_is_hidden` allows it.

### `rebroadcast`

Every second, each membership `event_rebroadcasting` row that is started and not finished (up to 8
at a time) gets its next batch: up to 100 of the user's events since `event_created_at` (the
requested `kinds`; replaceable and parameterized-replaceable kinds collapsed to the latest), sent to
`target_relays` through `relay_proxy`, one connection per relay, 10 events/s. A batch is done when
every event has an `OK` from some relay, or after 30 s. The row gets `event_idx_intermediate` as
events are first acknowledged, `last_batch_status` (a JSON summary), and, when the batch succeeded,
the new `event_created_at`, `event_idx` and `batchhash`. A batch identical to the previous one (same
sha256) finishes the row (`finished fine`); an error finishes it as `failed` with the exception text.

### `failover`

With `membership_discovery_url` set: takes a Postgres advisory lock on the membership DB (one active
watcher however many run), then every second fetches the discovery document
(`{"postgres": "host=... port=... dbname=... user=..."}`) and, when the server it names answers
`pg_is_in_recovery()` true, calls `pg_promote()` on it. It does not re-point any connection pool.

### `media`

The processing-graph executor. Its state is in `processing_nodes` (id, `mod`, `func`, `args`,
`kwargs`, `result`, `exception`, `started_at`, `finished_at`, `extra`) and `processing_edges`
(`ancestry` edges from a node to the nodes it ran), on the DB named by `cache_db`: on the media host
that is the media DB, where the media tables live.

**Scheduler.** Every `scheduler_period_s`, for each func in `execute_funcs` that has a handler, it
claims pending nodes (not started, not finished), oldest first, with
`for update skip locked`, up to that func's limit of running nodes: `julia_duty_concurrency` for
`import_upload_3`, `block_media` and `purge_media_`, `max_concurrent_per_name` for the rest. Funcs
without a handler are logged and never claimed. Claimed nodes run on `worker_domains` worker
domains, each with its own DB pools (`worker_pool_size` cache-DB connections, 3 membership). At
start, the claimed funcs' nodes that are started but unfinished and under 2 days old are reset to
pending (nodes interrupted by a stop are resumed this way). Every 60 s it logs, per func, pending
(last 48 h), running, completed and failed; every `refresh_matview_period_s` it refreshes the
materialized view `pn_time_for_pubkeys` concurrently.

**Execution.** A run sets `started_at`, then stores the result, or `{"error": msg}` with
`exception` true, and `finished_at`, and deletes the binary-cache files its arguments referenced.
A node can run other nodes inline or schedule them (stored pending); both get an ancestry edge
from it. Diagnostics go to the node's `extra` (fields at the root, and entries appended to
`extra.log`). A node id is the sha256 of the node's `{mod, func, args, kwargs}` JSON (typed values
encoded as `{"_ty", "_v"}`; byte vectors over 256 bytes as files in `binary_data_cache_dir`).
Scheduling an id that already exists resets the node to pending, so a node scheduled again while it
runs (a retried upload, one URL in several events) runs again.

**Funcs** (`execute_funcs` `null` = all of these except `purge_user_content`):

| Func | Does | Writes |
|---|---|---|
| `import_media_pn` | Variants of a media URL (`media_variants_pn` inline): original, small (200), medium (400), large (1000), each animated and not (a URL with a video extension gets only the original); then `import_media_variant_pn` per variant (download, mimetype, dimensions, rotation; for videos a thumbnail, itself imported) | storage files, `media_storage`, `media_1_16fa35f2dc`, `event_media`, `video_thumbnails`; schedules `ext_after_import_upload_2` unless `no_media_analysis` |
| `import_media_fast_pn`, `import_media_fast_pn_2` | First 5 MB of an image/video URL: mimetype and dimensions only | `media_1_16fa35f2dc` (original), `event_media` |
| `import_preview_pn` | Link preview of a URL (below); the preview image through `import_media_pn` | `preview_1_44299731c7`, `event_preview_1_310cef356e` |
| `import_media_hls_pn` | Submits a video to every enabled HLS provider in parallel, polls until done or `hls_processing_timeout_s` | `event_hls_media` per provider |
| `import_text_event_pn` | Kind 1/30023 text: `nomic-embed-text` embedding of the first 500 characters; `llama3.1` language, sentiment and categories (Ollama on `ai_host:11434`) | `event_embedding`, `text_metadata` |
| `import_upload_3` | Processes a Blossom upload (below) | storage, membership `memberships`, `video_urls`, `video_frames` |
| `block_media` | Schedules `purge_media_`, counts `csam_block_count` for the uploader; at 3 or more, and no csam block yet, schedules `purge_user_content` | `bytea_props` |
| `purge_media_` | Purges a URL (below) | membership `media_block`, `media_storage`/`media_uploads`/`short_urls` block ids |
| `inc_counter` | Adds to a counter | `bytea_props` |
| `purge_user_content` | POSTs `{"func": "purge_user_content", "message"}` to `user_content_purger_api` (fails when unset); claimed only when listed | |

Media of low-trust authors is not imported (result `low_trust_user`): authors neither verified nor
ranked above 1e-6 whose `pn_time_for_pubkeys` duration exceeds 1800 s. For `import_media_pn` and
`import_media_hls_pn`, an event whose author is not found counts as low-trust too.

`ext_after_import_upload_2` nodes have no handler in this build; they stay pending unless an
extension build handles them.

**Storage** (`Media_store`):

- v1, key-addressed (`media_import`): `h` = sha256 of the key JSON; tried on the entries of
  `media_paths.<cache|upload|uploadfast>` in order until one succeeds. Local entries are used only when
  the key names a pubkey that is verified or has a `pubkey_trustrank` row; otherwise only S3 entries
  are tried. Local layout
  `<path>/<h[0]>/<h[1..2]>/<h[3..4]>/<h><ext>` with a `<h>.key` file and a `<h>` symlink; URL
  `<media_url_root>/<last dir of path>/<same subdir>/<h><ext>`.
- v2, content-addressed (`media_import_2`): the same layout keyed by the blob's sha256, written to
  every entry of `media_paths_2.<...>`; returns `<blossom_host>/<file>`.
- S3 entries name an `s3_providers` entry; the object key is `<dir>/<subdir>/<h><ext>`, the URL
  `https://<domain or bucket.endpoint host>/<key>`.
- Every copy is a `media_storage` row (`media_url`, `storage_provider`, `key`, `h`, `ext`,
  `content_type`, `size`, `sha256`). Reads prefer providers by `media_storage_priority`.
- Resizing runs `nice ionice -c3 ffmpeg`, or `ssh <ffmpeg_remote_host> nice ffmpeg` streaming
  through stdin/stdout when that is set.

**Downloads.** Through the `proxies` in random order, 2 s between attempts. Hosts under
`primal.net` are tried directly first and get a 180 s timeout (also `primalnode.net`), others
`download_timeout_s`. A HEAD first refuses bodies over 2 GB; up to 5 redirects. A direct
(unproxied) connection is made only to a public IP address, resolved once and connected to, for
every hop.

**Link previews** (`import_preview_pn`): one GET (10 s, 15 MB) through `metadata_proxy` (direct when
`null` or `"null"`; an unparsable proxy means no preview), parsed by `common`'s `Link_preview`
(og/twitter title, description and image, the description meta, a lone icon link); a page
without a title falls back to the site's oEmbed. Shared with the API's `/link-preview`.

**HLS providers**: `aws` (MediaConvert, SigV4, endpoint discovery; outputs in an S3 bucket),
`mux`, `bunny` (Bunny Stream), `cloudflare` (Cloudflare Stream). Polling starts at 2 s and grows
by 1.5x up to 30 s.

**Uploads** (`import_upload_3`, scheduled by the Blossom role with the blob in the binary cache):

1. mimetype and dimensions;
2. v2 copies to `media_paths_2.upload`;
3. membership `memberships`: a row (`free`, or `premium` when verified) if missing, and
   `used_storage` increased by the size;
4. videos: `video_urls`, 5 frames stored and recorded in `video_frames`; the after-upload hook (an
   extension's analysis) for images and videos;
5. CSAM similarity: the sha256 (with its before/after pair from `media_metadata_stripping`) against
   `media_uploads_media_block_csam`, then the image/video embedding (`ai_host` ports 5013/5014)
   against blocked blobs' `media_embedding` (cosine distance ≤ 0.02). A match purges the blob with
   every upload of it, and calls the CDN purge hook;
6. unless blocked: the CDN variants through `import_media_pn` for blobs under 10 MB with extension
   `.jpg`, `.png`, `.gif`, `.mp4`, `.mov` or `.webp`;
7. if every upload of the blob was blocked or deleted meanwhile, what this import wrote is purged.

**Purges** (`purge_media_`, args pubkey and URL; kwargs `reason`, `extra`, `block_all_uploads`,
`clear_cache`): a membership `media_block` row records what was purged. Each file found is moved
into a `cdn-hidden` directory of its storage tree (local), or copied to the provider's `bucket2`
(when set) and deleted (S3, plus a Cloudflare cache purge for providers named `cloudflare` or
`cloudflare2` when `cloudflare_cache` is set); matching `media_storage` rows get the block id.

- Blossom URLs (host in `blossom_hosts`, path the blob's sha256): with a pubkey, that uploader's
  `media_uploads` rows of the blob are blocked, and when they are all its uploads, the upload copies
  (`upload_url_root` + path) and storage copies are purged, and `clear_cache` applies. Without a
  pubkey, every upload of the blob is blocked and its upload copies purged. `clear_cache` purges the
  CDN variants and video thumbnails; `block_all_uploads` blocks and purges every upload and storage
  copy of the blob.
- `m.primal.net` short URLs: the files behind the `short_urls` rows, which get the block id.
- Other URLs: the URL's files, its media variants and video thumbnails.

### `blossom`

A Blossom server (BUD-01, 02, 04, 05) on `0.0.0.0:<blossom.port>` (SO_REUSEPORT; CORS on; bodies up
to 10 GB). It needs the `media` object as well, and a `media` role on the same DB and binary cache
to process the `import_upload_3` and `purge_media_` nodes it schedules.

| Route | Does |
|---|---|
| `GET /` | welcome text |
| `HEAD /upload`, `HEAD /media` | upload preflight: `X-SHA-256` header and `upload` authorization |
| `HEAD /<sha256>[.ext]` | 200 with content type and length, or 404 |
| `GET /<sha256>[.ext]` | 302 to the stored copy's URL, or the bytes over the ssh fallback |
| `GET /list/<pubkey>` | the caller's own unblocked uploads (`since`/`until` query); hex, npub or nprofile; `list` authorization |
| `PUT /upload` | stores the body |
| `PUT /media` | strips metadata first, then stores |
| `PUT /mirror` | `{"url": ...}`: downloads the URL (through `blossom.proxy`, 300 s) and stores it |
| `DELETE /<sha256>[.ext]` | `delete` authorization by the uploader; schedules `purge_media_` and waits up to `node_wait_timeout_s` for it |

**Authorization**: `Authorization: Nostr <base64 event>`, a kind-24242 event with a valid
signature, a `t` tag equal to the action, an `expiration` tag in the future if present, and for
uploads and deletes an `x` tag equal to the blob's sha256. Refused (401) when the pubkey is blocked
in the `csam` filterlist group or the blob is in `media_uploads_media_block_csam`.

**Storing a blob**: `application/octet-stream` bodies are refused (415). The blob is written to
`<root>/uploads2/<s[0]>/<s[1..2]>/<s[3..4]>/<sha256><ext>` under every `local_storages` root, with a
`media_storage` row per storage (URL under `media_server_url`) and a membership `media_uploads` row;
the answer is the blob descriptor (`url` under `base_url`, `sha256`, `size`, `type`, `uploaded`);
then an `import_upload_3` node is scheduled.

**Metadata stripping** (`/media`): `exiftool -all=` keeping the orientation (audio is left
alone); videos are then remuxed by `ffmpeg -map_metadata -1 -movflags +faststart`. Recorded in
`media_metadata_stripping` (sha256 before and after). With `sandboxing`, both run under
`bwrap --unshare-net` with `/nix` read-only and the media `tmp_dir` bound.

**Lookups** go through a blob cache cleared every 60 s. A blob is hidden when every uploader of it is
blocked, or when its storage rows carry a block id.

**ssh fallback**: when the blob's URL is under `media_server_url` and the file is missing from
`media_serving_dir` (or, when that is unset, from every `local_storages` root), the server runs
`ssh <ssh_fallback_host> cat <ssh_fallback_remote_base><path>` (batch mode, 10 s connect timeout),
checks the sha256 and serves the bytes itself. Only paths under `/uploads/` or `/uploads2/` whose
file name is the sha256 are fetched. A failure answers 404.

**Request log**: with `log_db`, every PUT is logged to that DB's `log` table (tag
`blossom.put_handler`: request headers, path, size, auth event, response status or error).

## Configuration

`primal_jobsd <config.json>` reads one JSON object. `primal_jobsd --check-config <config.json>`
parses it, runs the extensions' initialisation, checks that every role is known, prints
`config ok` and exits 0; errors exit 2.

**Every top-level key is required**, including those of roles the instance does not run (give
them inert values, e.g. a zero key for `dvm_requester_pubkey`). Exceptions: `dag_statement_timeout_s`
(default 30), `media`, `blossom` and `ext` may be absent. Unknown keys are ignored. A conninfo is
`{"host", "port", "user", "database"}`.

| Key | Type | Used by | Meaning |
|---|---|---|---|
| `roles` | string list | | the roles to run |
| `admin_host`, `admin_port` | string, int | | admin HTTP listener |
| `cache_db` | conninfo | all | the cache DB (for `media`/`blossom`, the DB holding the processing and media tables) |
| `membership_db` | conninfo | all | the membership DB |
| `relay_proxy` | string or null | dvm_checker, dvm_provider, rebroadcast | SOCKS5 proxy, `socks5h://host:port` or `socks5://host:port` |
| `dvm_relays` | string list | dvm_checker | relays the job requests go to |
| `dvm_requester_seckey`, `dvm_requester_pubkey` | 64 hex | dvm_checker | requester key; the pubkey is the "user" of personalized feeds |
| `dvm_check_period_s` | number | dvm_checker | period (usually 600) |
| `dvm_timeout_s` | number | dvm_checker | per-request timeout (usually 30) |
| `dvm_parallel` | int | dvm_checker | concurrent checks (usually 8) |
| `dvm_randomized_delays` | bool | dvm_checker | random start delay per check |
| `dvm_log` | bool | dvm_checker | log every check |
| `dvm_provider_keypair_salt` | hex or null | dvm_provider | key salt; `null` = role off |
| `dvm_provider_relays` | string list | dvm_provider | relays to serve on and answer to |
| `dvm_provider_announce_created_at` | int | dvm_provider | `created_at` of the announcements |
| `dvm_provider_dry_run` | bool | dvm_provider | log instead of publishing and recording |
| `pg_listener_rate_limit_s` | int | pg_listener | per host/follower (usually 3600) |
| `pg_listener_log` | bool | pg_listener | log notification counts |
| `trustrank_period_s` | number | trustrank | period (usually 10800) |
| `trustrank_iterations` | int | trustrank | usually 20 |
| `trustrank_alpha` | number | trustrank | usually 0.85 |
| `trustrank_target_table` | string | trustrank | `pubkey_trustrank` = live swap; any other name = standalone table |
| `trustrank_run_at_start` | bool | trustrank | first run at start instead of after one period |
| `trustrank_extra_targets` | conninfo list | trustrank | other DBs that get the same table |
| `api_config_path` | string | analytics, dvm_provider | the API's JSON config |
| `analytics_period_s` | number | analytics | period (usually 600) |
| `analytics_key_suffix` | string | analytics | appended to the cache keys; `""` = the live keys |
| `ollama_host` | string or null | analytics | `host:port` of Ollama; `null` disables gaming detection |
| `gaming_report_command` | string list or null | analytics | argv receiving the gaming report on stdin |
| `dag_period_s` | number | dag | tick period (usually 5) |
| `dag_tasks` | int | dag | parallel segments (usually 8) |
| `dag_dry_run` | bool | dag | roll back everything, record no coverage |
| `dag_since` | int | dag | earliest `imported_at` to process |
| `dag_poll_votes_enabled` | bool | dag | run `poll_stats` |
| `dag_log` | bool | dag | log every segment and node |
| `dag_dry_run_window_s` | int | dag | with `dag_dry_run`: exercise every node once over this many seconds; 0 = off |
| `dag_statement_timeout_s` | int, optional | dag | statement timeout of the DAG's connections (default 30) |
| `pushgateway` | object or null | dag | `{host, port, job}` |
| `membership_discovery_url` | string or null | failover | the discovery document URL |
| `media` | object, optional | media, blossom | below |
| `blossom` | object, optional | blossom | below |
| `ext` | any, optional | extensions | settings of extension roles |

### The `media` object

Every key is required unless marked optional.

| Key | Type | Meaning |
|---|---|---|
| `binary_data_cache_dir` | string | binary cache of node arguments; shared by the `media` and `blossom` processes |
| `media_url_root` | string | URL root of local storage |
| `tmp_dir` | string | scratch files (ffmpeg output, sandbox bind) |
| `proxies` | string list | SOCKS5 proxies for downloads, `socks5[h]://host:port` |
| `metadata_proxy` | string or null | proxy for link previews; `null` or `"null"` = direct |
| `download_timeout_s` | number | download timeout for non-Primal hosts |
| `strip_image_metadata` | bool | strip metadata from originals fetched by `media_variants_pn` |
| `s3_providers` | list | `{name, endpoint, region, bucket, access_key, secret_key}`, optional `bucket2` (purge backup), `domain` (public host) |
| `hls_providers` | list | `{type: aws\|mux\|bunny\|cloudflare, enabled, ...}`: `aws`: `api_key`, `api_secret`, `region`, `role_arn`, `s3_output_bucket`, optional `s3_output_path`, `endpoint`, `abr_profiles` (`{name, width, height, video_bitrate, audio_bitrate}`); `mux`: `api_key`, `api_secret`; `bunny`: `api_key`, `library_id`, `cdn_hostname`; `cloudflare`: `api_token` (or `api_key`), `account_id` |
| `hls_processing_timeout_s` | number | how long `import_media_hls_pn` waits per provider |
| `media_paths`, `media_paths_2` | object | `{uploadfast, upload, cache}`, each a list of `{"type": "local", "host", "path"}` or `{"type": "s3", "provider", "dir"}`; `host` is the `storage_provider` name |
| `ai_host` | string | host of Ollama (11434) and the image/video feature servers (5013/5014) |
| `ai_timeout_s` | number | timeout of those calls |
| `blossom_host` | string | host name `media_import_2` returns URLs under |
| `ffmpeg_remote_host` | string or null | ssh host that runs the resizing ffmpeg |
| `scheduler_period_s` | number | claim period (usually 1) |
| `worker_domains` | int, optional | worker domains (default 8) |
| `worker_pool_size` | int, optional | cache-DB connections per worker domain (default 8) |
| `max_concurrent_per_name` | int | running-node limit per func |
| `julia_duty_concurrency` | int | running-node limit of `import_upload_3`, `block_media`, `purge_media_` (the funcs the Julia nodes used to run; the key keeps its name) |
| `refresh_matview_period_s` | number | `pn_time_for_pubkeys` refresh period (usually 600) |
| `cloudflare_cache` | object or null | `{zone_id, api_key}` for cache purges |
| `blossom_hosts` | string list | host names whose URLs `purge_media_` treats as Blossom blobs |
| `upload_url_root` | string | URL root of the upload copies |
| `user_content_purger_api` | string or null | URL `purge_user_content` posts to |
| `execute_funcs` | string list or null | funcs this instance claims (`[]` = none, e.g. a Blossom-only instance); `null` = the default list |
| `log` | bool | log every node's completion |

### The `blossom` object

| Key | Type | Meaning |
|---|---|---|
| `port` | int | listener port |
| `base_url` | string | public URL of the server (blob URLs in answers) |
| `media_server_url` | string | URL root of the stored copies |
| `local_storages` | object | `storage_provider` name -> root directory; every upload is written to each |
| `media_serving_dir` | string, optional | directory `media_server_url` serves from on this host (for the ssh fallback check) |
| `ssh_fallback_host`, `ssh_fallback_remote_base` | string, optional | ssh fallback; both needed to enable it |
| `ssh_fallback_timeout_s` | number, optional | default 300 |
| `log_db` | conninfo, optional | DB of the PUT request log (`port` defaults to 5432) |
| `proxy` | string, optional | SOCKS5 proxy for `/mirror` downloads |
| `sandboxing` | bool, optional | run exiftool/ffmpeg under bwrap (default true) |
| `node_wait_timeout_s` | number, optional | DELETE's wait for `purge_media_` (default 120) |

## Operation

- Run: `primal_jobsd <config.json>`. Logs go to stdout, one line per message with a timestamp
  and a role tag (`[dag]`, `[trustrank]`, `[media]`, `[blossom]`, ...); every periodic run also logs
  `<role>: run took Ns`.
- Restarts are stop-then-start: the roles are singletons. A Blossom-only instance (`roles:
  ["blossom"]`, `execute_funcs: []`) can be replaced rolling instead: start the new process on the
  same port (SO_REUSEPORT), then stop the old one, which finishes its in-flight requests.
- Stop: SIGTERM, SIGINT, SIGUSR1 or `POST /stop`. Periodic roles stop at their next check; the
  daemon waits up to 60 s for every role to return (the Blossom server finishes in-flight requests),
  then exits 0. Work still running is cut off: an unfinished DAG segment rolls back and records no
  coverage, unfinished media nodes are reset at the next start.
- A failure inside a periodic run is logged and the run repeats after the period. A role that fails
  while setting up (DB connection, missing DAG tables, unreadable API config) stops the daemon.
- External tools for `media`/`blossom`: `file`, `identify`, `magick`, `ffprobe`, `ffmpeg`,
  `exiftool`, `nice`, `ionice`, `ssh` (fallback, remote ffmpeg), `bwrap` (sandboxing). The media
  role adds the user's Nix profile and the system binary directories to `PATH` when missing, and
  removes `LD_LIBRARY_PATH` from the tools' environment. Child processes are started with
  `posix_spawn`, with a deadline after which they are killed.

### Admin HTTP (`admin_host:admin_port`)

| Endpoint | Answer |
|---|---|
| `GET /healthz` | `ok` |
| `GET /readyz` | 200 `ready` while serving, else 503 with the state |
| `GET /status` | JSON: pid, state, uptime, roles, `rss_bytes` |
| `GET /tasks` | per-fiber phase report |
| `POST /stop` | starts the stop |

## Extensions

`Daemon.run ~argv ?init ()` is the whole daemon; `bin/primal_jobsd.ml` calls it without `init`. A
private build calls it with an `init` that registers more:

- roles: `Roles.register name (fun ctx -> ...)`, with the config's `ext` object for their settings;
- node handlers: `Procgraph.register ~mod_ ~func handler`;
- media hooks: `Hooks.after_import_upload` (analysis of each uploaded image/video) and
  `Hooks.bunny_purge` (CDN purge after a CSAM match).

## Tools

- `media_tool CONFIG CMD`, on a jobs config with a `media` object:
  - `pending`: pending nodes per func (last 3 days) with the oldest;
  - `show-node HEX`: one node's row;
  - `execute-node HEX`: runs a stored node now with the registered handlers;
  - `import-media URL [EID]`: creates and runs an `import_media_pn` node (all variants);
  - `import-preview URL EID`: creates and runs an `import_preview_pn` node;
  - `check-ids [LIMIT]`: recomputes the ids of the latest nodes under the two id conventions found
    in stored rows and reports matches per func.
- `blossom_tool`: a Blossom client signing kind-24242 authorizations (key file: nsec or hex):
  `auth KEY ACTION [SHA256]` prints the header; `put BASE KEY FILE [upload|media]`,
  `mirror BASE KEY URL`, `get BASE SHA256[.ext]` (HEAD and GET, no redirects), `list BASE KEY`,
  `delete BASE KEY SHA256[.ext]`.

## Layout

```
bin/primal_jobsd.ml        the public binary (Daemon.run)
bin/media_tool.ml          processing-graph inspection and manual runs
bin/blossom_tool.ml        Blossom client
lib/daemon.ml              startup, role fibers, stop
lib/config.ml              the JSON config
lib/roles.ml               role registry for extensions
lib/periodic.ml            run / sleep / repeat loop
lib/admin.ml               admin HTTP
lib/api_context.ml         the in-process API's DB pools (analytics, dvm_provider)
lib/dag.ml                 dag
lib/trustrank.ml           trustrank
lib/analytics.ml           analytics
lib/dvm_checker.ml         dvm_checker
lib/dvm_provider.ml        dvm_provider (the feed list)
lib/pg_listener.ml         pg_listener
lib/rebroadcast.ml         rebroadcast
lib/failover.ml            failover
lib_membership/            membership-DB statements ([%pgsql])
lib_media/media_config.ml  the media object
lib_media/media_role.ml    media role setup
lib_media/scheduler.ml     claiming and worker domains
lib_media/procgraph.ml     nodes, execution, handler registry
lib_media/pgj.ml           typed node JSON (alias of common's Pgj)
lib_media/proc.ml          external processes
lib_media/media_tools.ml   downloads, probing, ffmpeg, link previews, AI calls
lib_media/media_store.ml   local and S3 storage
lib_media/hls.ml           HLS providers
lib_media/nodes_media.ml   media and preview nodes
lib_media/nodes_upload.ml  import_upload_3
lib_media/nodes_moderation.ml  purge_media_, block_media, inc_counter, purge_user_content
lib_media/nodes_text.ml    import_text_event_pn
lib_media/hooks.ml         extension hooks
lib_media/blossom.ml       the Blossom server
test/test_media.ml         unit tests
```

`lib/` links the importer (`primal_importer`: notification writer, DAG indexers) and the API
(`primal_api`, `primal_api.db`: `scored_content`, `mega_feed_directive`). Shared code is in
`../common`.

## Build and test

From anywhere in the repo, with the shared dev shell:

    nix develop "path:$(git rev-parse --show-toplevel)/common" -c dune build @all
    nix develop "path:$(git rev-parse --show-toplevel)/common" -c dune test jobs

`_build/` is at the repository root; the binaries are
`_build/default/jobs/bin/{primal_jobsd,media_tool,blossom_tool}.exe`.

`[%pgsql]` statements are type-checked at compile time: `lib/` against a cache DB (point
`PGHOST`/`PGPORT` at a database created from `schema/cache.sql`), `lib_membership/`
against a membership DB (its `dune` sets `PGDATABASE` to the membership reference DB created from
`schema/membership.sql`). `lib_media/` uses dynamic SQL only. See
`schema/README.md`.

The tests (`test/test_media.ml`) cover float formatting, storage key hashes, the typed node JSON,
Blossom paths, external processes, and the download rules (direct hosts, refusal of private
addresses).
