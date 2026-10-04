# primal-api

The Primal cache API daemon in OCaml 5 / Eio (`ocaml-plan.md` §5): the WebSocket cache API that
clients reach on port 9001 (and the per-node 8800+N ports), later the HTTP services (14000+N,
24000+N, Blossom 21000+N). It replaces the Rust `ws-connector` and the Julia `CacheServer`,
`InternalServices` and `Blossom`.

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
**Cutover A (2026-10-04 09:45 UTC, host <stage-host>):** `primal-api` serves port 9001 on this host and the
ws-connector that held it (started 2026-09-30 in tmux pane 0:19.1 from `<tmp>/ws-connector`) is
stopped. This host's 9001 is the endpoint used by dev.primal.net (about two thousand connections in
five days, one at a time), not one of the public cache hosts of `deploy.sh` (<production-host>, <production-host>, <production-host>), so
it is the low-risk first host of the plan's one-week soak (until 2026-10-11). `cutover-9001.sh` is
the script that was run; its header has the rollback (restore the config backup, roll back to 9006,
relaunch ws-connector with its original command line). Soak check: `primalctl replay ... --a
ws://127.0.0.1:8817 --b ws://127.0.0.1:9001` (Julia direct vs primal-api). Known gap: primal-api
does not read `/tmp/wsconn_blocked`, the flag `deploy.sh` sets while it restarts Julia; proxied
funcalls fail for that window, native ones keep working.

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
| `cache_db` / `membership_db` | `{host,port,user,database}` | per-domain PGOCaml pools (cache: statement_timeout 30 s) |
| `cache_pool_size` / `membership_pool_size` | `4` / `2` | connections per worker domain |
| `content_moderation_root` | path | `default-settings.json`, `app-releases.json` (mtime-cached) |
| `primal_pubkey` | hex | default `user_pubkey` for handlers (ws-connector constant) |
| `request_log` | path or `null` | JSONL `{t,time,funcall,kwargs,ws,subid}` of handled requests slower than `wsconnvars.metrics_logging_min_request_duration`, when `metrics_logging_enabled` (the replay corpus format) |
| `live_events_enabled` | `true` | run the live-event distributor on the main domain |
| `wsconnvars_poll_s` | `1.0` | poll period of the `wsconnvars` table (idle timeout, logging knobs) |

## Admin HTTP (127.0.0.1:`admin_port`)

`GET /healthz`, `GET /readyz` (503 unless serving — the load balancer / restart script gate),
`GET /status` (JSON: pid, state, uptime, connections), `GET /metrics` (Prometheus text),
`GET /tasks` (fiber phase registry, the pgwire `select * from tasks` replacement),
`POST /drain` (same as SIGUSR1).

## Rolling restart (`rebuild-restart-api.sh`, ocaml-plan.md §6)

Build → start a NEW generation as transient unit `primal-ocaml-api-<timestamp>` next to the running
one (SO_REUSEPORT: both hold the ports, the kernel balances new connections) → poll `/status` until
the new pid reports `serving` → `SIGUSR1` the old generation(s), which stop accepting, finish
in-flight requests, close idle WebSockets, close the rest after `drain_grace_s` and exit → SIGKILL
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
registry + poll/LISTEN distributor), `lib/wsconnvars.ml` (operator knobs + request log),
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
- Deliberate deviations from Julia, kept because the OCaml answer is the better one: accounts on
  the csam/impersonation filterlist are hidden by the SQL predicate (Julia's
  `content_moderation_filtering_2` only knows the spam/nsfw groups, so Julia still lists them in
  `user_scores` and zap lists); a `pubkey_notifications`/`event_stats` row pointing at a purged
  event makes Julia raise (NOTICE "error") where we answer with the remaining rows; Julia's
  per-request time budget can cut a large `contact_list` with a PARTIAL_RESPONSE marker where we
  answer in full.
