# primal-api

`primal_apid` is the Primal cache API daemon (OCaml 5, Eio). One process serves:

| Listener | Config key | What |
|---|---|---|
| public WebSocket | `public_ws_port` | the cache API: `REQ`/`CLOSE` with `cache` funcalls, a few plain Nostr filters, push subscriptions |
| second WebSocket (optional) | `cache_ws_port` | the same WebSocket service on another port (health probes, internal callers) |
| internal HTTP | `internal_http_port` | `/api` (funcalls over HTTP), NIP-05, media/link-preview helpers, URL shortener, web-app previews |
| moderation HTTP | `moderation_http_port` | `/purge-media`, `/pre-sign-urls` |
| admin HTTP | `admin_host`:`admin_port` | health, readiness, status, Prometheus metrics, drain |

All listeners except admin bind `public_ws_host`. Every port is bound with `SO_REUSEPORT`, so a new
generation can start on the same ports while the old one drains. It reads the cache DB and the
membership DB (PostgreSQL), and talks to the importer, relays, S3 and a few HTTP services as
configured below.

`primalctl` (same directory) is the operator CLI.

The earlier Julia/Rust implementation is in git tag `julia-final`; the "Julia ..." comments in the
sources refer to it.

## WebSocket protocol

```
client:  ["REQ", subid, {"cache": [funcall, {kwargs}]}]      ["CLOSE", subid]
server:  ["EVENT", subid, msg]* ["NOTICE", subid, text]* ["EOSE", subid]
```

- **zlib mode.** `["REQ", s, {"cache": ["set_primal_protocol", {"compression": "zlib"}]}]` is answered
  with EOSE and switches the connection: each later answer is one binary frame
  `zlib(["EVENTS", subid, [msg, ...]])` followed by text NOTICEs and `["EOSE", subid]`. Push
  subscription updates stay plain text `EVENT` frames.
- **Errors.** A funcall name primal-api does not know is answered `NOTICE "unknown api request"` +
  EOSE. A known funcall whose handler fails (bad kwargs, DB error, 15 s wait for a pool connection)
  gets `NOTICE "error"` + EOSE; some handlers answer `NOTICE "error"` deliberately for invalid input
  (e.g. `limit > 1000`).
- **Plain filters** (a REQ without `cache`): `{"ids": [...]}` runs `events`; `{"since"/"until", "limit",
  "idsonly"}` runs `events` once (no live push). A filter containing `kinds` or `authors` gets
  `NOTICE "kinds or authors filter is not supported"` (no EOSE) and the connection is closed. Other
  filters (including `search`) are not handled: `NOTICE "error"`.
- **Concurrency.** Up to `request_concurrency` REQs of one connection run at once; answers can
  interleave across subids. `set_primal_protocol`, `CLOSE` and non-REQ frames are handled in order.
  With `request_concurrency = 1` answers come strictly in request order.
- **Push subscriptions.** The REQ stays open until `CLOSE` or disconnect:

  | Funcall | Pushes |
  |---|---|
  | `live_feed` | new events tagging the live event's address (`a` tag), filtered per viewer (`content_moderation_mode`) |
  | `live_events_from_follows` | kind-30311 live events whose host the viewer follows |
  | `notification_counts`, `notification_counts_2` | unread notification counts, every 1 s |
  | `directmsg_count`, `directmsg_count_2` | unread DM count, every 1 s |
  | `rebroadcasting_status` | the membership content-rebroadcast progress, every 2 s |
  | `net_stats` | network stats, every `netstats_period_s` (from `network_stats_url` or `network_stats_file`; silent if neither is set) |

  Live events come from a 1 s poll of newly imported events plus `LISTEN primal_events` on the cache
  DB (`live_events_enabled`).
- **Idle connections** are closed after `0.95–1.0 × idle timeout` without a frame in either direction
  (checked every 3 s). The timeout starts as `idle_connection_timeout_s` and follows the
  `wsconnvars` table.
