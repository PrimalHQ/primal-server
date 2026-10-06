# primal-api

The Primal cache API daemon in OCaml 5 / Eio (`ocaml-plan.md` §5): the WebSocket cache API that
clients reach on port 9001 (and the per-node 8800+N ports), later the HTTP services (14000+N,
24000+N). It replaces the Rust `ws-connector` and the Julia `CacheServer` and
`InternalServices`.

**Status (Phase 3b):** 48 funcall names are answered natively (`Funcall.native_names`, plus
`set_primal_protocol` in the connection layer): the ws-connector ones of Phase 3a (`set_primal_protocol`, `server_name`, `thread_view`,
`multi_kind_thread_view`, `scored`, `get_default_app_settings`, `get_app_releases`, `get_bookmarks`,
`user_infos`, `get_notifications_seen`, `feed`, `mega_feed_directive`,
`multi_kind_mega_feed_directive`, `live_feed`, `live_events_from_follows`, `find_live_events`,
`events`) plus the Julia-era catalogue whose SQL already exists in primal1: `user_profile`,
`user_profile_followed_by`, `contact_list`, `is_user_following`, `mutelist`, `mutelists`,
`allowlist`, `replaceable_event`, `get_user_relays(_2)`, `creator_paid_tiers`, `poll_votes`,
`nip19_decode`, `event_zaps_by_satszapped` (event form), `long_form_content_feed`, `events`
(plain / idsonly / range), `get_reads_topics`, `get_reads_feeds`, `get_featured_authors`,
`get_home_feeds`, `get_recommended_blossom_servers`, `get_default_app_subsettings`,
`get_app_subsettings`, `set_app_subsettings`, `get_default_relays`, `get_media_metadata`,
`note_mentions_count`, `user_profile_scored_content`, `user_search`, `feed_directive` (pubkey
forms), `get_recommended_users`, `get_suggested_users`, `membership_media_management_stats`.
Answers of the 3b funcalls pass through `Moderation.filter`, the port of Julia's
`content_moderation_filtering_2` (hidden/deleted events, the viewer's rules per funcall scope,
USER_SCORES and ZAP_EVENT content; default rules when there is no `user_pubkey`). Live-event push
subscriptions, the `wsconnvars` knobs and the request log are unchanged from 3a. Every other frame
is proxied verbatim to the Julia CacheServer (`upstream_julia_ws`), as ws-connector does
(`set_primal_protocol` is not forwarded; zlib applies to native answers only).