- **Limits.** Inbound messages over `ws_max_message_bytes` close the socket with 1009. A frame not
  flushed to the client within `ws_send_stall_s` closes the socket. `ws_outbound_queue` frames can be
  queued per connection before the sender waits.
- **Anonymous feed cache.** When `anon_feed_cache_s > 0`, answers of `mega_feed_directive`,
  `multi_kind_mega_feed_directive` and `explore` for the default viewer (no `user_pubkey`, or the
  Primal pubkey), and of `scored_users_24h` and `user_infos` for anyone, are reused for that many
  seconds (TTL from computation; concurrent misses wait for one computation; at most ~4096 entries).
  A fresh hit is answered inline, without taking a concurrency slot.
- Any GET without an `Upgrade` header gets the text `Primal cache API Websocket endpoint`. Any path
  upgrades.

## Funcalls

The catalogue is the closed variant `Funcall.t` in `lib/funcall.ml` (146 names). `Funcall.dispatch`
matches it exhaustively, so a constructor without a handler arm does not compile.

| Area | Funcalls |
|---|---|
| Feeds, threads, articles | `feed`, `feed_2`, `feed_directive`, `feed_directive_2`, `mega_feed_directive`, `multi_kind_mega_feed_directive`, `thread_view`, `multi_kind_thread_view`, `long_form_content_feed`, `long_form_content_thread_view`, `enrich_feed_events`, `note_mentions`, `note_mentions_count`, `events`, `get_bookmarks`, `get_highlights`, `find_reposts`, `drafts`, `top_article`, `articles_stats`, `get_reads_topics`, `get_reads_feeds`, `get_featured_authors`, `get_home_feeds`, `get_recommended_reads`, `get_advanced_feeds` |
| Profiles, follows, lists | `user_infos`, `user_profile`, `user_profile_followed_by`, `user_profile_scored_content`, `user_profile_scored_media_thumbnails`, `contact_list`, `is_user_following`, `user_followers`, `mutual_follows`, `follow_list`, `follow_lists`, `mutelist`, `mutelists`, `allowlist`, `user_search`, `get_user_relays`, `get_user_relays_2`, `user_of_ln_address`, `creator_paid_tiers`, `get_recommended_users`, `get_suggested_users`, `get_suggested_users_2`, `trusted_users`, `replaceable_event`, `parametrized_replaceable_event`, `parametrized_replaceable_events`, `parameterized_replaceable_list`, `nip19_decode`, `get_media_metadata`, `poll_votes` |
| Explore, trending, search | `explore`, `explore_media`, `explore_zaps`, `explore_people`, `explore_topics`, `explore_legend_counts`, `explore_global_trending_24h`, `explore_global_mostzapped_4h`, `scored`, `scored_users`, `scored_users_24h`, `trending_hashtags`, `trending_hashtags_4h`, `trending_hashtags_7d`, `trending_images`, `trending_images_4h`, `search`, `advanced_search`, `advanced_feed`, `parse_advanced_search_query` |
| Zaps, reactions | `zaps_feed`, `user_zaps`, `user_zaps_by_satszapped`, `user_zaps_sent`, `event_zaps_by_satszapped`, `event_actions`, `invoices_to_zap_receipts` |
| Notifications, DMs | `get_notifications`, `set_notifications_seen`, `get_notifications_seen`, `notifications`, `notification_counts`, `notification_counts_2`, `get_directmsgs`, `get_directmsg_contacts`, `directmsg_count`, `directmsg_count_2`, `reset_directmsg_count`, `reset_directmsg_counts` |
| Settings, app config | `get_default_app_settings`, `get_app_settings`, `get_app_settings_2`, `set_app_settings`, `get_default_app_subsettings`, `get_app_subsettings`, `set_app_subsettings`, `get_app_releases`, `client_config`, `get_default_relays`, `get_recommended_blossom_servers`, `relays`, `server_name`, `set_last_time_user_was_online`, `update_push_notification_token`, `update_push_notification_token_for_nip46` |
| Moderation | `check_filterlist`, `get_filterlist`, `search_filterlist`, `is_hidden_by_content_moderation`, `report_user`, `report_note` |
| Live events | `live_feed`, `live_events_from_follows`, `find_live_events` |
| Stats | `net_stats`, `network_stats`, `nostr_stats` (always `NOTICE "error"`), `rebroadcasting_status` |
| DVM feeds | `get_dvm_feeds`, `get_featured_dvm_feeds`, `dvm_feed_info`, `dvm_feed` |
| Relays, importer | `broadcast_events`, `broadcast_reply`, `import_events`, `import_poll_vote_event` |
| NIP-46 | `get_queued_events_for_nip46`, `events_nip46` |
| Membership | `membership_content_stats`, `membership_content_backup`, `membership_recovery_contact_lists`, `membership_recover_contact_list`, `membership_content_rebroadcast_start`, `membership_content_rebroadcast_status`, `membership_content_rebroadcast_cancel`, `membership_legends_leaderboard`, `membership_premium_leaderboard`, `membership_media_management_stats`, `membership_media_management_uploads`, `membership_media_management_delete` |

Behaviour worth knowing:

- **Content moderation.** Answers of most funcalls pass through `Moderation.filter`: hidden and
  deleted events, the viewer's compiled content-moderation rules for the funcall's scope (content or
  trending), default rules when there is no `user_pubkey`. Funcalls dispatched with
  `~moderate:false` (their SQL already applies the viewer's rules, or they are writes) skip it.
- **Advanced search** (`lib/advsearch.ml`): the query language is parsed to an AST and compiled to
  SQL; execution walks back from `until` in time windows (1 h, widened 4× while empty) under a 9 s
  budget and returns partial results when it runs out. `primalctl advsearch-sql` prints one window's
  SQL for `EXPLAIN`.
- **In-process caches:** `trending_hashtags_4h` and `trending_images_4h` 10 min,
  `trending_hashtags_7d` 4 h, the 24 h trending score percentiles used by `minscore:`/`maxscore:`
  10 min. Files under `content_moderation_root` are re-read only when their mtime changes.
- `search` (and the `search` spec of `mega_feed_directive`) answers `NOTICE "error"`: Julia
  forwarded it to a separate search node, which no longer exists.
- `broadcast_events` / `broadcast_reply` publish to every relay concurrently (through `relay_proxy`)
  and answer when one relay accepts, or after 15 s, with the replies received so far.
- `dvm_feed` answers a non-personalized feed from the DVM results already in the cache DB
  (`usecache`, default true); otherwise it sends a NIP-90 job request
  (kind 5300, signed with `dvm_requester_seckey`) to `dvm_relays` plus the handler's relay and waits
  up to the `timeout` kwarg (default 10 s) for the result.
- `import_events` sends events to the importer's import listener (`import_events_line_server`); with
  that key `null` it answers with EOSE only.
- **Replication.** `set_notifications_seen`, `reset_directmsg_count` and `reset_directmsg_counts`
  are re-sent with `"replicated": true` to every WebSocket in `replicate_to` (fire and forget, 2 s per
  target, a queue of 1000 that drops when full). Requests already marked `replicated` are not passed
  on, so two hosts can point at each other.
- `mega_feed_directive` spec ids that name a funcall are dispatched through the same registry.

### Adding a funcall

1. Add the SQL to `lib/queries.ml` (cache DB) or `lib_membership/queries_mem.ml` (membership DB) as a
   `[%pgsql]` statement; handlers contain no SQL.
2. Write the handler in `lib/handlers.ml`: `ctx -> Kw.t -> Response.outcome`. Read kwargs with `Kw`
   (raise `Kw.Invalid` on bad input); return `Handled { messages; registrations }` (messages are JSON
   texts, sent unchanged), `Notice text`, or `Not_handled`.
3. Add a constructor to `Funcall.t`, its name to `Funcall.names`, and an arm to `Funcall.dispatch`
   (`run` or `run ~moderate:false`).
4. For a push subscription, return a `Response.registration` and serve it in `Broadcasts` or
   `Live_events`.

### Extensions

A private build adds funcalls and HTTP routes without changing this repo. It calls
`Daemon.run ~argv ~init ()`; `init` runs after the config is parsed and before anything listens, and
fills the `Extensions` registry (`lib/extensions.ml`):

- `Extensions.register_funcall ?moderate name handler`: consulted for names that are not in
  `Funcall.t` (a public name always wins); a duplicate registration fails at startup.
- `Extensions.register_http_route (`Internal | `Moderation) route`: extra routes on the internal or
  moderation HTTP port.
- The optional top-level config object `"ext"` is passed through untouched (`Config.t.ext`) for the
  extension's own settings.

`--check-config` runs `init` too.

## HTTP services

**Internal port** (`internal_http_port`, CORS on, 4 MB body limit; handler errors are `500 error`):

| Route | What |
|---|---|
| `GET`/`POST /api` | body `["funcall", {kwargs}]`; answers a JSON array of messages, or `{"error": text}` for a NOTICE. Unknown and unhandled funcalls get `500 error`. `server_name` answers `{server, node}` from `http_server_name`. |
| `POST /collect_metadata` | body: list of hex pubkeys → their kind-0 events |
| `GET /.well-known/nostr.json?name=` | NIP-05 from the membership DB's verified names |
| `GET /media-upload?u=`, `GET /media-cache?u=&s=&a=` | 302 to the media URL if it is a known/allowed host, else 404 |
| `GET /link-preview?u=` | page metadata (title, description, image) fetched through `download_proxies`; empty list = previews disabled |
| `GET /url-shortening?u=`, `GET /url-lookup/<path>` | short URLs under `url_shortening_root_url` (membership DB) and their redirect |
| `GET /spam` | the curated filter lists |
| `GET`/`POST /api/suggestions`, `/api/suggestions_2` | suggested accounts from the content-moderation files, with metadata |
| `GET /.well-known/{apple-app-site-association,assetlinks.json,remote-signer-nip46-*.json}` | static files from `content_moderation_root` |
| `GET /*` (anything else) | the web app's `index.html` for the request's `Host` (from `index_dirs`) with OpenGraph/Twitter meta tags for profiles, notes, articles and live events; unknown hosts 404 |

**Moderation port** (`moderation_http_port`, no authentication: keep it internal):

- `POST /purge-media` `{"url", "pubkey"?, "reason"?, "initiator_pubkey"?, "block_all_uploads"?,
  "clear_cache"?}`: records a media block, moves local copies under each local `media_paths` root
  into a sibling `cdn-hidden/`, copies S3 objects to the provider's `bucket2` and deletes them,
  purges the Cloudflare cache (when `cloudflare` is set) and marks every row that points at the
  file. Answers `ok`.
- `POST /pre-sign-urls` `{"storage_provider", "bucket", "paths"}`: pre-signed S3 GET URLs, as
  `{path: url}`.

## Configuration

One JSON file, given as the only argument. Every key below is **required** (use `null`, `[]` or
`{}` where allowed); only `ext` may be absent. Keys not listed are ignored, so a config that still
carries a removed key keeps loading. `primal_apid --check-config <file>` parses it (and
runs the extensions' `init`), prints `config ok` and exits 0; a bad config exits 2 with the reason.

Listeners and process:

| Key | Type | Meaning |
|---|---|---|
| `servername` | string | answer of `server_name` over WebSocket; shown in `/status` |
| `public_ws_host` | string | bind address of every listener except admin |
| `public_ws_port` | int | public WebSocket API |
| `cache_ws_port` | int \| null | second port for the same WebSocket service |
| `internal_http_port` | int | internal HTTP services |
| `moderation_http_port` | int | moderation HTTP |
| `admin_host`, `admin_port` | string, int | admin HTTP (keep it on loopback) |
| `num_domains` | int | OCaml domains; each accepts on the public WS, second WS and internal ports; the main one also runs moderation, admin and the background loops |
| `status_interval_s` | float | period of the status line on stdout (0 = off) |
| `drain_grace_s` | float | after a drain signal: time for connections to finish before the remaining WebSockets are closed |
| `drain_ws_max_s` | float | further time allowed for closing them before the process exits |
| `log_handled` | bool | log a line per locally answered request (funcall, subid, ms) |
| `log_not_handled` | bool | log a line per request primal-api could not answer (WebSocket and HTTP `/api`) |
| `pushgateway` | `{host, port, job, period_s}` \| null | push `cache_max_request_duration` (longest request of the period, s) and `cache_requests_per_second` every `period_s`; a draining generation stops pushing |
| `request_log` | path \| null | JSONL request log (see Operation) |

WebSocket behaviour:

| Key | Type | Meaning |
|---|---|---|
| `idle_connection_timeout_s` | float | idle timeout until `wsconnvars` provides one |
| `wsconnvars_poll_s` | float | poll period of the `wsconnvars` table |
| `ws_max_message_bytes` | int | inbound message cap |
| `ws_outbound_queue` | int | frames queued per connection before the sender waits |
| `ws_send_stall_s` | float | close a socket whose frame is not flushed within this |
| `request_concurrency` | int | REQs of one connection handled at once (1 = in order) |
| `anon_feed_cache_s` | float | TTL of the anonymous feed cache (0 = off) |
| `live_events_enabled` | bool | run the live-event distributor |
| `http_server_name` | `{server, node}` \| null | `server_name` answer over HTTP `/api` (null: `500 error`) |
| `replicate_to` | list of ws URLs | other APIs that get replicated counter resets |

Databases (`{host, port, user, database}`; every pooled connection has a 30 s `statement_timeout`):

| Key | Type | Meaning |
|---|---|---|
| `cache_db` | conninfo | cache DB |
| `membership_db` | conninfo | membership DB |
| `cache_pool_size`, `membership_pool_size` | int | connections per domain (lazily opened) |
| `monitoring_db` | conninfo \| null | DB with `monitoring_events`, read by `events_nip46` (null: `NOTICE "error"`) |

Content and services:

| Key | Type | Meaning |
|---|---|---|
| `content_moderation_root` | path | directory of the content-moderation files (`default-settings.json`, `app-releases.json`, `advanced-feeds.json`, `client-config.json`, `hashtag-whitelist.txt`, `suggested-accounts*.json`, the `.well-known` files, …) |
| `primal_pubkey` | 64 hex | default `user_pubkey` of handlers that need a viewer |
| `algos_user_pubkey` | 64 hex \| null | account whose mute list is the NSFW group in `search_filterlist` |
| `trending_blocked_domains` | list of strings | NIP-05 domains hidden from trending/explore |
| `network_stats_url` | http URL \| null | HTTP `/api` answering `network_stats` (the importer's); wins over the file |
| `network_stats_file` | path \| null | the importer's `stats.json`, read directly |
| `netstats_period_s` | float | `net_stats` push period |
| `import_events_line_server` | `{host, port}` \| null | the importer's import listener for `import_events` |
| `relay_proxy` | `socks5h://host:port` \| null | SOCKS5 proxy for relay connections, DVM requests and S3 calls |
| `dvm_relays` | list of ws URLs | relays for DVM job requests |
| `dvm_requester_seckey` | 64 hex \| null | signs DVM job requests (null: live `dvm_feed` answers `NOTICE "error"`) |
| `primal_dvm_pubkeys` | list of hex | DVMs marked `is_primal` in DVM feed metadata |
| `index_dirs` | `{host: dir}` | web-app directory (with `index.html`) per `Host` for preview pages |
| `url_shortening_root_url` | string | prefix of short URLs |
| `download_proxies` | list of strings | proxies for `/link-preview` (`"null"` = direct); empty disables previews |
| `s3_providers` | list of `{name, endpoint, region, bucket, bucket2, access_key, secret_key, domain}` | S3 storage (`bucket2`, `domain` may be null) |
| `cloudflare` | `{zone_id, api_key}` \| null | cache purge on `/purge-media` |
| `media_paths` | list of `{"type": "local", "root", "label"}` \| `{"type": "s3", "provider", "label"}` | storage a purge walks; `label` (may be null: `local` or the provider name) is the storage provider name in the DB |
| `ext` | object, optional | settings of a private extension |

## Operation

Run `primal_apid <config.json>`. It logs to stdout. Typically it runs under a service manager.

**Signals and drain.** `SIGUSR1`, `SIGTERM`, `SIGINT` and `POST /drain` all start a drain:

1. `/readyz` turns 503 and the Pushgateway pushes stop.
2. The public, second WebSocket, internal and moderation listeners close in every domain, so the
   kernel sends new connections to another generation on the same ports (the admin listener stays
   open).
3. WebSockets idle for 30 s with no request in flight are closed at once.
4. Up to `drain_grace_s` for the remaining connections to finish; then every WebSocket is closed
   (requests in flight still finish), with up to `drain_ws_max_s` more.
5. The process exits 0.

A stop by a service manager therefore needs a stop timeout of at least
`drain_grace_s + drain_ws_max_s`.

**Rolling restart.** Start the new process with the same config while the old one runs (both hold
the ports), wait until it serves (`/status` shows the new `pid` with `"state": "serving"`; the admin
port is shared too, so check the pid), then signal the old one with `SIGUSR1`.

**Admin endpoints** (`admin_host`:`admin_port`):

| Route | What |
|---|---|
| `GET /healthz` | `ok` |
| `GET /readyz` | 200 `ready` while serving, else 503 with the state (`starting`, `draining`, `stopped`) |
| `GET /status` | JSON: `pid`, `state`, `uptime_s`, `servername`, ports, `connections`, live and broadcast subscription counts, `inflight_http`, `anon_feed_cache` (hits, misses, waits, entries, ttl), `rss_bytes` |
| `GET /metrics` | Prometheus text: `primal_api_connections`, `_accepted_total`, `_recv_total`, `_sent_total`, `_handled_total`, `_idle_closed_total`, `_live_events_total`, `_errors_total`, `_rss_bytes`, `_ready`, `_inflight_http` |
| `GET /tasks` | the fiber phase registry (what each slot is doing) |
| `POST /drain` | start a drain |

**`wsconnvars`** (a cache-DB table, `name`/`value` JSON, polled every `wsconnvars_poll_s`):

| Name | Effect |
|---|---|
| `idle_connection_timeout` | idle timeout in seconds |
| `metrics_logging_enabled` | `true` enables the request log (missing = off) |
| `metrics_logging_min_request_duration` | only requests at least this many seconds long are logged (missing = 0, every request) |

**Request log.** With `request_log` set and logging enabled in `wsconnvars`, every locally answered
WebSocket request is appended as one JSON line `{"t", "time", "funcall", "kwargs", "ws", "subid"}`
(`t` the wall clock, `time` the duration in seconds, `ws` the connection id; plain-filter REQs are
logged as `filter:events`). The file is not rotated.

### primalctl

`_build/default/ocaml-api/bin/primalctl.exe`:

```sh
primalctl req <ws-url> <funcall> ['{kwargs}'] [--zlib]   # one request, frames printed until EOSE, then the duration
primalctl status|metrics|drain [<admin-url>]               # the admin endpoints (default: the selfhost admin port, http://127.0.0.1:8811)
primalctl replay <corpus.jsonl> --a <ws-url> --b <ws-url> [--only f1,f2] [--all]
                 [--per-funcall N] [--workers K] [--timeout S] [--report diffs.jsonl]
primalctl advsearch-sql <user-hex> '<query>' <since> <until> [kinds]   # one advanced-search window's SQL, params inlined
primalctl sign <nsec-file> <kind> <content> ['[tags]']   # a signed event as JSON (for event_from_user kwargs)
```

`replay` sends requests from a request-log file to two servers and compares the answers as
multisets of canonical messages (sorted keys, JSON inside strings canonicalised, integral floats as
integers). It skips writes (`set_*`, `update_*`, `import_*`, `reset_*`, uploads, broadcasts,
reports and the membership writes); by default it replays only funcalls primal-api knows
(`--all`: every funcall in the corpus). It prints per funcall the count, identical share,
timeouts and median latency of each side, and `--report` writes each mismatch with its kwargs and
up to three messages only one side produced. Use it to compare a new build against the running
one over the same data. Always pass `--a` and `--b`; the defaults are leftovers.

## Layout

| Path | What |
|---|---|
| `bin/primal_apid.ml` | the public daemon: `Daemon.run` |
| `bin/primalctl.ml`, `bin/replay.ml` | operator CLI, replay comparison |
| `lib/daemon.ml` | startup, listeners, domains, background loops, drain controller |
| `lib/config.ml` | config parsing |
| `lib/conn.ml` | one client WebSocket: dispatch, concurrency, idle timer, drain registry |
| `lib/protocol.ml` | REQ/CLOSE parsing; EVENT, NOTICE, EOSE and zlib EVENTS framing |
| `lib/funcall.ml` | funcall catalogue and dispatcher |
| `lib/handlers.ml` | one function per funcall |
| `lib/kw.ml`, `lib/response.ml` | typed kwargs; handler results and subscription registrations |
| `lib/queries.ml` | every cache-DB statement (`[%pgsql]`) |
| `lib_membership/queries_mem.ml` | every membership-DB statement (`[%pgsql]`) |
| `lib_db/db.ml` | per-domain connection pools, cache/membership handles kept apart by type |
| `lib/moderation.ml` | per-viewer content-moderation filter of answers |
| `lib/advsearch.ml` | advanced-search parser, SQL builder, windowed execution |
| `lib/anon_cache.ml` | anonymous feed cache |
| `lib/live_events.ml` | live-event subscriptions and distributor |
| `lib/broadcasts.ml` | periodic push subscriptions |
| `lib/netstats.ml` | network stats source |
| `lib/replicate.ml` | replication of counter resets to other APIs |
| `lib/wsconnvars.ml` | `wsconnvars` poller and request log |
| `lib/internal_http.ml`, `lib/moderation_http.ml` | the HTTP services |
| `lib/admin.ml`, `lib/stats.ml` | admin endpoint, counters, status line, Pushgateway |
| `lib/extensions.ml` | registry for private extensions |
| `lib/files.ml`, `lib/jsonfmt.ml` | mtime-cached file reads; two-space pretty JSON |
| `test/test_api.ml` | unit tests (no DB at run time) |
| `tools/` | ad-hoc diagnostics: headless web-app walk (`playwright.sh`, `webapp-walk.py`, `webapp-compare.py`), WebSocket timing and burst clients |

The server kernel (`Http_server` on httpun-eio/httpun-ws, `Listen`, `Lifecycle`, `Ws_client`,
`Zlib_util`, `Postgres`) is in `../ocaml-common`.

## Build and test

From the repository root:

```sh
nix develop path:./ocaml-common -c dune build @all
nix develop path:./ocaml-common -c dune test ocaml-api
```

`_build/` is at the repository root; the daemon is `_build/default/ocaml-api/bin/primal_apid.exe`.

The `[%pgsql]` statements are type-checked at compile time against a live database, so building
(and therefore testing) needs one: create the cache DB from `../ocaml-common/schema/` (see its
README) and point `PGHOST`/`PGPORT` at it. The membership statements in `lib_membership/` are
checked against a second database with the membership schema (`schema/membership.sql`); its name
is set in `lib_membership/dune`.