Parity against the production ws-connector → Julia on 9001 (`primalctl replay`, 300 requests per
funcall from the request corpus, 7238 in all): 99.6 % identical; every native funcall is at
99.3–100 % and the residue is classified (the deliberate deviations below, counters moving between
the two fetches, Julia's PARTIAL_RESPONSE under its time budget). `mega_feed_directive` shows
91.7 % only because its proxied specs (advsearch, reads/follows, nostr-reads-feed, explore-media)
vary on the Julia side under the six-worker load — one at a time Julia, the shadow and ws-connector
agree 24/24. The hand-written sets (`scratch wscompare`) are 25/25 (3a) and 52/54 (3b); the two
remaining are `nip19_decode` with TLV ids, where the running Julia predates the flattened `ser()`
in app.jl (ours matches the source). Still proxied on purpose, with the reason: `get_notifications` and
`set_notifications_seen` (in-memory enrichment + cross-node replication), `enrich_feed_events` and
`note_mentions` (Julia's in-memory `response_messages_for_posts` emits a different pubkey set than
the SQL `enrich_feed_events`), `explore_legend_counts` (`all_users` is an in-process Julia stat),
the `(pubkey, identifier)` forms of `event_zaps_by_satszapped`, the search/explore forms of
`feed_directive`, `feed_directive_2`, and every funcall whose SQL function does not exist in
primal1 (membership_* except media stats, DVM feeds, articles/drafts, directmsgs, zaps feeds,
explore_*, user_followers, mutual_follows, parametrized_replaceable_*, search_filterlist,
is_hidden_by_content_moderation, user_of_ln_address, nostr_stats/network_stats, client_config,
import_events, get_highlights, find_reposts, invoices_to_zap_receipts, events_nip46,
update_push_notification_token*) — Phase 4 writes those from the Julia code.
**Phase 4a (2026-10-04):** the push subscriptions Julia's periodic broadcasters served —
`notification_counts(_2)` and `directmsg_count(_2)` every second (one statement per tick for all
subscribed pubkeys), `rebroadcasting_status` every two seconds, `net_stats` every
`netstats_period_s` from the importer's HTTP `/api` (`network_stats_url`) — are native
(`Broadcasts`), as are `get_notifications` (one indexed statement instead of Julia's
time-windowed cursor; `DB.notif2namedtuple` reproduced byte for byte, id included),
`set_notifications_seen` (membership `pubkey_notifications_seen` + the cache counters; Julia's
`REPLICATE_TO_SERVERS` is empty in production) and `notifications` (EOSE only: `broadcast_notification`
lost its producer when the importer moved out of the API node). The non-`cache` REQ filters of
the Julia CacheServer are handled too: `{"ids"}` and `{"since"/"until"}` map to `events`,
`{"search", "kinds":[0]}` to `user_search`, other kinds get the NOTICE "unsupported search filter";
`{"search","kinds":[1]}` (the `search` funcall) stays proxied. Live push of new events to
since/idsonly subscriptions had no producer left in Julia either. Compared with the reference
ws-connector on 9007: push subscriptions identical in shape and cadence; `get_notifications`
identical except the RANGE message, whose since/until Julia sets to the current second.

**Phase 4b (2026-10-04):** the explore family is native: `explore` (app_ext.jl `scored_content` —
global/network/tribe/follows scopes, latest/popular/trending/mostzapped, grouped-by-author and
kinds variants, the retry loop that doubles the candidate window, Julia's post filter as one
statement over the filterlist, deleted events, the trending-blocked nip05 domains
(`trending_blocked_domains`) and the followers ≥ 5 rule), `explore_global_trending_24h`,
`explore_global_mostzapped_4h`, `scored_users(_24h)`, `trending_hashtags(_4h/_7d)` (whitelist
file, Float32 accumulation and Julia's shortest Float32 text, cached 600 s / 14400 s like
`@cached`), `explore_zaps`, `explore_people`, `explore_topics` (the precalculated cache row),
`explore_legend_counts`, and the explore ids of `mega_feed_directive` /
`multi_kind_mega_feed_directive` (`global-trending`, `all-notes`, `most-zapped`,
`hall-of-fame-notes`, `explore-zaps`, spec ids naming exposed functions, the `kinds` form and the
`advanced-feeds.json` fallback; advsearch/dvm/video specs stay proxied, and `latest` with kind
photos/short_videos/media no longer falls into `feed`). Against the reference ws-connector:
`explore`, `explore_people`, `explore_topics`, `scored_users_24h`, `mega_feed_directive`,
`trending_hashtags_7d` identical; `explore_zaps` differs only in which borderline sender passes
the humaness threshold (Julia keeps the value computed at start-up, we read the current one);
`explore_legend_counts` differs on purpose in `all_users` (Julia reports its own node's import
counter — 2 on this host — where we report the importer's network_stats users) and in
`your_outer_network` for 30 % of accounts (Julia walks contact lists capped at 5000 per follow,
we count `pubkey_followers`). `trending_images(_4h)` is still proxied.

**Phase 4c (2026-10-04):** the long tail of app.jl is native: `get_directmsgs`,
`get_directmsg_contacts` (+ Julia's DIRECTMSG_COUNTS moderation rule), `reset_directmsg_count(s)`,
`zaps_feed`, `user_zaps`, `user_zaps_by_satszapped`, `user_zaps_sent`, `event_actions`,
`user_followers`, `mutual_follows`, `find_reposts`, `follow_list`, `follow_lists`,
`parameterized_replaceable_list`, `parametrized_replaceable_event(s)`, `check_filterlist`,
`is_hidden_by_content_moderation`, `get_app_settings(_2)` (membership `app_settings`, the
accessed_at/log writes and the stored default), `user_of_ln_address`,
`set_last_time_user_was_online`, `report_user/note`, `relays`, `trusted_users`, `client_config`,
`network_stats`, `articles_stats`, `drafts`, `top_article`, `long_form_content_thread_view`,
`user_profile_scored_media_thumbnails`, `get_highlights`, `get_suggested_users_2`, `feed_2`,
`feed_directive_2`, and — through the port of Julia's in-memory `response_messages_for_posts`
(`Handlers.Rmfp`: events, stats, media, relays, top-five zaps, referenced events three levels
deep via e/a tags and nostr: mentions, metadata, viewer actions, verified names) —
`enrich_feed_events` and `note_mentions`. Against the reference: `event_actions` 100 %,
`get_highlights`, `mutual_follows`, `user_followers`, `parametrized_replaceable_event` ≥ 95 %,
`get_directmsg_contacts` and `note_mentions` 85 % (the csam deviation and viewers whose compiled
rules differ from Julia's defaults), `explore_zaps` low on this host only because the Julia node's
`TrustRank.humaness_threshold` is 0.0 (it never loaded trust ranks) where we apply the real one.
**Phase 4d (2026-10-04):** advanced search is native (`Advsearch`): a parser equivalent to
dag.jl's PEG grammar (words, phrases, hashtags and their negations, since/until with the relative
names, from:/to:/@ with hex, npub, nprofile, naddr follow lists and verified names, kind:,
repliestokind:, post:root, note/nevent/naddr, filter:, url:, orientation:, min/maxduration:,
emoticons and ?, category:, min/maxinteractions:, scope:, min/maxwords:, maxchars:,
minlongreplies:, lang:, features:, ref:, zappedby:, orderby:, the min/max stats fields with
minscore:/maxscore: as percentiles of the 24-hour trending scores, mintrustrank:, pas:, OR and
parentheses), the `to_sql` builder (the same tables, CTEs and conditions, dynamic SQL run through
`Postgres.query` with text parameters), and `fetch_results`' windowed execution — one-hour windows
walking back from `until`, widened fourfold while empty, a nine-second budget, partial results on
a statement timeout — read through a no-scroll cursor exactly as Julia does: with a plain LIMIT the
planner bitmap-scans the whole `created_at` range of a wide window (six minutes for a rare word
over two years), with the cursor it starts from the GIN index (four seconds). Native on top of it:
`advanced_search` (default viewer = the primal account, the `!contentmoderationdemofeed:` canned
feeds, the pas:1 cap for non-members), `advanced_feed`, `parse_advanced_search_query`, and every
mega-feed id that Julia routes to a search query (`advsearch`, `nostr-reads-feed`, reads
`follows`/`myfollowsinteractions`, `video-reels`, `wide-net-notes`, `strange-but-popular`,
`engaging-discussions`, `only-tweets`, `bookmarked-by-follows`, `explore-media`, the
photos/short_videos/media `latest` feeds) plus `important-notes-i-might-have-missed`,
`muted-threads` and the non-notes `wide-net-notes` feed. Against the reference: `advanced_search`
1000/1000 identical, `mega_feed_directive` 97.3 % — the rest are Julia's nine-second budget
running out under the replay's load (identical when replayed alone).
**Phase 4e (2026-10-04):** the remaining readers are native: `search` (Julia forwards it over
HTTP to another node's `/api`; `search_api_url` names it), `explore_media`, `get_advanced_feeds`,
`get_filterlist` (the four curated lists of the membership `lists` table, the other Julia
in-process sets are empty on the API nodes), `get_recommended_reads` (three random articles of the
Nostr-Gems curation, `Bech32.encode_naddr`), `trending_images(_4h)` (hashtag whitelist, media of
the trending notes ordered by score × followers/posts), `get_dvm_feeds`, `get_featured_dvm_feeds`
and `dvm_feed_info` (the `response_messages_for_dvm_feeds` port: handler event, user infos, names,
likes/sats, the viewer's follows' and own actions, feed metadata; `primal_dvm_pubkeys` marks
Primal's own DVMs), and `nostr_stats` (NOTICE error, as Julia answers without its `daily_stats`
table). `top_article` now raises like Julia when the author has no article.
**Phase 4f (2026-10-04):** the settings write and the remaining non-media writes. The
content-moderation rule compiler moved from the importer into `Primal_common.Cmr` (parameterized
by the cache/membership connections and an event lookup; the importer keeps thin wrappers), so
`set_app_settings` is native (carry-over of stored keys the new event lacks, the `app_settings`
upsert, `notification_settings`, the cmr_* re-import — Julia compares the compiled rules by
identity and therefore always re-imports) and so is `search_filterlist` (allow list, muted-by
parent, the spam list, the algos user's mute list as the nsfw group via `algos_user_pubkey`).
Also native: `update_push_notification_token(_for_nip46)` (membership token tables),
`get_queued_events_for_nip46`, `events_nip46` (`monitoring_db`), `invoices_to_zap_receipts`,
`import_events` (the importer's import listener over `import_events_line_server`, plus the
`human_override` upsert) and `import_poll_vote_event`. Verified with a throwaway key against the
reference: identical settings read-back, cmr/notification/token rows as Julia writes them, identical
import status. **Phase 4g (2026-10-04):** the relay-facing funcalls. `broadcast_events` and `broadcast_reply`
publish through `Relay_broadcast` with Julia's semantics (every relay concurrently, the answer as
soon as one relay accepts or after 15 s, the replies received so far; `relay_proxy` is Julia's
SOCKS proxy). `dvm_feed` serves non-personalized feeds from the DVM checker's `dvm_feeds` cache and
otherwise runs the NIP-90 request itself: a kind-5300 job request signed with
`dvm_requester_seckey` (BIP340 signing now lives in `Primal_common.Nostr.create`), published on
`dvm_relays` plus the relay the handler event came from, the first kind-6300 result (or 7000
error) referencing it within `timeout` seconds; the mega-feed `{"dvm_pubkey","dvm_id"}` spec routes
there. Verified against the reference: identical broadcast status, identical cached DVM feeds
through the mega spec, a live personalized feed answered in 12 s. Still proxied: the uploads
(Phase 5/8) and the membership funcalls of `ext/App.jl` (private repo, Phase 9).

**Phase 5 (2026-10-04):** the HTTP services (ocaml-plan.md §5.5), as shadow listeners next to the
Julia node's: `Internal_http` on `internal_http_port` (14000+N) is InternalServices route for
route — `/collect_metadata`, `/.well-known/nostr.json` (Julia's two-space JSON, `Jsonfmt`),
`/media-upload`, `/media-cache`, `/link-preview` (link-preview.py in OCaml over `Http.request`;
disabled like Julia's while `download_proxies` is empty), `/url-shortening` and `/url-lookup/*`
(membership `short_urls`), `/spam`, `/api` (the funcall dispatcher with `subid` "http"; proxied
names and `server_name` go to `upstream_julia_http`), `/api/suggestions(_2)`, the well-known
static files, and the catch-all preview_handler (index.html per Host from `index_dirs` with the
OpenGraph/twitter metas of profiles, notes, articles, live events and the static pages). Every
route's status, headers and body were compared with the Julia node's: identical except where
noted below. `Moderation_http` on `moderation_http_port` (24000+N): `/purge-media` (purge_media_
step for step — media_block record, local roots moved into cdn-hidden/, `S3` providers backed up
to bucket2 and deleted, Cloudflare cache purge, the media_storage/media_uploads/short_urls rows
marked) and `/pre-sign-urls`; `Primal_common.S3` is a SigV4 client (check, delete, copy, upload,
get, pre-signed GET; the AWS documentation vector is a unit test). Blossom is not part of primal-api: production serves blossom.primal.net from the media host (`ocaml-jobs` role `blossom`, a port of primal-blossom-server).

**Cutover A (2026-10-04 09:45 UTC, host <stage-host>):** `primal-api` serves port 9001 on this host and the
ws-connector that held it (started 2026-09-30 in tmux pane 0:19.1 from `<tmp>/ws-connector`) is
stopped (its tmux pane ran a relaunch loop: the first stop was followed by a silent respawn that
shared 9001 with primal-api for 48 minutes; the loop was interrupted at 10:32 — check
`ss -ltnp | grep :9001` after every change). This host's 9001 is the endpoint used by dev.primal.net (about two thousand connections in
five days, one at a time), not one of the public cache hosts of `deploy.sh` (<production-host>, <production-host>, <production-host>), so
it is the low-risk first host of the plan's one-week soak (until 2026-10-11). `cutover-9001.sh` is
the script that was run; its header has the rollback (restore the config backup, roll back to 9006,
relaunch ws-connector with its original command line). Soak check: a reference ws-connector runs on 9007 (transient user unit
`primal-wsconn-ref-9007`, same binary and arguments), so `primalctl replay ... --a
ws://127.0.0.1:9007 --b ws://127.0.0.1:9001` compares the pre-cutover behaviour with primal-api
(99.8 % on the first 535 requests after the switch; Julia direct is not the right reference for
the 3a funcalls, which mirror ws-connector by design). Known gap: primal-api
does not read `/tmp/wsconn_blocked`, the flag `deploy.sh` sets while it restarts Julia; proxied
funcalls fail for that window, native ones keep working.

**Phase 10 on <stage-host> (2026-10-05 00:13 UTC):** the production binary here is the private build
`ocaml-ext/bin/primal_apid.exe` (`PRIMAL_EXE=... ./rebuild-restart-api.sh`; `ext.crash_report_file`
set, no Studio on this host). Julia API node 17 is retired (its `m1_cache.sh` loop in tmux pane 0:0.0
was killed, then `["EVAL","exit()"]` on 12017); `primal-api` now also binds its ports: `cache_ws_port`
8817 (the same WebSocket service; `user_infos` probes answer), `internal_http_port` 14017,
`moderation_http_port` 24017 (the Blossom listener 21017 was dropped on 2026-10-05: Blossom is the media host's service, `ocaml-jobs` role `blossom`). The few funcalls still proxied (uploads,
membership purchase/status, wallet) go to <julia-host>'s Julia node (`upstream_julia_ws`
ws://<julia-host>:8831, `upstream_julia_http` http://<julia-host>:14031/api). The ws-connector
shadows on 9005 and 9007 are stopped (their upstream was node 17). Replay before the switch (12 per
funcall, 696 requests, new binary vs ws-connector→Julia): 92.4 % identical, every difference a known
one (`get_notifications`, `get_featured_dvm_feeds`, live counters, two slow-feed timeouts) or a Julia
node-17 quirk (`explore_legend_counts` all_users = 2; `follow_lists` wrapped in an
`event_media_response` object). Rollback: restore `primal-api-config.json.bak-20261005000625-pre-phase10`,
start `bash ../m1_cache.sh` again in a tmux pane, rerun the restart script. The public hosts
(<production-host>/<production-host>/<production-host>) and <julia-host> keep Julia + ws-connector by decision.

## Build / run

```sh
C=$(git rev-parse --show-toplevel)/ocaml-common   # the shared toolchain flake
nix develop "path:$C" -c dune build @all        # whole workspace; _build/ is at the repo root
nix develop "path:$C" -c dune test
./rebuild-restart-api.sh                        # build + rolling restart (see below)
```

Binaries: `_build/default/ocaml-api/bin/primal_apid.exe <config.json>` (the daemon) and
`primalctl.exe` (operator CLI).

## Configuration (`$PRIMAL_CONFIG_DIR/primal-api-config.json`, every key required)

| Key | Example | Purpose |
|---|---|---|
| `servername` | `"wscm"` | answered by `server_name` (ws-connector `--servername`) |
| `public_ws_host` / `public_ws_port` | `"0.0.0.0"` / `9006` | the cache API WebSocket (9001 in production) |
| `cache_ws_port` | `8817` or `null` | the Julia CacheServer port (8800+N): the same WebSocket service for health probes (`monitor-cache-server.sh`) and cross-node calls; `null` while a Julia node holds it |
| `admin_host` / `admin_port` | `"127.0.0.1"` / `14006` | admin HTTP (below) |
| `num_domains` | `4` | worker domains; each runs an accept loop on the shared SO_REUSEPORT socket |
| `upstream_julia_ws` | `"ws://127.0.0.1:8817"` | fallback proxy target for everything not handled natively |
| `upstream_connect_timeout_s` | `10.0` | |
| `idle_connection_timeout_s` | `600.0` | close a client idle for 0.95–1.0 × this (ws-connector parity) |
| `ws_max_message_bytes` | `1048576` | inbound message cap (close 1009) |
| `ws_outbound_queue` | `256` | frames queued per connection before the sender blocks |
| `ws_send_stall_s` | `15.0` | a frame not flushed within this closes the socket (WSConnUnblocker parity) |
| `drain_grace_s` / `drain_ws_max_s` | `30.0` / `900.0` | rolling restart: idle WS closed at once, active after grace, all by the hard deadline |
| `status_interval_s` | `10.0` | status line period (0 = off) |
| `log_handled` / `log_not_handled` | `false` | per-request log lines (ws-connector `--log-handled` / `--log-not-handled`) |
| `request_concurrency` | `8` on <stage-host> | REQs of one connection handled at once. `1` = strictly in order like ws-connector and Julia, where one slow feed delays every later answer on that socket (a profile header waited 10 s behind the reads feed). >1 runs REQs in fibers (semaphore-bounded; `set_primal_protocol`, CLOSE and forwarded messages stay in order). |
| `anon_feed_cache_s` | `30.0` on <stage-host> | `mega_feed_directive` / `multi_kind_mega_feed_directive` pages answered for the anonymous default pubkey are reused for this long (`0` = off; one computation per key, concurrent misses wait for it; `/status` shows hits/misses/entries). Every logged-out visitor asks the identical feeds on every route. |
| `cache_db` / `membership_db` | `{host,port,user,database}` | per-domain PGOCaml pools (cache: statement_timeout 30 s) |
| `cache_pool_size` / `membership_pool_size` | `4` / `2` | connections per worker domain (<stage-host> runs `cache_pool_size` 16 since 2026-10-05 20:44: a logged-in page load fires ~20 REQs at once and the reads feed held all 4) |
| `content_moderation_root` | path | `default-settings.json`, `app-releases.json` (mtime-cached) |
| `primal_pubkey` | hex | default `user_pubkey` for handlers (ws-connector constant) |
| `request_log` | path or `null` | JSONL `{t,time,funcall,kwargs,ws,subid}` of handled requests slower than `wsconnvars.metrics_logging_min_request_duration`, when `metrics_logging_enabled` (the replay corpus format) |
| `live_events_enabled` | `true` | run the live-event distributor on the main domain |
| `wsconnvars_poll_s` | `1.0` | poll period of the `wsconnvars` table (idle timeout, logging knobs) |
| `network_stats_url` | `"http://127.0.0.1:14018/api"` or `null` | `App.NETWORK_STATS_URL`: where `net_stats` pushes are fetched from (the importer node's HTTP `/api`) |
| `netstats_period_s` | `2.0` | `1 / CacheServerHandlers.NETSTATS_RATE` |
| `trending_blocked_domains` | `["bchnostr.com"]` | `App.TRENDING_BLOCKED_DOMAINS`: nip05 domains hidden from trending/explore |
| `search_api_url` | `"http://<search-host>:14017/api"` or `null` | `App.search` forwards the call to this HTTP `/api` (null: NOTICE error) |
| `primal_dvm_pubkeys` | `[]` | hex pubkeys of Primal's own DVMs (`DVMServiceProvider.keypairs`): `is_primal` in DVM feed metadata |
| `import_events_line_server` | `{"host":"127.0.0.1","port":12118}` or `null` | `App.IMPORT_EVENTS_LINE_SERVER`: the importer's import listener; null answers `import_events` with nothing |
| `algos_user_pubkey` | hex or `null` | `App.ALGOS_USER.pk`: the account whose mute list is the `primal_nsfw` group (`search_filterlist`) |
| `monitoring_db` | `{"host","port","user","database"}` or `null` | `events_nip46` reads `monitoring_events` there (null: NOTICE error) |
| `relay_proxy` | `"socks5h://<socks-proxy-host>:1080"` or `null` | SOCKS5 proxy for outbound relay connections (`Main.PROXY`) |
| `dvm_relays` | `["wss://relay.primal.net", ...]` | `DVMFeedChecker.RELAYS`: where DVM job requests are published |
| `dvm_requester_seckey` | hex or `null` | `App.DVM_REQUESTER_KEYPAIR`: signs the kind-5300 job requests (null: `dvm_feed` live path answers NOTICE error) |
| `internal_http_port` | `14096` (14017 at cutover) | InternalServices router (14000+N) |
| `moderation_http_port` | `24096` (24017 at cutover) | `/purge-media`, `/pre-sign-urls` (24000+N) |
| `upstream_julia_http` | `"http://127.0.0.1:14017/api"` or `null` | HTTP `/api` forwards funcalls that are still proxied (and `server_name`) there |
| `index_dirs` | `{"primal.net": "/var/www/dev.primal.net", ...}` | Host -> directory of the web app's index.html (preview_handler); other hosts answer 404 |
| `url_shortening_root_url` | `"https://m.primal.net"` | `InternalServices.URL_SHORTENING_ROOT_URL` |
| `download_proxies` | `[]` | `Media.DOWNLOAD_PROXIES` for `/link-preview` (`"null"` = direct); empty disables previews, as in Julia |
| `s3_providers` | `[{"name","endpoint","region","bucket","bucket2","access_key","secret_key","domain"}]` | `Main.S3_CONFIGS` |
| `cloudflare` | `{"zone_id","api_key"}` or `null` | cache purge of the cloudflare providers' domains |
| `media_paths` | `[{"type":"local","label","root"} \| {"type":"s3","provider","label"}]` | the roots a purge walks (`Media.MEDIA_PATHS(_2)`); `label` is the media_storage provider name |

## Request log on <stage-host> (stage.primal.net)

Since 2026-10-05 17:10 UTC the API records every request (`wsconnvars.metrics_logging_min_request_duration = 0`;
the ws-connector default was 2.0 s, i.e. slow calls only) to `$PRIMAL_VAR_DIR/metrics-wsconn.log`, the
input format of `primalctl replay`. stage.primal.net is <edge-proxy>'s nginx proxying `/` to <stage-host>:9001 and `/api` to
<stage-host>:14017, so this is the stage webapp's traffic. To replay a day against <julia-host>'s Julia:
`primalctl replay $PRIMAL_VAR_DIR/metrics-wsconn.log --a ws://127.0.0.1:9001 --b ws://<julia-host>:8831 --all --report /tmp/r.jsonl`.
Restore the threshold with `update wsconnvars set value = '2.0' where name = 'metrics_logging_min_request_duration'`.

**Stage replay 2026-10-05 (same data, shadow 9009 over <julia-host>'s DB vs Julia 8831):** the stage webapp's 99
requests of one page load were 81 % identical; the differences were `get_notifications` with no results
(fixed: the SQL enrichment now runs on an empty list too, emitting the empty elements message as Julia),
`get_recommended_reads` (three random articles on both sides), `explore_legend_counts` (`all_users`, known),
`live_events_from_follows` (<julia-host>'s older Julia lacks it) and the empty-spec `multi_kind_mega_feed_directive`
poll (both sides answer a notice: "invalid spec format" here, "error" there). `explore_media` takes 2–9 s on
<stage-host>'s database against 0.6 s on <julia-host>'s with the same code: a <stage-host> data/plan matter, not the port.

**Headless-browser check 2026-10-05 (the "empty home / no trending / empty reads" report):** the API
answered every replayed request correctly, yet the webapp against stage rendered nothing. Driving the real
primal.net build in a headless Chromium (`nix shell nixpkgs#chromium` + python playwright, cache server via
`localStorage.cacheServer`, see `ocaml-common/README.md`) showed the cause: the webapp opens the cache
socket with a burst of 15–20 REQs in one TCP write, and httpun-ws 0.2.0 delivered only the first two frames
of such a read to the session, leaving the rest queued until the client sent more bytes (the feeds were
answered 24 s later, when the page navigated away). A raw-socket client reproduced it deterministically
(3+ frames in one write → the third never answered; with 20 ms gaps all answered). Fixed by
`ocaml-common/patches/httpun-ws-frame-queue.patch` (`Websocket_connection._next_read_operation` now drains
every already-complete frame), regression test "ws burst" in `ocaml-common/test`. After the roll the
headless walk over /home (with paging), /reads and /explore renders the same counts against stage as
against cache2. Lesson: replaying requests one at a time cannot see transport-level bugs; keep the
headless walk (``ocaml-api/tools/webapp-walk.py` (NSEC_FILE for a logged-in session), run through `tools/playwright.sh`, compared with `tools/webapp-compare.py`; `tools/ws-burst.py` is the raw-socket reproducer; `tools/ws-direct.py` and `tools/ws-head-of-line.py` (via `tools/websockets.sh`) time single requests and the per-connection ordering; `tools/advsearch-windows.py` replays a windowed search through psql) as the
acceptance check for a cutover.

**Logged-in walk 2026-10-05 20:00 (QA user via `NSEC_FILE`, pages home/reads/explore/notifications/messages/
bookmarks):** every page renders against stage as against cache2; the 253 requests of the walk replayed on the
same data (shadow 9009 over <julia-host>'s DB vs Julia 8831) are 91.7 % identical, the rest being the trending feed's
drifting follower-count batches, `get_recommended_reads` (random), `live_events_from_follows` (<julia-host>'s Julia)
and `get_notifications` differing only in the one-second `since/until` stamp. Two stage-only observations are
data, not the port: stage's notifications start with live-stream notifications (type 501) because <stage-host>'s
Julia pg listener keeps writing them (8934 rows for the QA user, 1–4 a day; <julia-host>'s stopped 2025-09-24),
and a logged-in home/reads page load fires ~20 REQs at once, so the reads feed's windowed search (6–11 s on
<stage-host> with `until` paging) holds the 4-connection pool and trivial calls queue behind it for up to 15 s
(`get_app_settings` 15.7 s, `get_featured_dvm_feeds` 19 s on /explore); same requests alone: 0.1–3 s.
With `cache_pool_size` 16 (20:44) the rerun shows no queueing: home feed 0.4 s (was 9.8 s), settings calls
0.2–0.7 s, /explore timings equal to production's (6–8 s there too), no pool timeouts. What remains is the reads
feed query itself on <stage-host>'s database: 1.4–9.2 s for the same request, and the `until` pages hit the 9 s
window deadline and come back partial (88 events, page 2 unanswered) where production answers in 1.3 s; on
<julia-host>'s data the OCaml and Julia timings are equal (1.95 s vs 1.99 s), so it is <stage-host>'s plan/data.
EXPLAIN of one window (`primalctl advsearch-sql <user> "kind:30023 scope:myfollowsinteractions minwords:100
features:summary" <since> <until>` → `explain (analyze, buffers) declare cur no scroll cursor for ...`): the plan
is the same on both hosts (reads by published_at backwards, advsearch by id per row, the scope subplans), 98 ms
warm / 2.7 s cold on <stage-host> for a 64 h window, 170 ms on <julia-host>. The time goes into the number of windows: <stage-host>
imported no kind-30023 events between early August and 2026-09-29 (0 per sampled hour vs 60–420 on <julia-host>), so
its `reads` table has 20 articles for that month against <julia-host>'s 83k; the search walks back through the empty
weeks (window 1h→4h→…→4096h) and the last, 170-day window eats the 9 s deadline. Not the port: the fix is to
import the missing long-form events into <stage-host> (the DAG's reads node covers by imported_at and will pick them up).
Done 2026-10-06 01:30–02:35 UTC with `ocaml-importer/tools/backfill-events.py` (kind 30023, created_at
2026-07-13..2026-09-30 from <julia-host> through the import listener): 274,902 imported, 6,221 duplicates, 1,719
rejected; the DAG's reads node filled the weeks within minutes (<stage-host>'s weekly `reads` counts now equal <julia-host>'s).
After it (cache warm) the QA user's reads page answers in 2.0 s / page 2 in 1.8 s on <stage-host>, as on <julia-host>'s Julia
(2.1 / 2.0 s); the first cold runs still took 5–9 s while the freshly written rows were read from disk.
**The gap is wider than long-form:** <stage-host> imported no events of ANY kind between about 2026-07-11 and
2026-09-29 (0 per sampled noon hour vs 25k on <julia-host>; 538k in the 2026-07-10 hour, then nothing until 142k on
09-30). Notes, profiles, reactions, zaps and relay lists of those eleven weeks are missing on the stage host,
which is why its feed answers carry fewer profile/relay-list messages than <julia-host>'s for the same request. A full
backfill is ~100M events and needs a database-level copy, not the import listener (~60 events/s).

**Concurrent requests per connection (2026-10-06 03:26, <stage-host> `request_concurrency` 8):** the webapp opens a
socket per route and asks for the home and reads feeds before the page's own calls, and ws-connector/Julia
answer in order, so a profile header waited 10 s behind the reads feed on stage. `Conn` now runs REQs in
fibers (semaphore-bounded; `set_primal_protocol`, CLOSE and forwarded messages stay in order). Same socket,
reads feed first then the five profile calls: <stage-host> answers the profile calls at 0.06 s and the feed at 0.97 s;
Julia answers nothing before the feed (1.17 s) and the profile calls at 1.24–1.49 s.

**Anonymous feed cache (2026-10-06 03:37, <stage-host> `anon_feed_cache_s` 30):** the anonymous reads feed answers in
0.9 s once per 30 s and 0.1 s for every other logged-out visitor in between (`/status` → `anon_feed_cache`
hits/misses); logged-in feeds are untouched. Fresh entries are answered inline on the reader, without a
`request_concurrency` slot, so a hit is not queued behind the page's burst (03:43: the reads page's feed answered
in 0.2 s instead of 1.1 s). The first `until`-paged reads pages for the anonymous network are still slow on <stage-host>
(cold windows), the cache only removes the repeats; the TTL runs from the computation, hits do not extend it.

**Profile media tab (2026-10-06):** the webapp's media grid asks `mega_feed_directive` with spec
`{"id":"feed","kind":"notes","notes":"user_media_thumbnails","pubkey":…}`; `feed_with` knew only follows/authored/
replies and forwarded it to the Julia upstream (which never compresses: 499 KB per page instead of 141 KB, and
stage depended on <julia-host> for it). It now goes to the native `feed_2`; the four-request media corpus is identical
to Julia on the same data. A page is 449 messages for 20 thumbnails (media metadata 177 KB, zap receipts 152 KB,
profiles 58 KB raw); a thumbnails-only enrichment would need a client-side opt-in, so it is not done.

**Formerly proxied requests, native since 2026-10-06 (commit 038628f):** the bookmarks feed (`notes:
"bookmarks"` in `feed`, `mega_feed_directive`, `multi_kind_mega_feed_directive`; the e/a tags of the user's
kind-10003 list, only ids known to `event_created_at`, as Julia), `events` without `extended_response`, and
`membership_content_stats`, `membership_content_backup` (get_user_events: replaceable kinds reduced to their
latest), `membership_recovery_contact_lists`, `membership_recover_contact_list` (a no-op in Julia too),
`membership_content_rebroadcast_start/status/cancel` (rows of `event_rebroadcasting`; the engine is
ocaml-jobs' rebroadcast role), `membership_legends_leaderboard`, `membership_premium_leaderboard`,
`membership_media_management_uploads`, `membership_media_management_delete` (purges through the API's own
moderation listener, then recomputes `used_storage`). Same-data replay against Julia: 12/13 identical; the
one difference is a `{pubkey: 0}` follower-count message for a leaderboard user without data that Julia
omits. A 300-event backup is the same set in a different order (ties on `created_at`). `primalctl sign
<nsec-file> <kind> <content> [tags]` makes the signed `event_from_user` such corpora need.
Still forwarded: `upload`, `upload_chunk`, `upload_complete`, `upload_cancel` (the legacy chunked upload path,
`app_media.jl`; no current webapp caller) and the edge cases listed under conditional hand-backs (a hidden
profile's `search_filterlist`, `feed` for a user without a followers row, unknown feed directive strings).

## Admin HTTP (127.0.0.1:`admin_port`)

`GET /healthz`, `GET /readyz` (503 unless serving — the load balancer / restart script gate),
`GET /status` (JSON: pid, state, uptime, connections), `GET /metrics` (Prometheus text),
`GET /tasks` (fiber phase registry, the pgwire `select * from tasks` replacement),
`POST /drain` (same as SIGUSR1).

## Rolling restart (`rebuild-restart-api.sh`, ocaml-plan.md §6)

Build → start a NEW generation as transient unit `primal-ocaml-api-<timestamp>` next to the running
one (SO_REUSEPORT: both hold the ports, the kernel balances new connections) → poll `/status` until
the new pid reports `serving` → `SIGUSR1` the old generation(s), which close their listening
socket in every domain at once (the kernel then routes every new connection to the new
generation; before 2026-10-04 the socket stayed open through the grace period and the old
binary kept serving a share of new connections), finish in-flight requests, close idle WebSockets, close the rest after `drain_grace_s` and exit → SIGKILL
stragglers after `drain_grace_s + drain_ws_max_s`. A broken build or a new generation that does not
become ready leaves the old one untouched. Logs append to `$PRIMAL_VAR_DIR/ocaml-api.log`;
`PRIMAL_EXE` / `PRIMAL_API_CONFIG` override the binary and config (used by the private `ocaml-ext`
wrappers).

## primalctl

```sh
primalctl req ws://127.0.0.1:9006 server_name                 # one request, frames printed until EOSE
primalctl req ws://127.0.0.1:9006 user_infos '{"pubkeys":["<hex>"]}' --zlib   # zlib mode (frames inflated)
primalctl status|metrics|drain [http://127.0.0.1:14006]
primalctl replay $PRIMAL_CONFIG_DIR/requests-sample-2.jsonl --per-funcall 300 --workers 6 \
         --report mismatches.jsonl          # parity of 9006 against 9001 over a request corpus
```

`replay` is the parity gate of ocaml-plan.md §12: every corpus line (`{t,funcall,kwargs,ws,subid}`,
the request-log format) is sent to A (`--a`, default the production ws-connector on 9001) and B
(`--b`, default the shadow on 9006) and the answers are compared as multisets of canonical messages
(sorted keys, JSON-in-strings canonicalised, integral floats as ints). Only read-only funcalls are
replayed, by default only the natively answered ones (`--all` adds the proxied ones, `--only a,b`
restricts); each worker keeps one connection per side and sends CLOSE after EOSE like a client
(Julia caps open subscriptions per connection). The table lists per funcall: total, identical,
percentage, timeouts per side, median latency per side; `--report` writes every mismatch with the
kwargs and up to three messages only one side produced.

## Layout

`lib/config.ml`, `lib/protocol.ml` (REQ/CLOSE parsing, EVENT/EVENTS/NOTICE/EOSE framing, zlib),
`lib/funcall.ml` (the closed variant of native funcall names + exhaustive dispatcher),
`lib/handlers.ml` (one function per funcall; ws-connector semantics for the 3a set, app.jl /
app_ext.jl semantics for the rest), `lib/moderation.ml` (content_moderation_filtering_2),
`lib/kw.ml` (typed kwargs),
`lib/response.ml`, `lib/queries.ml` (every cache-DB statement, `[%pgsql]`-checked against primal1),
`lib_membership/queries_mem.ml` (membership statements, checked against `primal_membership_ref`),
`lib_db/db.ml` (per-domain pools, phantom-tagged handles), `lib/live_events.ml` (subscription
registry + poll/LISTEN distributor), `lib/broadcasts.ml` (the periodic push subscriptions), `lib/wsconnvars.ml` (operator knobs + request log),
`lib/conn.ml` (one client connection: native dispatch + upstream proxy + idle timer + registry for
drain), `lib/admin.ml`, `lib/stats.ml`, `lib/files.ml`, `bin/primal_apid.ml`, `bin/primalctl.ml`. The server kernel
(`Http_server` on httpun-eio/httpun-ws, `Listen`, `Lifecycle`, `Ws_client`, `Zlib_util`) lives in
`../ocaml-common`.

## Notes

- zlib frames inflate to exactly the ws-connector/Julia body but are not byte-identical to
  ws-connector's (flate2 may emit stored blocks; zlib emits compressed ones). Clients only inflate.
- Shadow port 9006 was chosen because 9005 is occupied by the `ocaml-handlers` ws-connector instance.
- Julia reports every handler error as NOTICE "error" (CacheServerHandlers does not unwrap the
  TaskFailedException), so the 3b handlers answer `Notice "error"` wherever app.jl raises; a
  malformed kwarg is `Not_handled` and the upstream produces Julia's own NOTICE.
- Lessons from the ocaml-handlers SQL (sql/new_functions.sql): notification type 5 is
  YOUR_POST_WAS_REPOSTED (mentions are 8); `response_messages_for_post(..., depth 0)` returns
  nothing; `response_messages_for_list` has an array bug; `follow_lists(a_pubkey)` is not Julia's
  follow_lists; `user_profile` lacks the zap/media counts. Those were re-written as plain statements.
- `primal_verified_names` in Julia also appends `user_blossom_servers`; Julia's in-memory
  `event_media_response` omits `"mt"` when a resource has no variants (SQL emits null) — see
  `Handlers.verified_names` / `strip_null_mt`.
- Content moderation for a viewer: Julia compiles the viewer's app settings (deep-merged over the
  defaults) on every request; the importer materialises those rules into the `cmr_*` tables for
  only about half of the users with settings (218k of 412k). `Moderation.viewer_rules` therefore
  uses the SQL predicate when compiled rules exist, hides nothing when the settings switch
  moderation off, and applies Julia's default rules (spam in content+trending, nsfw in trending,
  the viewer's follows exempt from spam) otherwise and for requests without a viewer.
- Advanced search's `minscore:`/`maxscore:` percentiles index the sorted `score24h` values of the
  global trending top 300 of the last 24 hours; Julia recomputes them in its precalculation job,
  primal-api caches them for ten minutes (`Handlers.trending_24h_scores`). `Advsearch.run` sets
  `statement_timeout` per window on the pooled connection and restores 30 s afterwards.
- `follow_lists` in Julia appends the media responses as `select * from event_media_response(id)`
  rows, which serialise as `{"event_media_response": {...}}` (no `kind`); primal-api emits the
  proper media response message, so a replay shows every follow_lists answer as different.
- `get_queued_events_for_nip46`: Julia queries a `remote_signer_pubkey` column that the production
  `monitoring_request_queue` table does not have (it is `service_pubkey`), so Julia always answers
  NOTICE error; primal-api uses the real column. `search_filterlist`: the running Julia node omits
  the metadata event that app.jl's source emits next to the allow/block reason; primal-api follows
  the source.
- `broadcast_events`: Julia's per-request time budget adds a PARTIAL_RESPONSE marker when every relay
  is unreachable for the full 15 s; primal-api answers the same status without the marker. The
  running Julia node answers the direct `dvm_feed` funcall with NOTICE error (through the mega-feed
  spec it works); primal-api serves both.
- HTTP services vs the Julia node: the index.html is rewritten textually, so the page has no XML
  prolog and keeps the original markup (Julia serialised through libxml2); the meta elements are
  identical. An unknown Host answers 404 (Julia: 500 KeyError). `/.well-known/assetlinks.json`
  is served from the content-moderation root (the Julia API node has a relative path there and
  answers 500). `/spam` lists Julia's in-process sets, whose order is hash order; `/api`
  `server_name` is forwarded because Julia answers `{server, node}` there and ws-connector's name
  on the WebSocket. `broadcast_events` over HTTP has no PARTIAL_RESPONSE marker.
- Deliberate deviations from Julia, kept because the OCaml answer is the better one: accounts on
  the csam/impersonation filterlist are hidden by the SQL predicate (Julia's
  `content_moderation_filtering_2` only knows the spam/nsfw groups, so Julia still lists them in
  `user_scores` and zap lists); a `pubkey_notifications`/`event_stats` row pointing at a purged
  event makes Julia raise (NOTICE "error") where we answer with the remaining rows; Julia's
  per-request time budget can cut a large `contact_list` with a PARTIAL_RESPONSE marker where we
  answer in full.
