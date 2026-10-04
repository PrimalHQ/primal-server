# Plan: port everything in `primal-server` to OCaml 5 / Eio

Status: proposal v2 (2026-10-03). Replaces the earlier `ocaml-api-plan.md` (renamed and expanded).

End state: this repo contains OCaml, SQL, shell and config only. Every `.jl`, `.rs`, `Cargo.toml`,
`Project.toml`, Python helper and the Julia nix flake are deleted. Clients and peers keep using the
same ports and wire protocols. The reference stack is `ocaml-importer/` (already in production) and
`<config-dir>/tsunami-backend-scheduler/kernel/` ("tsunami kernel"), which runs the same
toolchain with httpun-eio/httpun-ws servers and script-driven rolling restarts (its task-queue
framework is not adopted: background jobs keep their current loop-based design, §2.5).

Projects after the port (all in one dune workspace, all built from `ocaml-common/flake.nix`):

| Directory | Daemon(s) | Replaces |
|---|---|---|
| `ocaml-common/` | library only | shared code from importer + new server kernel |
| `ocaml-api/` | `primal-api` | Julia CacheServer/App/InternalServices/Blossom, Rust ws-connector (+ws-handlers, ws-importer, ws-replay), `ocaml-handlers` |
| `ocaml-importer/` | `primal-importer` (exists) | Julia import path (done) + the Julia-only importer duties listed in §7 |
| `ocaml-fetcher/` | `primal-fetcher` | `fetching.jl`, `firehose_server.jl`, dedup storage |
| `ocaml-jobs/` | `primal-jobs` | DAGRunner, TrustRankMaker, `precalculate_analytics`, DVMFeedChecker, CacheStoragePgListener, EventRebroadcasting, DVMServiceProvider, membership failover, pg monitoring; media role: ProcessingGraph scheduler + Rust `primal-media` executor + MediaAnalysis + `import_upload_3` |
| `ocaml-api/bin/primalctl` | CLI | `rex`/EVAL ops, `code_load.jl` SQL deploy, `ws-replay`, `send-eval-request-to-julia.py` |
| `../ocaml-ext/` (**parent repo, private**) | `primal-api`, `primal-jobs`, `primal-importer` production binaries = public libs + private extensions | parent `src/app_studio.jl`, `studio_event_broadcasting.jl`, `sql/studio.sql`, `rss-content-importer/` (Rust), `studio/` (Rust stub), `user_content_purger.jl`, `media_analysis.jl`, `push_notifications.jl` intake, `ext/App.jl`, `ext/DB.jl`, `crash-report-handler.jl` |

Repository boundary rule: `primal-server` is public on GitHub, `primal-net-server` is private. Code
that lives in the private repo today is ported into `primal-net-server/ocaml-ext/` and never into
`primal-server/ocaml-*`. The public daemons expose registration points (§11.1) that the private
build fills in; the public repo still builds and runs on its own, without Studio.

Sections: 1 inventory · 2 decisions · 3 layout · 4 ocaml-common · 5 ocaml-api · 6 rolling restart ·
7 importer completion + control plane · 8 fetcher · 9 jobs · 10 media · 11 private extensions
(`ocaml-ext/`: Studio, purger, media analysis, push intake, membership/wallet funcalls) ·
12 testing · 13 phases · 14 risks · 15 deletion checklist.

---

## 1. Inventory summary (what runs today)

Per host `192.168.(10+srv).7`, node indices N ∈ {17, 18, 31–36}. On this box: Julia API node 17,
Julia importer node 18 (`start_media_importer_2.jl`, firehose import disabled, hosts the background
jobs), Julia fetcher (9017), OCaml importer (systemd), ws-connector :9001 (Rust handlers) and a
shadow ws-connector :9005 running `ocaml-handlers`.

### 1.1 Ports that must survive unchanged

| Port | Today | After |
|---|---|---|
| 9001 | ws-connector (SO_REUSEPORT) | `primal-api` public WS |
| 8800+N | Julia CacheServer WS | `primal-api` (health probes, `REPLICATE_TO_SERVERS`, cross-node calls) |
| 14000+N | InternalServices HTTP | `primal-api` |
| 24000+N | InternalServices media moderation HTTP | `primal-api` |
| 21000+N | Blossom HTTP (configured, Julia upload path broken at HEAD) | `primal-api` |
| 12000+N | FirehoseServer: `EVAL`/`EXPR` RCE + import | `primal-importer` import-only line listener (§7.2); no eval |
| 9000+N | fetcher firehose (127.0.0.1) | `primal-fetcher` same protocol (`STREAM-NEW-EVENTS`) |
| 14001 | ws-connector pgwire `tasks` | dropped; admin HTTP on 127.0.0.1 (§5.6) |
| 20000 | push-notification TCP intake (parent repo `push_notifications.jl`) | `primal-importer` built from `ocaml-ext` (§11.6) |
| 22000 | user-content-purger (parent repo) | `primal-jobs` built from `ocaml-ext`, `purger_http` role (§11.5) |
| 9091 | pushgateway target | unchanged; metric names preserved |

### 1.2 Request surface

- WS cache API: 139 sync + 7 async funcalls + `set_primal_protocol`; ws-connector adds `live_feed`,
  `live_events_from_follows`, `find_live_events`. Dead: `upload*` (4), async `notifications`.
  Non-`cache` filters: `{"ids"}`, `{"search","kinds":[0|1]}`, `{"since"/"until"}`.
- Framing: `EVENT*`+`EOSE`; zlib → one binary `["EVENTS",sub,[..]]` + text `EOSE`; `NOTICE`+`EOSE`
  on error; 200-subscription cap; 10 s budget with `PARTIAL_RESPONSE` (10000123) for
  `feed`/`get_notifications`; `content_moderation_filtering_2` unless `usepgfuncs`.
- HTTP 14000+N: `/collect_metadata`, `/.well-known/nostr.json`, `/media-upload`, `/media-cache`,
  `/link-preview`, `/url-shortening`, `/url-lookup/*`, `/spam`, `/api`, `/api/suggestions(_2)`,
  `/crash-report`, catch-all OpenGraph `preview_handler`. 24000+N: `/purge-media`, `/pre-sign-urls`.
  Blossom: BUD-01/02/04/05 with kind-24242 auth.
- Postgres: cache `127.0.0.1:54017/primal1` (`pr`), membership `<membership-db-host>:5432/primal`
  (`primal`) with failover via `http://<discovery-host>/discovery/postgres/membership/primary.json`
  + `pg_promote()`; `:p7` `<trace-db-host>/primal` (trace). All API SQL functions are `sql`/`plpgsql`
  in `sql/app.sql`; `pg_primal` is unused by current code; pg_cron holds 4 jobs; no non-SQL triggers.

### 1.3 Background systems (Julia/Rust) and their outputs

| System | Where | Period | Produces |
|---|---|---|---|
| Fetcher | `fetching.jl` (378) + firehose + dedup | continuous, ~8k relays | firehose 9017; `dedup/messages/YYYY/MM/DD.log` (467 GB archive); per-relay `latest_timestamp` |
| DAGRunner, 13 nodes | `dag.jl` (4487), `dag_runner.jl` | 5 s loop, 1 d / 90 d segments, `coverages_1_8656fc443b` | `basic_tags_6_*`, `zap_receipts_1_*`, `poll_stats_1_*`/`poll_user_votes_1_*`, `a_tags_1_*`, `reads_12_*`/`reads_versions_12_*`, `pubkey_media_cnt_1_*`, `pubkey_content_zap_cnt_1_*`, `advsearch_5_*`, `event_mentions_1_*`, `note_length_1_*`, `note_stats_1_*`, `user_search` |
| TrustRankMaker | `trustrank_maker.jl` (413) | 3 h | `pubkey_trustrank` (table swap, 1.44M rows), `tr_sorted.jls` (write-only now) |
| `precalculate_analytics` | `app_ext.jl:672-773` + `scored_content` | 600 s | `cache` keys `precalculated_analytics_{trending,gm_trending,classic_trending,mostzapped}_{24h,12h,4h,1h}`, `_explore_topics`; Ollama "gaming" flag; HTML report via ssh |
| DVMFeedChecker | `dvm_feed_checker.jl` + `App.dvm_feed` | 600 s | `dvm_feeds` |
| CacheStoragePgListener | `cache_storage_pg_listener.jl` | LISTEN `cache_storage` | `LIVE_EVENT_HAPPENING` notifications |
| `expire_scores`, `run_scheduled_hooks` | `CacheStorage.periodic` | 60 s | `event_stats.score24h`, `hashtags.score` |
| `update_content_moderation_rules`, `update_user_search` | import hooks (Julia only) | per event | `cmr_*`, `user_search`, `pg_notify('primal_events')` kind 11000001 |
| EventRebroadcasting | `event_rebroadcasting.jl` | 1 s | membership `event_rebroadcasting` → relays |
| DVMServiceProvider | `dvm_service_provider.jl` | relay client | NIP-89/NIP-90 answers, `dvm_usage` |
| ProcessingGraph scheduler + Rust `primal-media` executor | `processing_graph*.jl`, `primal-media/` | 1 s tick | `processing_nodes` execution: media variants, previews, HLS, text events, uploads (`import_upload_3`), block/purge |
| MediaAnalysis | parent `media_analysis.jl` (814), `media_ai.jl` | inline on upload | `media_metadata`, `media_embedding`, CSAM/NSFW blocks, purger calls |
| Membership failover + PG monitoring | `postgres.jl:887-955` | 1 s / 15 s | `pg_promote()`, `postgres_*` metrics |
| Remote-eval control plane | `rexec_client.jl`, `code_load.jl`, `init-api-request-replication.jl` | ad hoc | `import_events` RPC, DAG output push, replication peers, SQL deploy, hot reload |
| Studio (private repo) | `app_studio.jl` (197), `studio_event_broadcasting.jl` (93), `sql/studio.sql` (682), Rust `rss-content-importer/` (589) | per request / 1 s / 120 s | `studio_operation` funcall, `studio.scheduled_events` + `rss_feed_items` broadcasting, RSS drafts |
| User content purger (private repo) | `user_content_purger.jl` (458) | HTTP :22000 | media purges, filterlist entries, Bunny purge |

Production runtime config is **not in the repo**: `<config-dir>/primalnode_config*.jl`
(pools, content-moderation files, keys, which subsystems start, `APP_ROOT`, DAG wiring,
`REPORTING_WHITELIST` pubkeys). Media-host and wallet-host configs live on other hosts.

### 1.4 Known gaps between Julia and the OCaml importer today (live bugs to fix in Phase 1)

- `expire_scores` is not ported: `score_expiry` fills (20k rows pending) and `score24h` never decays.
- `run_scheduled_hooks` runs in both Julia and OCaml (possible double decrement of hashtag scores).
- `update_user_search`, `update_content_moderation_rules`, `add_human_override` not ported.
- `CacheStoragePgListener` (live-event notifications) not ported.
- Importer has no inbound import RPC (the API's `import_events` goes through Julia `rex`).
- Membership DB auto-promotion exists only in Julia processes.

### 1.5 Toolchain facts (nixpkgs nixos-25.11 rev 03c72920, `ocamlPackages_5_3`)

Proven in tsunami kernel on this box: ocaml 5.3.0, dune 3.20, eio 1.3, pgocaml(+ppx) 4.4,
httpun / httpun-eio / httpun-ws / gluten / gluten-eio, tls-eio, mirage-crypto, digestif, yojson,
xmlm, secp256k1-internal, sqlite3, alcotest, ocaml-lsp, ocamlformat. In nixpkgs but unfetched:
camlzip, decompress, lambdasoup, markup, angstrom, uri, qcheck, ppx_expect, magic-mime. Absent:
cohttp-eio, ocaml-websocket, pgx, prometheus-app.

---

## 2. Design decisions

1. **Eio only, OCaml 5.3, no Lwt.** Blocking libc calls are banned (`Dns_eio`, `Eio.Process`).
2. **Every SQL statement is `[%pgsql]`-checked at build time**, against `primal1` for cache tables and
   against a schema-only clone of the membership DB for membership tables (dune per-directory env,
   §4.4). Dynamic SQL is confined to one typed query builder (advanced search) and the DAG
   coverage runner's table-name templating.
3. **Postgres does the work; OCaml orchestrates.** Where Julia computed in-process over `PSQLDict`s
   (analytics, trustrank graph walk, DAG nodes) the port uses set-based SQL or arrays, not row loops.
4. **One shared server kernel** (`ocaml-common/net`, `runtime`) copied and hardened from the tsunami
   kernel's `httpd.ml`, `ws_client.ml`, `pg.ml`, `pg_listen.ml`, `http.ml`, `socks5.ml`.
   Additions Primal needs that tsunami lacks: multi-domain accept, WS frame/message size caps,
   bounded outbound queues, zlib `EVENTS` frames, idle timeout, ping.
5. **Background jobs keep today's design.** No task-execution framework (tsunami's `sched` is not
   adopted). Each job is what it is in Julia: a supervised loop with a sleep (`DAGRunner` 5 s with
   its `coverages` table, TrustRankMaker 3 h, `precalculate_analytics` 600 s, DVMFeedChecker 600 s,
   rebroadcasting 1 s, Studio broadcasting 1 s), plus the existing `processing_nodes` scheduler tick
   for media. Same tables, same periods, same metrics; only the language changes.
6. **Incremental cutover with built-in fallbacks.** API: a fallback proxy to Julia for unported
   funcalls (closed variant that shrinks to empty). Jobs: each job is enabled per daemon by config,
   so a job moves from Julia to OCaml by flipping two flags.
7. **Rolling restart = tsunami's protocol** for the request-serving daemons (SO_REUSEPORT overlap +
   SIGUSR1 drain + script that only touches the old instance after the new one is verified), run
   under transient systemd user units like the importer. The jobs daemon does not overlap: it is
   asked to stop, finishes its current iteration, exits, and the new one starts (background work
   tolerates a pause, as it does today). Listening-fd handoff is an optional later hardening (§6.2).
8. **Configuration is one JSON file per daemon, every key required**, loaded into a typed record;
   `PG*` for the ppx are exported by the dev shell from the same file (tsunami shellHook pattern).
   Private extensions add their own top-level sub-objects (`"studio"`, `"purger"`,
   `"media_analysis"`, `"push_intake"`, `"wallet"`) to the **same** file; the public `Config.t`
   ignores unknown top-level keys, each sub-object is parsed strictly by its owner (§11.2).
9. **Control plane replaced, not ported.** No `EVAL`/`EXPR`; cross-node needs become narrow typed
   protocols (import line protocol), DB rows (`vars`), config, and `primalctl` (§7.3).
10. **Drop**: `Workers`/SPI/`pgext`, `pljava`, `pg_primal` (after a final grep of all DBs),
   `perf_test_redirection`, `prometheus_exporter.jl`, `tracing.jl` (`:p7` writes), SQLite dedup
   shards, `tr_sorted.jls`, `ws_conn_unblocker`, `@cached` in-importer trending, Julia EventSyncer /
   EventSync / CacheServerSync, `usage_tracking`, notebooks and one-off scripts.

### 2.1 Library choices

- HTTP/WS server: **httpun-eio + gluten-eio + httpun-ws** (tsunami `api/core/httpd.ml` is the
  template). TLS terminated by the proxy as today. zlib via `camlzip` (system zlib present).
- Outbound HTTP: tsunami `lib/http.ml` (hand-rolled HTTP/1.1, tls-eio, SOCKS5, redirects, chunked,
  SSE) extended with PUT/HEAD and request bodies for S3/CDN/Ollama/HLS providers.
- Outbound WS: tsunami `api/core/ws_client.ml` (RFC 6455 client) extended with masking, ping
  timers, per-connection switches; this is the relay client for the fetcher, DVM, rebroadcasting.
- HTML: `lambdasoup`+`markup` for OpenGraph injection and link previews (replaces EzXML and
  `link-preview.py`). Parser combinators: `angstrom` for `feed_directive` and advanced-search grammar.
- JSON: yojson; records via `ppx_yojson_conv` (already in the importer). Config records use it with
  strict unknown-key rejection.
- Language detection for `reads.lang` (Languages.jl today): a trigram-profile classifier in
  `ocaml-common/text/langid.ml`, profiles generated offline from the existing `reads_12_*` rows
  (labelled data we already have); accuracy gate against those rows in CI.

---

## 3. Directory layout

```
primal-net-server/                  # PRIVATE repo
├── dune-workspace, dune            # (dirs primal-server ocaml-ext): one workspace when built from here
├── ocaml-ext/                      # private extensions, see §11 (flake re-exports primal-server/ocaml-common's)
│   ├── bin/   primal-api.ml, primal-jobs.ml, primal-importer.ml   (public libs + Ext.register ())
│   ├── lib/   ext_config, studio/ (api, sql, broadcasting, rss_importer), purger/, media_analysis/,
│   │          push_intake/, membership/ (ext/App.jl funcalls), wallet_proxy/, crash_report/
│   ├── sql/   migrations for the studio/studio1 schemas (from sql/studio.sql)
│   └── rebuild-restart-*.sh        # wrappers: call primal-server's scripts with PRIMAL_EXE=…/ocaml-ext/_build/…
└── primal-server/                  # PUBLIC repo (nested checkout)
    ├── dune-workspace, dune        # (dirs ocaml-common ocaml-api ocaml-importer ocaml-fetcher ocaml-jobs); standalone builds
    ├── ocaml-common/
│   ├── flake.nix                   # the toolchain; shellHook exports PG* from $PRIMAL_CONFIG
│   ├── sql/ membership-refdb-setup.sh, migrate.sh (versioned runner, `public.schema_migrations`)
│   └── lib/
│       ├── core/    hex, str_util, utils, time, log, json_util, config_json, syntax (let*)
│       ├── nostr/   nostr (+to_json), bech32 (+nip19 json), kind (all synthetic kinds), secp256k1,
│       │            ids (Pubkey, Event_id, Sha256 abstract), signed_event (verified private type),
│       │            participant_proof, zap (bolt11 amount, receipt parse — from primal-cache/nostr.rs)
│       ├── pg/      postgres (Eio adapter, tagged pools), pg_types, pg_listen (raw-protocol LISTEN),
│       │            tracked_server (discovery JSON + pg_promote), notify
│       ├── pg_cache/        shared [%pgsql] against primal1 (filterlist, vars, cache kv, event lookups)
│       ├── pg_membership/   shared [%pgsql] against the membership schema (dune env → ref DB)
│       ├── net/     http_server (httpun), ws_server, http_client, ws_client, dns_eio, socks5, listen
│       ├── runtime/ lifecycle (signals → Condition → stop promise, drain), stats (phase registry,
│       │            watchdog), worker_pool, pushgateway, metrics, supervise, periodic (sleep loop
│       │            with stop), pg_lock (advisory-lock singletons), files (mtime reload)
│       ├── media/   mimetype_ext, s3 (SigV4), cdn_purge, ext_tools (file/ffmpeg/ffprobe/magick/exiftool)
│       ├── text/    langid, hashtags, mentions (for_mentiones), tsquery helpers
│       └── notifications/
├── ocaml-api/        (§5)  bin: primal-api, primalctl   lib: protocol, ws_api, handlers, queries, http_*, blossom, admin
├── ocaml-importer/   (§7)  + lib/import_listener, expire_scores, content_moderation_rules, user_search, push_intake
├── ocaml-fetcher/    (§8)  bin: primal-fetcher   lib: relay_conn, relay_set, resume, dedup, firehose, archive
└── ocaml-jobs/       (§9,§10) bin: primal-jobs   lib: dag/ (13 nodes), trustrank, analytics, dvm_checker,
                        dvm_provider, rebroadcast, pg_listener, failover, media/ (procgraph, tasks_*, analysis, uploads, purger)
```

---

## 4. `ocaml-common/`

### 4.1 Extraction from `ocaml-importer` (Phase 0)

Move verbatim, add `.mli` where an invariant is encoded (tsunami house style, not blanket):
`hex_util`, `str_util`, `utils`, `nostr`, `bech32`, `secp256k1(+stubs)`, `postgres`, `pg_types`,
`dns_eio`, `socks5`, `http`→`http_client` (merge with tsunami's), `pushgateway`, `notifications`,
`filterlist`→`pg_cache/filterlist`, `stats` split (registry/watchdog generic; counter record stays),
`worker_pool` parameterised over per-domain state. Importer keeps building and is redeployed with
`rebuild-restart-importer.sh`; `compare` parity unchanged.

### 4.2 Postgres layer

- Keep the importer adapter; adopt tsunami's pool semantics: lazy reconnect slots, **poisoned
  connections closed under `Cancel.protect`** (never returned after a non-`PostgreSQL_Error`),
  exclusive lease, fixed slot count. Keep the importer's eager `statement_timeout` /
  `application_name` at connect and the fd-leak-safe connect.
- Phantom-tagged handles so a membership query cannot run on a cache pool:
  ```ocaml
  type cache and cache_tl and membership
  type 'db conn  type 'db pool
  val use : 'db pool -> ('db conn -> 'a) -> 'a
  val raw : 'db conn -> Postgres.dbh      (* only queries/ and pg_*/ modules call it *)
  ```
- Pools are per domain (connections are domain-bound); `Pool.create ~domain_mgr ~per_domain`.
- `Tracked_server`: resolves the membership `conninfo` from the discovery JSON, re-resolves on
  connection errors; the promotion decision itself lives in one place (§9.7).
- `Pg_listen` from tsunami (raw v3 protocol, reconnect with backoff) for `primal_events`,
  `cache_storage`; `Waker` (condition + timeout fallback) for consumers.
- `Json_text.t`: validated-once JSON string from `e::text` columns, written without re-parsing.

### 4.3 Nostr additions

`Nostr.to_json` (NIP-01 canonical); `Kind` table of every synthetic kind from `app.jl`,
`app_ext.jl`, `app_media.jl`, `sql/app.sql` `c_*`, documenting the three collisions (10000134,
10000138, 10000176) that clients already depend on; abstract `Pubkey.t`/`Event_id.t`/`Sha256.t`;
`Signed_event.verified` as a private type constructible only by the verifier (so a handler needing
`event_from_user` cannot be reached with an unchecked event); `participant_proof` and zap receipt
parsing from `primal-cache/src/nostr.rs`; `nip19_decode_to_json` from `ocaml-handlers`.

### 4.4 Compile-time checking against two databases

`[%pgsql]` reads `PGHOST/PGPORT/PGUSER/PGDATABASE` at build time. `lib/pg_membership/dune` and
`ocaml-api/lib/queries/membership/dune` set `(env (_ (env-vars (PGDATABASE primal_membership_ref))))`
pointing at a schema-only clone made by `sql/membership-refdb-setup.sh` (pg_dump from
`<membership-db-host>`, like the importer's `refdb-setup.sh`). Cache queries use live `primal1` base tables
(not views: views make every column nullable and break `ON CONFLICT`).

### 4.5 Server kernel

- `Listen.bind` with `SO_REUSEADDR|SO_REUSEPORT`, backlog 1024; the fd is dup'ed and imported into
  every worker domain so each domain runs its own accept loop (kernel balances connections).
- `Http_server` (from tsunami `httpd.ml`): `route = {meth; pattern; auth; handler}` with closed
  `response = Json | Text | Blob | Redirect | Empty | Raw | Ws of ...`; adds body size caps,
  CORS helper reproducing Julia `api_headers`, per-service error style, inflight counter.
- `Ws_server`: httpun-ws upgrade; adds max 1 MiB inbound message, assembled fragments, binary
  frames, **bounded per-connection outbound `Eio.Stream`** with a writer fiber (a writer blocked
  > 15 s closes the socket, replacing `WSConnUnblocker`), server pings, idle timeout with the
  ws-connector jitter, close codes, graceful close on drain.
- `Ws_client` (from tsunami): masking, TLS via tls-eio, SOCKS5, ping/pong, per-connection switch,
  `recv_timeout` desync-safe; used by fetcher, DVM, rebroadcast, `broadcast_events`, replay tool.
- `Lifecycle`: signal handler only broadcasts an `Eio.Condition`; a fiber resolves `stop`;
  `Starting → Serving → Draining → Stopped`; `/readyz` false while not Serving.
- `Supervise label f`: restart-on-crash loop re-raising `Cancelled` (tsunami `schedd.ml`).
- `Files`: mtime-based reload of the content-moderation JSON/text files.

### 4.6 Job loops (for `ocaml-jobs`)

Deliberately minimal, mirroring the Julia modules: `Periodic.run ~clock ~period ~stop ~label f`
(sleep loop that checks `stop` between iterations, exceptions logged and the loop continues, phase
registered in `Stats`), `Supervise` for long-lived fibers, and `Pg_lock.with_advisory ~key` for the
few jobs that must not run twice across hosts (trustrank table swap, `precalculate_analytics`,
failover decision). No new tables. The DAG runner keeps its own `coverages` bookkeeping (§9.1) and
the media scheduler keeps `processing_nodes` (§10.1).

---

## 5. `ocaml-api/`

### 5.1 Process structure

```
main domain:  config → Lifecycle → bind all ports (every node index in config + 9001)
              → spawn K worker domains → LISTEN primal_events + imported_at poller (live events)
              → broadcasters (0.2 s net_stats, 1 s directmsg/notification counts, 2 s rebroadcast status)
              → admin HTTP 127.0.0.1 → pushgateway → stats line → await stop → drain
worker domain: own pools (cache, cache_tl 10 s, membership) → accept loops → per-connection fiber
```
Per-request work stays on its domain; cross-domain traffic is only live-event fan-out and
broadcasters pushing into connection streams.

### 5.2 Funcall registry — the central compile-time guarantee

```ocaml
type t = Thread_view | Multi_kind_thread_view | Feed | Feed_2 | Mega_feed_directive | ...
         | Set_primal_protocol   (* ~145 constructors: 135 sync + 3 live + 6 async + protocol *)
         | Extension of Ext_name.t  (* a name registered at startup by a private library, §11.1 *)
val of_string : string -> t option   (* consults the extension registry for unknown names *)
(* dispatcher *)
match f with
| Thread_view -> Handlers.Threads.thread_view c (Kw.decode Threads.args kw)
| Membership_content_backup -> Fallback_proxy.forward c f kw      (* explicit, grep-able *)
| Extension n -> Extensions.dispatch n c kw                        (* e.g. studio_operation *)
```
Exhaustive match with warnings-as-errors: a name without a handler, or a handler for a name that is
not exposed, does not compile. `Kw` is the tsunami typed-args DSL (`obj3 (req "event_id" event_id)
(opt "limit" (int ~min:1 ~max:1000) ~default:20) (opt "user_pubkey" pubkey)`): one declaration
gives parser and documentation. Handlers return `Response.t = {messages; notices; registrations;
partial}`; the kernel emits `EVENT*`/`EVENTS`, `NOTICE*`, `EOSE` — impossible to forget `EOSE` or
interleave frames. Async names only register a `Subscription`. Every handler gets a `Deadline.t`
(10 s; `PARTIAL_RESPONSE` for `feed`/`get_notifications`, NOTICE `"error"` otherwise). NOTICE
texts Julia clients see are reproduced verbatim (`"unknown api request"`, `"too many
subscriptions"`, `"kinds or authors filter is not supported"`, `"unsupported search filter"`).

### 5.3 Where the logic goes

| Area | Approach |
|---|---|
| threads, user_infos, bookmarks, enrich, long-form feed, live_*, poll_votes, scored, get_media_metadata | existing `sql/app.sql` functions (as ws-connector / ocaml-handlers do) |
| feed family, `mega_feed_directive`, `multi_kind_mega_feed_directive`, `feed_directive(_2)` | OCaml router over a closed spec variant (`Reads | Notes | Latest | Global_trending | Video_reels | Most_zapped | Wide_net | Search | Advsearch | Dvm | Muted_threads | Explore_media | …`), each arm one SQL function; `feed_directive` grammar in angstrom with a corpus from the replay logs |
| explore*, scored_users, trending_* | new plpgsql in `ocaml-api/sql/explore.sql` + per-domain TTL cache with background refresh (fixes frozen `@cached` values on API nodes) |
| zaps (5) | `og_zap_receipts` queries from ocaml-handlers + `zap_response` |
| get_notifications | ocaml-handlers version, cursor budget via `Deadline` |
| search, advanced_search, user_search, parse_advanced_search_query | port `DAG.search` (`dag.jl:3621-4487`): PikaParser grammar → angstrom; `to_sql` → typed query builder (`Sql.(select … where col "created_at" >= p_int since)`), the one sanctioned dynamic-SQL module; golden tests from `adv-search-parse-transform-tests.jl` + `adv-search-queries.json`; `search_upstream` config keeps the cross-node hop until all nodes are OCaml |
| settings, DMs, NIP-46, moderation, membership (12) | membership `[%pgsql]` (now checked); `event_from_user` via `Signed_event.verify` (signature + `created_at < now+300`) |
| import_events, import_poll_vote_event | send `["EVENT",..]` lines to `primal-importer` import listener (`import_node` config) and to `replicate_to` peers over WS; returns `EVENT_IMPORT_STATUS`; `add_human_override` and the instant indexers move with it (§7.2) |
| broadcast_events, broadcast_reply, dvm_feed, get_dvm_feeds | `Ws_client` relay connections bounded by `Deadline` |
| network_stats, nostr_stats, server_name, client_config, relays, defaults, releases, home/reads feeds | `Files` watcher over the content-moderation dir; `stats.json` path or `network_stats_url` |
| nip19_decode, invoices_to_zap_receipts, find_reposts, events, event_actions, replaceable* | straightforward queries (ocaml-handlers catalogue) |
| membership_name_available / purchase_product / status / change_name, `wallet*` (parent `ext/App.jl`), `studio_operation` (parent `app_studio.jl`), `crash_report` | **private**: registered from `ocaml-ext` as extension funcalls (§11); the public build answers `"unknown api request"` for them, as a public clone of the Julia code would |

### 5.4 Live events

`Subscriptions` registry keyed by connection id (removed on CLOSE and disconnect); fed by
`Pg_listen "primal_events"` + the 1 s `imported_at` poller with the 10k dedup ring; per event
`live_feed_is_hidden`/moderated checks in SQL; `p`-tag role lowercasing kept. The `ws-importer`
writes (`live_event_participants` with proof verification, `follow_lists`, `zap_receipt_invoices`,
`live_event_pubkey_filterlist`, `pg_notify('cache_storage')`) move to `primal-importer` (§7.1).

### 5.5 HTTP services

Route-for-route port of `internal_services.jl` (exact bodies: pretty `nostr.json`, `application/text`
short URLs, 302 targets, CORS). `preview_handler` with lambdasoup (reparsed on mtime change); unknown
Host → 404 instead of KeyError. `/link-preview` in OCaml (replaces `link-preview.py`). `/api` = same
dispatcher (`subid="http"`). 24000+N `purge_media_` step for step with `Media.s3` (SigV4, replaces
`s3.py`) and Cloudflare/Bunny purge. Blossom routes + auth; `PUT` import reconstructed from
`git show 2f2a3d7^:src/app_media.jl` (`import_upload_2`/`media_import_2`) sharing
`ocaml-jobs` upload code via `ocaml-common/media`; DELETE null-check bug fixed.

### 5.6 Admin, metrics, logs

`127.0.0.1:<admin_port>`: `/healthz`, `/readyz`, `/tasks` (phase registry), `/metrics`, `POST /drain`,
`/config` (redacted). Pushgateway metric names preserved (`max_request_duration`,
`requests_per_period`, `max_time_between_requests`, ws-connector counters). `wsconnvars` polled
(1 s) for `idle_connection_timeout`, `metrics_logging_*`; request log in `ws-replay` JSONL format.
Logs: `[component]`-prefixed lines to stdout, appended by systemd to `$PRIMAL_VAR_DIR/*.log`.

### 5.7 Config (`primal-api-config.json`, all keys required)

```jsonc
{ "servername": "wscm", "node_indices": [31,32,33,34,35,36,18], "public_ws_port": 9001, "admin_port": 14001,
  "num_domains": 12, "cache_db": {...}, "cache_db_timelimit_ms": 10000,
  "membership": {"discovery_url": "http://<discovery-host>/discovery/postgres/membership/primary.json", "fallback": {...}},
  "pool_per_domain": {"cache": 2, "cache_timelimit": 1, "membership": 1},
  "upstream_julia_ws": "ws://127.0.0.1:8817", "proxied_funcalls": [],
  "import_node": {"host":"127.0.0.1","port":12018}, "replicate_to": ["ws://<peer-host>:8831", ...],
  "search_upstream": "http://<search-host>:14017/api", "network_stats_url": null, "stats_file": "...",
  "content_moderation_root": "<config-dir>/content-moderation",
  "index_dirs": {"primal.net": "/var/www/dev.primal.net", ...},
  "media": {"paths": ..., "paths_2": ..., "url_root": ..., "blossom_base_url": ..., "download_proxies": [...],
            "s3_providers": {...}, "cloudflare": {...}, "bunny": {...}},
  "drain": {"grace_s": 30, "ws_max_s": 900}, "idle_connection_timeout_s": 600, "max_subscriptions": 200,
  "request_timeout_s": 10.0, "pushgateway": {...}, "request_log": "$PRIMAL_VAR_DIR/metrics-wsconn.log" }
```
Secrets (`algos_user` nsec, DVM requester key, S3 keys, Cloudflare/Bunny keys, DVM salt) are file
paths, never inline (tsunami convention). `primalnode_config*.jl` values are migrated in Phase 0.
Private sub-objects live in the same file (§11.2); the public `Config.t` has
`[@@yojson.allow_extra_fields]` at the top level only.

---

## 6. Rolling restart (all daemons)

`rebuild-restart-<daemon>.sh` follows `tsunami/ocaml-rolling-restart.md`, adapted to systemd:

1. `ocaml-common/sql/migrate.sh` (pending `sql/NNNN_*.sql`, `lock_timeout=5s`) — the ppx needs the
   schema current. Then `nix develop path:ocaml-common -c dune build @all` and the daemon's tests.
   Any failure stops before touching the running instance. Config presence is checked.
2. Start the **new generation** as a transient unit `primal-<daemon>-<ts>.service`
   (`Restart=always`, `OOMPolicy=kill`, `MemoryMax`, `LimitNOFILE=65536`, log append). Listeners bind
   with `SO_REUSEPORT` next to the old one; the kernel balances new connections across both.
3. Verify: process alive after 3 s and every port answers (`/readyz` on admin, a `user_infos` REQ on
   8800+N like `monitor-cache-server.sh`, `STREAM-NEW-EVENTS` handshake for the fetcher). If the new
   one dies while an old one runs → stop the new unit, report, leave the old serving.
4. `kill -USR1` old pids (captured by exe path **before** launching, pidfile as backup). Old enters
   `Draining`: closes listeners, finishes in-flight HTTP/REQs, closes idle WS immediately and active
   WS after `drain.grace_s`, everything by `drain.ws_max_s`, then exits 0 and its unit collects.
   Fetcher: new instance resumes from per-relay `latest_timestamp` files and the overlap produces
   only duplicates (importer dedups). Jobs daemon (`rebuild-restart-jobs.sh`): stop-then-start —
   SIGUSR1 makes every loop finish its current iteration (a DAG segment, an analytics run) and exit
   within `drain.grace_s`; a cut-off DAG segment simply resumes from `coverages.t2` next run, as it
   does after a Julia restart today.
5. Orphan sweep: any process from this project's exe path not in the pidfile is drained too.
6. `primalctl status|drain|stop <daemon>` via the admin socket.
7. The scripts take `PRIMAL_EXE` (default: this project's `_build/default/bin/<daemon>.exe`) so the
   private `ocaml-ext/rebuild-restart-*.sh` wrappers reuse them for the production binaries; the
   build step then runs in the parent workspace so public and private code compile together.

### 6.1 Why overlap is safe per daemon

- api: SO_REUSEPORT; subscriptions and live-event registries are per process; clients reconnect.
- importer: `store_event` is an atomic `ON CONFLICT` claim; sched-hooks use `DELETE … RETURNING`.
- fetcher: duplicates are harmless downstream; `latest_timestamp` files are written atomically.
- jobs: no overlap (stop-then-start); idempotent coverage rows and advisory-lock singletons
  (trustrank swap, failover decision, `precalculate_analytics`) protect against a straggler.

### 6.2 Optional hardening (later): listening-fd handoff over a unix socket (nginx-style) removes
the small SYN-loss window when the old listener closes. Not needed for parity with today.

### 6.3 Signal handling in multi-domain daemons (lesson, 2026-10-04)

`Sys.set_signal` + `Eio.Condition.broadcast` (the tsunami single-domain pattern) is not reliable
with several domains and Eio's systhread pool: the kernel may deliver SIGUSR1 to an idle pool
thread, and an OCaml handler only runs when that thread next returns to OCaml code, which can be
minutes later (observed: a drain requested at 01:29:00 was acted on at 01:30:40, after the load
had gone). `Lifecycle.create` therefore blocks the stop signals in the main thread before any
domain or thread exists (the mask is inherited), consumes them synchronously in one dedicated
thread with `Thread.wait_signal`, and a fiber polls the resulting flag every 250 ms. Every daemon
must create its `Lifecycle` before spawning domains, and the drain controller must be a concurrent
fiber: the accept loops' switches hold the connection fibers, so code placed after `Fiber.all`
only runs once every client has left on its own.

---

## 7. `ocaml-importer/` completion and control-plane replacement

### 7.1 Importer duties still Julia-only (gaps from §1.4)

| Item | Port |
|---|---|
| `expire_scores` (60 s) | `[%pgsql]` set-based: `update event_stats_1_… set score24h = score24h - s.change from score_expiry s where expire_at <= now …` then delete; run from the existing sched-hooks fiber |
| double `run_scheduled_hooks` | disable in Julia at cutover (Phase 1 flag), nothing to port |
| `update_user_search` on kind 0 | port `cache_storage_ext.jl:958` (tsvector of name/username/display_name/displayName/nip05/lud16, human-gated) into `ext_metadata_changed` |
| `update_content_moderation_rules` on kinds 10000/30000 (`mute`,`mutelists`,`allowlist`) | port `app.jl:488` `import_content_moderation_rules` (`cmr_*` tables) + `pg_notify('primal_events', kind 11000001)` |
| `add_human_override`, `get_trusted_followers_count` | small `[%pgsql]` helpers |
| ws-importer writes (§5.4) | `live_event_participants` (proof verify), `follow_lists`, `zap_receipt_invoices`, `live_event_pubkey_filterlist`, `pg_notify('cache_storage', …)` into `cache_storage_ext.ml` for kinds 30311/39089/9735/10555 |
| push-notification TCP intake :20000 (`wallet-transaction` type) | private `ocaml-ext/lib/push_intake`: newline JSON listener feeding the importer's push buffer through a registered role (§11) |

### 7.2 Import listener on 12000+N (replaces FirehoseServer `EVAL`/`EXPR`)

Line protocol, 0.0.0.0 as today but **only** `["EVENT", subid, event]` / `["IMPORT", [events]]`
lines → the normal import queue, reply `["OK", id, imported|duplicate|rejected, reason]`. Also runs
the "instant indexers" the Julia `import_events` path triggers (`import_basic_tags`,
`import_zap_receipts`, `import_poll_votes`, `import_event_mentions`) directly for that event id,
using the same SQL modules the DAG nodes use (shared `ocaml-common/pg_cache/dag_index`), and
`App.ext_import_event` reply broadcasting via `Ws_client`.
Typed message variant; anything else → `["NOTICE", "unsupported"]`.

### 7.3 Everything `rex` / EVAL does today, and its replacement

| Use | Replacement |
|---|---|
| API `import_events` → importer | §7.2 import listener |
| DAGRunner `onsuccessful` pushes `App.DAG_OUTPUTS` to API nodes | API reads `node_outputs` / `vars` row `dag_outputs` (written by jobs) on a 5 s poll |
| `init-api-request-replication.jl` sets `REPLICATE_TO_SERVERS` | `replicate_to` config |
| `POLL_VOTES_REDIRECTED`, `WALLET_REDIRECT` | config (`poll_votes_upstream`, `wallet_upstream`) |
| Julia EventSyncer `rex` into peers | OCaml `Event_syncer` already pulls directly from peer DBs |
| `code_load.jl` hot reload + SQL deploy | rebuild-restart scripts + `migrate.sh`; `sql/app.sql` is split into migrations once and then only changed via new migration files |
| `deploy.sh` EVAL `exit()` | `primalctl drain` / the scripts |
| MCP tools over EVAL (`mcp_tools.jl`) | `primalctl` subcommands (`req`, `sql` read-only, `status`) |

---

## 8. `ocaml-fetcher/`

- **Relay set**: `relays-active.txt`, `relays.txt`, `relays-paid.txt`, `relays-mined-*.txt`
  (same sanitising rules: drop `.onion`, IPv6, localhost; normalise ports), `ws://<internal-relay-host>:7777`
  (proxy forced off), plus the `fetcher_relays` table polled every 1 s (skip private ranges, > 300
  chars). Port `load_relays`/`start_relays_from_db` as a `Relay_set` with a typed `Relay_url.t`.
- **Per relay fiber** (`Relay_conn`): `Ws_client` with connect/read timeouts 30 s, SOCKS5 when
  configured; two REQs (`{since}` and `{since, authors: ["00".."ff"]}`); `since = min(now,
  max(since, created_at-1))`; backoff 1 s → 300 s; `AUTH`/`CLOSED`/`NOTICE`/`EOSE` passed through.
  ~8k connections spread over `num_domains` domains (relay → domain by hash); TLS session memory is
  the sizing risk, measured in the Phase 1 spike (target < 4 GB RSS at 8k relays).
- **Resume**: per-relay `latest_timestamp` under `$STORAGE/primalnode$N/fetcher/<escaped url>/`,
  same path and escaping so the first OCaml start resumes where Julia stopped; written atomically
  every 5 s; `since` default from config (`fetcher_since`, replaces `PRIMALSERVER_FETCHER_SINCE`).
- **Message envelope**: identical JSON `[time, {func, runid, relay_url, timeout, proxy, event},
  ["EVENT", subid, ev]]` so the archive format and the importer's `event_from_msg` stay valid.
- **Dedup**: in-memory time-bounded set (id → first-seen, pruned at 6 h) replaces the 256 SQLite
  shards. Signature + `created_at < now+300` verification before emitting (ocaml-common
  `Secp256k1`). Downstream dedup (importer `ON CONFLICT`) is the real guard, as today.
- **Archive** (`messages/YYYY/MM/DD.log` JSONL, bucketed by `created_at`): kept behind
  `archive_enabled` with the exact line format (the 467 GB archive, `maintanance.sh`,
  `pg-dedup-archive-funcs.sql` seek by `file_position`). `latest_file_positions` SQLite dropped.
- **Firehose server** on `127.0.0.1:9000+N`: `STREAM-NEW-EVENTS` subscription, 20k-message
  bounded channel per subscriber with drop-when-full, same as today; no other commands.
- **Metrics**: pushgateway job `fetcher<N>` with `fetcher_message_count`, `fetcher_exception_count`,
  `fetcher_chars_received`, `fetcher_chars_sent`; stats `stats.json` counters preserved.
- `Fetching.fetch` ad-hoc REQ fan-out (`auto_fetch_missing_events`) is off in production: not ported.
- Rolling restart per §6; overlap yields duplicates only.

---

## 9. `ocaml-jobs/` — background jobs (non-media roles)

One daemon, roles enabled by config (`roles: ["dag","trustrank","analytics","dvm_checker",
"dvm_provider","rebroadcast","pg_listener","failover","media"]`). Each role is one supervised
fiber running the same loop its Julia module runs today (§4.6); a few take a PG advisory lock so two
hosts never run them concurrently. No queue tables, no claims, no retries beyond what Julia has.

### 9.1 DAG runner and nodes

- `Dag_runner` is a direct port of `dag_runner.jl`: the 5 s loop with `until = now`, `since = last
  until` (initially 2023-01-01), segments of `imported_at` (1 d or 90 d per node),
  `coverages_1_8656fc443b(name, t, t2)` resume semantics, `node_outputs_1_cfe6037c9f`, up to 8
  segments in parallel (`Fiber.List.iter ~max_fibers:8`), `dag_runner_duration` /
  `dag_runner_all_ok` metrics, `CREATE … IF NOT EXISTS` of outputs per run, `onsuccessful` writing
  the outputs map to `vars` (§7.3). **Hashed table names are hard-coded** in one `Dag_tables` module
  (`basic_tags_6_62c3d17c2f`, `zap_receipts_1_9fe40119b2`, `poll_stats_1_d8de047040`,
  `poll_user_votes_1_5fa4d82e64`, `a_tags_1_7d98c5333f`, `reads_12_68c6bbfccd`,
  `reads_versions_12_b537d4df66`, `pubkey_media_cnt_1_b5e2a488b1`,
  `pubkey_content_zap_cnt_1_236df2f369`, `advsearch_5_d7da6f551e`, `event_mentions_1_a056fb6737`,
  `note_length_1_15d66ffae6`, `note_stats_1_07d205f278`) and asserted against `node_outputs` at
  startup; the `public.<name>` views stay the API contract.
- Nodes, each a module `Node.{name; version; window; run : dbh -> segment -> unit}` whose SQL is
  `[%pgsql]`-checked against the real hashed tables (the `@pg` macro bodies move over as-is):

| Node | Port notes | Size |
|---|---|---|
| `basic_tags` v6 | pure `INSERT … SELECT jsonb_array_elements` | S |
| `zap_receipts` v1 | OCaml parse of 9735 (`Zap.parse_receipt`, bolt11 ≤ `MAX_SATSZAPPED`, `a` → `parametrized_replaceable_events`) | S |
| `poll_stats` v1 | `update_single_poll_stats` logic (`dag.jl:2048-2198`) as plpgsql, gated by config | M |
| `a_tags` v1 | temp-table + 8 workers → one set-based statement per segment | S |
| `reads` v12 (5 phases) | latest 30023 per `(pubkey, identifier)`, topics tsvector, words, `lang`/`lang_prob` via `Langid`, image, summary; phases 2-5 counts via basic_tags/a_tags | M-L |
| `pubkey_media_cnt`, `pubkey_content_zap_cnt` | additive upserts | S |
| `advsearch` v5 | kinds 1/POLL/ZAP_POLL/30023/20/21/22/1111, 30-day window; tsvector + hashtags + mentions (`Text.mentions` port of `for_mentiones`) + media/link filters + url tokens | M |
| `event_mentions` v1 | `for_mentiones` over tags + `nostr:` bech32 in content | M |
| `note_length`, `note_stats` | SQL | S |
| `update_user_search_node` | calls the importer's `update_user_search` helper (shared in ocaml-common) | S |

  Not ported: `events_simplified_node`, `event_stats_node`, `sqlite2pg` transfer, `event_sentiment_node`
  (dead; its two references in `DAG.search` are removed). Orphan tables listed in the inventory
  are dropped by a migration after cutover.

### 9.2 TrustRank maker (3 h, singleton)

Seeds = membership `verified_users where default_name`; blocked = `filterlist` pubkeys in
`spam`/`csam`. Build the follow graph with **one query** (`select follower_pubkey, pubkey from
pubkey_followers`) into CSR arrays (no per-pubkey lookups), personalized PageRank α=0.85, 20
iterations, zero blocked, keep rank > 0. Write `pubkey_trustrank_new` with `COPY` (not row inserts),
`ANALYZE`, then the swap transaction (`DROP VIEW trusted_users_trusted_followers` → rename → recreate
view) exactly as `TrustRank.import_trustrank`; make the live table LOGGED unless benchmarks say
otherwise. `tr_sorted.jls` is not written (its reader is a no-op). Metrics as today.

### 9.3 `precalculate_analytics` (600 s, singleton)

Port `scored_content`/`scored_`/`explore_topics_` into `ocaml-jobs/sql/analytics.sql` plpgsql
producing the same JSON payloads for the `cache` keys
`precalculated_analytics_{trending,gm_trending,classic_trending,mostzapped}_{24h,12h,4h,1h}` and
`precalculated_analytics_explore_topics` (golden-compared against Julia output for a week). The
Ollama "gaming" classifier (gemma3n, yes/no prompt, `[G] ` prefix) via `Http_client` POST; the HTML
report via `Eio.Process` `ssh <edge-proxy> …` (config `gaming_report_command`). `trending_24h_scores` and the
`@cached` importer-side values are not ported (API computes its own).

### 9.4 DVM feed checker (600 s + per-feed random delay)

For each kind-31990 handler: NIP-90 5300 request via `Ws_client` to the 5 relays with the
requester key from config, 30 s timeout, parse 6300/7000, upsert `dvm_feeds(pubkey, identifier,
updated_at, results, kind, personalized, ok)`. `App.dvm_feed` logic is shared with the API handler.

### 9.5 DVM service provider (optional role, off by default until confirmed running)

Port `dvm_service_provider.jl`: key derivation from `PRIMAL_DVM_KEYPAIR_SALT`, NIP-89 31990 +
NIP-65 publishing per feed, NIP-90 request handling by calling the API funcalls in-process
(`ocaml-api` handler library linked), `dvm_usage` logging on membership.

### 9.6 Event rebroadcasting

1 s worker over membership `event_rebroadcasting` (8 tasks, batch 100, 10 ev/s, 30 s timeout) via
`Ws_client` to user relays; status rows the API's `membership_content_rebroadcast_*` read. The
engine (`Rebroadcast.broadcast_events ~relays ~delay`) is a public ocaml-common module so the
private Studio broadcaster (§11.3) reuses it.

### 9.7 PG listener, failover, monitoring

- `pg_listener` role: `Pg_listen "cache_storage"`, payload `{type:"live_event", kind, pubkey,
  identifier}` → for each follower: `live_event_notification_created` dedupe row, filterlist and
  `live_feed_is_hidden` checks, 1 h in-memory rate limit, `DB.notification(LIVE_EVENT_HAPPENING=501)`
  (the importer's `notification` function, shared via ocaml-common).
- `failover` role (singleton, advisory lock): every 1 s read the discovery JSON; if the named
  primary reports `pg_is_in_recovery()`, call `pg_promote()` and bump `vars.membership_primary`;
  every daemon's `Tracked_server` re-resolves on connection errors. Metrics
  `postgres_min_free_sessions`, `postgres_oldest_backend_age_<srv>` every 15 s.
- pg_cron jobs (`record_trusted_pubkey_followers_cnt`, `update_user_relative_daily_follower_count_increases`,
  deletions) stay in Postgres.

---

## 10. `ocaml-jobs/` media role (replaces Rust `primal-media` + Julia media code)

### 10.1 Processing graph executor

- Keep the `processing_nodes` / `processing_edges` / `processing_codes` tables and the Julia node-id
  hash (sha256 of `{mod, func, args, kwargs}` with the `{_ty,_v}` typed JSON): `Procgraph.node_id`
  ported from `primal-media/src/processing_graph.rs:81` with the existing
  `test_processing_node_ids` check against the DB. Binary args in `BINARY_DATA_CACHE_DIR` layout.
  `requeue-cdn-backlog.py` keeps working (then is ported to `primalctl media requeue`).
- Scheduler: port `processing_graph_execution_scheduler.rs` (1 s tick, oldest pending per task
  name, `max_concurrent_per_name`, stuck-node reset over 2 days, 60 s stats) plus the Julia tick
  duties (`block_media`, `purge_media_` ×10, `import_upload_3` ×10, `REFRESH MATERIALIZED VIEW
  CONCURRENTLY pn_time_for_pubkeys` every 600 s).
- Task handlers (typed, registered in one list; a `#[procnode]`-style naming check against the
  `func` column): `import_media_fast_pn`, `import_media_pn`, `import_media_variant_pn`,
  `media_variants_pn`, `media_variant_fast_pn`, `import_preview_pn`, `import_media_hls_pn`,
  `import_text_event_pn`, `import_upload_3`, `block_media`, `purge_media_`, `restore_media`,
  `restore_user_media`, `inc_counter`, `ext_after_import_upload_2` (today orphaned: no executor —
  verify backlog), `analyze_and_update_media_metadata`, `analyze_and_update_text_metadata`.
  Legacy `transcode_video_pn` / `media_video_variants_pn` (NVENC over ssh) not ported.
- **Procnode definition: combinators, no ppx (decided).** Julia's `@procnode` / Rust's
  `#[procnode]` derive `mod`/`func` from the binding, serialize args as Julia-typed `{_ty,_v}` JSON
  for the node id, memoize through `processing_nodes`, record ancestry from the current parent node
  and provide the `@pn` (inline) / `@pnd` (delayed) call forms. With ~35 handlers in total this is
  done with one declaration per node and no syntax extension:
  ```ocaml
  let analyze_image_2 =
    Procnode.define ~mod_:"PrimalServer.MediaAnalysis" ~func:"analyze_image_2"
      Args.(obj3 (pos "data" bytes) (kw "sha256" bytes) (kw_opt "extra" json))
      (fun ctx (data, sha256, extra) -> ...)
  let r = Procnode.run ctx analyze_image_2 (data, sha256, extra)     (* @pn  *)
  Procnode.enqueue ctx block_media (pubkey, surl, reason, extra)      (* @pnd *)
  ```
  `define` returns a typed handle (a call with the wrong argument shape does not compile); the
  `Args` descriptor is the single source for the typed-JSON encoding, the node id, and the decoder
  the scheduler uses to execute a stored node; ancestry is a fiber-local parent key. What the macro
  gave for free, `func` from the binding name, is replaced by a startup/test check: registry names
  unique and covering every distinct `func` in `processing_nodes`. Rationale: greppable, LSP-friendly,
  no ppx to maintain (the tsunami kernel's own guidance: flat tables over DSLs; its `ppx_task` serves
  fingerprinting/memo we do not adopt). Revisit only if kwargs records become repetitive, in which
  case a `[@@deriving procargs]` (adapted from tsunami's `[@@deriving codec]`) generates the record
  encoder/decoder, nothing more. The real risk is byte-identical node ids: the `{_ty,_v}` encoding of
  every argument type must match Julia exactly or historical nodes re-run and
  `requeue-cdn-backlog.py` stops matching; the Rust `test_processing_node_ids` check against the live
  DB stays as the gate.
- External tools via `Eio.Process` with deadlines: `file -b --mime-type` (stdin, with the > 7 MiB
  EPIPE fix from `f1715fc` as a test), `ffprobe`, `ffmpeg` (`nice ionice -c3`, optional remote
  `ssh`), `magick` under `systemd-run --user --scope -p MemoryMax=5G`, `exiftool` under `bwrap`
  (strip metadata keeping Orientation), `timeout`. `LD_LIBRARY_PATH` stripped from children.
- Storage: v1 key-addressed and v2 content-addressed layouts (`<root>/<h1>/<h2:3>/<h4:5>/<h><ext>`,
  `.key` file, symlink), `media_paths`/`media_paths_2` with `local`/`s3` entries, `media_storage`
  (+ `media_storage_priority`) rows, `use_external_storage` trust-rank rule.
- S3 (`Media.s3`, SigV4 over `Http_client`; replaces `s3.py` and aws-sdk-s3): upload, check, get,
  delete, copy, presign. HLS providers (`hls_providers.rs` 1k lines): AWS MediaConvert (SigV4 JSON
  API), Mux, Bunny Stream, Cloudflare Stream; `event_hls_media` rows.
- AI: Ollama `/api/embeddings`, `/api/chat`; classifiers on `<ai-host>:{5012,5015,5016,5017,5018}/classify`
  and features `:5013/:5014` — thin typed HTTP clients.

### 10.2 Uploads (public) and media analysis (private hook)

`import_upload_3` (`app_media.jl:26-137`): mimetype + dimensions, `media_import_2(:upload)` to local
+ S3, `memberships` row creation/`used_storage += size`, videos → `video_urls`/`video_frames`,
then the **`after_import_upload` hook**: a registration point (§11.1) that the private
`media_analysis` library fills (today `MediaAnalysis.ext_after_import_upload_2`, parent repo). The
public build runs uploads without analysis. Blossom `PUT` and `import_upload_3` share this code.
Text embeddings (`ext_event_batch`) stay disabled. The `media_uploads` writer is outside these
repos (unchanged). `block_media`, `purge_media_`, `inc_counter` stay public (they are
`primal-server` code); the CSAM/NSFW decision logic that calls them is private (§11.4).

---

## 11. Private extensions: `primal-net-server/ocaml-ext/`

Everything that is Julia/Rust in the private parent repo today is ported here, never into
`primal-server`. `ocaml-ext` depends on the public libraries (`primal_common`, `primal_api`,
`primal_jobs`, `primal_importer`) and produces the production binaries. The public repo compiles
and runs without it (no Studio, no analysis, extension funcalls answer `"unknown api request"`).

### 11.1 Registration points in the public code (the only coupling)

| Public registry | Signature (sketch) | Filled by `ocaml-ext` with |
|---|---|---|
| `Api.Extensions.register_funcall` | `name:Ext_name.t -> 'a Kw.args -> (Conn.t -> 'a -> Response.t) -> unit` | `studio_operation`, `membership_*` (4), `wallet*` proxies, `crash_report` |
| `Api.Extensions.register_http_route` | `port:[`Internal|`Moderation] -> Http_server.route -> unit` | `/crash-report` on 14000+N |
| `Jobs.Roles.register` | `name:string -> (Ctx.t -> stop:unit Promise.t -> unit) -> unit` | `studio_broadcast`, `rss_import`, `purger_http` (:22000), `push_intake` (:20000, importer) |
| `Jobs.Procgraph.register` | a `Procnode.define` handle (§10.1: `mod`, `func`, `Args` descriptor, run) | `analyze_and_update_media_metadata`, `analyze_and_update_text_metadata`, `ext_after_import_upload_2`, `block_porn_spammer` |
| `Media.Hooks.after_import_upload` | `(Upload.t -> unit) ref`-style hook, one registration | media analysis entry (§11.4) |
| `Nostr.Kind.register_private` | `name -> int -> unit` (asserted unique against the public table) | `STUDIO_*` 10000901–10000911, wallet 10000300–10000320/10000600–10000603 |

Each registry is append-once at startup (`Ext.register ()` in the private `bin/*.ml`), checked for
duplicates, and dumped by `primalctl status`. Inside `ocaml-ext` the same compile-time discipline
applies: closed variants, `[%pgsql]` against `primal1` (the `studio`/`studio1` schemas live there)
and against the membership ref DB.

### 11.2 Configuration

Same JSON file per daemon (`primal-api-config.json`, `primal-jobs-config.json`, …). `ocaml-ext`
parses its sub-objects strictly, every key required:

```jsonc
"studio": { "godmode_pubkeys": [...], "default_inbox_pubkey": "529f0119…3db1", "trial_days": 30,
            "broadcast": {"period_s": 1, "tasks": 2, "delay_s": 5.0},
            "rss": {"period_s": 120, "min_refetch_s": 900, "signer_key_file": "…"} },
"purger":  { "port": 22000, "dry_run": false, "bunny_api_key_file": "…", "primal_domains": [...],
             "media_server_url": "http://<media-host>:24018" },
"media_analysis": { "ai_host": "<ai-host>", "ollama_host": "<ai-host>:11434",
                    "thresholds": {"meme": 1.0, "nsfw": 0.94, "csam_child": 0.4}, "csam_block_limit": 3,
                    "purger_api": "http://…:22000/api", "warning_email_command": [...] },
"push_intake": { "port": 20000 },
"wallet": { "upstream": null }
```

### 11.3 Studio (all of it)

- **`studio_operation` funcall** (`app_studio.jl`, 197 lines): `event_from_user` → verified event,
  content JSON `{op, …}`. `Studio_op.t` is a closed variant parsed with the typed-args DSL:
  `Home_totals | Home_graph of {resolution: Hour|Day|Month} | Home_top_notes | Home_top_articles |
  Settings_inbox_permissions_(list|add|remove) | Settings_content_imports_(list|add|remove) |
  Feed_totals | Feed | Import_scheduled | Replace_scheduled | Get_scheduled | Delete_from_inbox |
  Delete_scheduled | Scoring | Media_files_usage | License_status` — exhaustive, so an op without a
  handler does not compile. `get_pubkey` authorization (`pubkey == user || user ∈ godmode`), the
  `limit ≤ 100` clamp, `since ≥ 2023-01-01`, the hard-coded default inbox pubkey (moved to config),
  event verification for `import_scheduled`/`replace_scheduled` (signature + author match).
  `studio_license_status`: membership `premium-legend` check, `studio.user_access(_daily)` upserts,
  30-day trial arithmetic. Kinds 10000901–10000911 registered privately.
- **SQL** (`sql/studio.sql`, 682 lines): `studio.home_totals`, `home_graph`, `home_graph_monthly`,
  `home_event_stats`, `home_top_notes`, `home_top_articles`, `event_tags` view, `get_event_tags`,
  `feed_totals`, `get_unpublished_posts`, `get_scheduled_posts`, `feed`, the `c_STUDIO_*`
  constants, tables `settings_inbox_permissions`, `settings_content_imports`, `scheduled_events`,
  `deleted_proposed_events`, `rss_feed_items`, `user_access`, `user_access_daily`, `studio1.scoring`.
  Moved verbatim into `ocaml-ext/sql/` migrations; all calls are `[%pgsql]`-checked. Queries run on
  the 30 s time-limited cache pool as today (`:p0timelimit30s`).
- **Scheduled + RSS broadcasting** (`studio_event_broadcasting.jl`, 93 lines) as the
  `studio_broadcast` jobs role: every 1 s, `scheduled_events` with `status='pending' and
  scheduled_at <= now` and `rss_feed_items` with `broadcast_state='pending'`; for each: import the
  event through the importer's import listener (§7.2; today `DB.import_event` in-process), resolve
  the user's relays (`get_user_relays` logic shared from the API handler library), broadcast with
  the public `Rebroadcast` engine (2 tasks, 5 s delay), write `status/result/broadcasted_at` or
  `broadcast_state/broadcast_result`, push `scheduled_events_broadcast_latest` /
  `rss_imports_broadcast_latest`. Same plain `select … where status='pending'` as Julia; the jobs
  daemon never overlaps itself (§6), so no claiming is needed.
- **RSS content importer** (Rust `rss-content-importer/`, 589 lines) as the `rss_import` role:
  `studio.settings_content_imports` (kinds `notes`/`articles`), conditional fetch with
  `etag`/`expires_at` and the 15-minute minimum, RSS/Atom parsing with `xmlm`, HTML → Markdown
  (replace `html2md` with a small lambdasoup-based converter covering the tags the Rust custom
  handlers cover), item dedupe by guid, draft event creation (kind 31234 wrapping kind 1 / 30023,
  `nostr_event` + `nostr_event_unencrypted`, signer key from config), `broadcast_state='pending'`
  hand-off. Needs event signing (secp256k1 schnorr sign stub, as tsunami `uiauto/sign.ml`) and,
  if the draft is NIP-44-encrypted as the column names suggest, NIP-44 v2 (secp256k1 ECDH stub +
  ChaCha20 + HMAC-SHA256/HKDF via mirage-crypto/digestif). Verify against existing rows first.
- The Rust `studio/` crate is a 37-line stub: deleted, nothing to port.

### 11.4 Media analysis (`src/media_analysis.jl`, 814 lines)

Everything here is a `@procnode`: memoised by node id in `processing_nodes`, and `@pnd` enqueues a
delayed node that the scheduler tick executes. The port keeps that shape: each function below is a
registered procgraph task (§11.1) with the same `mod`/`func`/args so node ids and the historical
rows stay compatible.

- **Entry point `ext_after_import_upload_2(surl, data; pubkey, eid, origin)`** (line 435). Two
  callers: `import_upload_3` inline with `origin="upload"` (today via `ext_after_import_upload`), and
  Rust `import_media_pn` enqueueing a delayed node with `origin="nostr"` (today without an executor —
  check the backlog). Logic: `sha256(data)`, extension from `surl`; for `origin="nostr"` skip if a
  `media_metadata` row with `model='primal'` exists; AI host `<ai-host>` (task-local, both origins);
  images (`.jpg/.png/.gif`, < 10 MiB, both dimensions > 50) → `analyze_image_2`; videos
  (`.mp4/.mov/.mkv/.webp`, < 100 MiB, dimensions > 50) → `analyze_video_2`; if `csam` → `@pnd
  block_media(pubkey, surl, reason="csam by media analysis")`; if `nsfw` and the event is a reply
  (`event_replies`) and the author's first event is < 7 days old → `@pnd block_porn_spammer`.
- **`analyze_image_2`**: `analyze_and_update_media_metadata` with algo `1b` (meme: minicpm-v via
  Ollama, `askprob` yes/no over n=5 on a 768 px resize, threshold 1.0), `2` (NSFW classifier,
  threshold 0.94), `1a` only if NSFW (child probability, threshold 0.4 → `csam`), `3` (image
  features → `media_embedding`); each algo writes its own `media_metadata` row, then the summary row
  `model='primal'` `{meme, sfw, nsfw, csam, extra}`. The three thresholds are memoised procnodes
  today; they become config values (§11.2) and are passed as `extra` so the node ids still change
  when a threshold changes.
- **`analyze_video_2`**: `DB.import_video` (frames via ffmpeg → `video_frames`/`media_storage`), each
  frame downloaded from `media_storage.media_url` and run through `analyze_image_2` (OR-ing
  meme/nsfw/csam), then algo `2v` on `extract_video_beginning` (first 20 s) and `4` (video
  features); 10 s overall budget on the frame fetches.
- **`block_media`**: `@pnd purge_media_` (public, 24000+N logic) then `inc_counter(pubkey,
  "csam_block_count")`; at ≥ 3 and no `csam` filterlist row → `@pnd purge_user_content`, which POSTs
  `{func:"purge_user_content", message:"reason: …\npubkey: npub…"}` to the purger API (§11.5).
  **`block_porn_spammer`**: membership `filterlist` insert `(pubkey, 'pubkey', true, 'spam', now,
  'porn spammer detected by media analysis')`.
- **Infrastructure**: `ai_host_lock` (one in-flight call per `(host, selector)`), `parallel` with
  batch size 8, `send_warning_email` via ssh to <edge-proxy>, `update_media_metadata` /
  `update_media_embedding` / `update_text_metadata` writers. Text analysis (`ext_event`,
  `ext_event_batch`, algos 9/10, `TEXT_ALGOS`) is gated by `ENABLED=false` and is ported but stays
  off. Thin typed clients for Ollama (`/api/chat`, `/api/embeddings`) and the classifier/feature
  ports live in public `ocaml-common/media/ai_client`; prompts, thresholds and the decision logic
  stay private. Manual tools (`import_media_embeddings`, `refresh_media_metadata`,
  `refresh_text_metadata`, `check_image_nsfw`) become `primalctl ext media …`.

### 11.5 User content purger (`src/user_content_purger.jl`, 458 lines)

`purger_http` role on 0.0.0.0:22000: `POST /api` `{func:"purge_user_content", message}`; URL
extraction with `hxxps` de-fanging and the `PRIMAL_DOMAINS` list; `media_urls_to_files` over
`short_urls`, `media`, `video_thumbnails`, `media_uploads`; `purge_media_urls` via the public
`/purge-media` endpoint (`media_server_url`) + `HEAD` verification + Bunny purge; `scan_event`,
`insert_into_filterlist`, `purge_user_media` by pubkey / event id / URL; `dry_run` with the
fake-executor log returned in the response. Called by media analysis and by admins.

### 11.6 Other private pieces

`push_notifications.jl` TCP intake :20000 (`push_intake` role inside the importer binary; the rest
of push notifications is already in the public importer), `ext/App.jl` membership funcalls +
wallet proxies (`wallet.upstream`), `ext/DB.jl` reporting (already public in the importer; the
whitelist pubkeys from `test_pubkeys.jl` go into config), `crash-report-handler.jl` (route),
`init-api-request-replication.jl` (config), `event_syncer.jl` (dropped), `rate_limiting.jl`
(public `Rate_limit` in ocaml-common since the public API uses it too), `requeue-cdn-backlog.py`
(`primalctl media requeue`), `src/mcp_tools.jl` (`primalctl`).

Out of scope, decision needed: `src/wallet.jl` (2.7k lines, Strike/KYC/IAP python, ports
17000/19000, last commit 2024-07; `primal-spark-service` likely superseded it) and
`nostr_wallet_connect.jl`. If still live, it becomes `ocaml-ext/lib/wallet` (size L) on the same
kernel; until then the `wallet*` funcalls proxy to it via `wallet.upstream`.

---

## 12. Testing and parity

- **Unit** (alcotest): protocol framing, zlib `EVENTS`, kwargs decoders, kinds table, nip19,
  `feed_directive` grammar, advanced-search parser + SQL (existing corpora), OpenGraph injection,
  blossom auth, SigV4 vectors, node-id hash vectors, `for_mentiones`, langid accuracy, drain state
  machine, dedup set, relay URL sanitising.
- **Golden replay** (`primalctl replay`, port of `ws-replay`): corpus
  `<config-dir>/requests-sample-2.jsonl` (~42k requests), canonical JSON diff per
  funcall, allow-list for nondeterministic funcalls. Gate ≥ 99.5 % per funcall before flipping it.
- **Job parity**: for every DAG node/analytics key, a `compare` tool diffs rows produced by Julia
  (peer host DB) and OCaml (local) over the same segment, like the importer's `compare`.
- **Shadow**: `primal-api` on 9005 with mirrored traffic; `primal-jobs` on this host while the
  other hosts still run Julia (each host runs its own DAG against its own DB, so per-host cutover is
  natural).
- **Integration**: ws-connector `tests/integration_tests.rs` cases ported to alcotest
  (`PRIMAL_INTEGRATION=1`); importer `compare`; fetcher soak (8k relays, 24 h, fd/RSS flat).
- **Regression tests for incidents**: fd-leak counter (tsunami `test_kernel.ml:1868`), `file(1)`
  EPIPE, pool poisoning, drain under load (2k WS, running replay, zero errors).

---

## 13. Phases

Sizes are relative effort. Each phase ends with its parity gate.

| Phase | Deliverable | Gate | Size |
|---|---|---|---|
| **0** Workspace + `ocaml-common` (**done 2026-10-03**) | dune-workspace, flake, extraction §4.1, tsunami modules imported (ws_client, pg_listen, pool semantics; httpd and the richer http client follow in Phase 2 where they are first needed), membership ref DB script, `migrate.sh`, `primalnode_config*.jl` → `ocaml-common/config/primalnode-snapshot.json` (redacted; per-daemon JSON configs are written when each daemon's `Config.t` exists) | importer rebuilt on ocaml-common and redeployed, parity unchanged; `dune build @all` + `dune test` green | M |
| **1** Importer completion (**code done 2026-10-03**; cutover flags pending) | §7.1 gaps: `expire_scores` (flag `expire_scores_enabled`), `update_user_search`, `update_content_moderation_rules` + live-event notify, `add_human_override`/`get_trusted_followers_count`, ws-importer writes (live events with proof verification, follow packs, zap invoices, live mute lists); §7.2 import listener (`import_listener_port`, 12118 while Julia node 18 holds 12018) with per-event DAG indexers (`dag_index.ml`) and reply broadcasting (`Relay_broadcast`); Julia `App.IMPORT_EVENTS_LINE_SERVER` switch | `score_expiry` drains; hook decrements match Julia hosts; `import_events` from the Julia API node routed to the listener works | S/M |
| **2** Server kernel + lifecycle (**done 2026-10-04**) | `Http_server` (httpun-eio/gluten/httpun-ws; bounded outbound queue, size caps), `Listen` (one SO_REUSEPORT fd shared by N domains), `Lifecycle` (blocked signals + `Thread.wait_signal`, §6.3; concurrent drain controller), admin endpoint, `rebuild-restart-api.sh` (generations as transient units), `primalctl req/status/metrics/drain` (replay follows with Phase 3's parity work); `primal-api` on **9006** (9005 is taken by the ocaml-handlers shadow) answering `server_name`/`set_primal_protocol` natively and proxying the rest to Julia 8817 exactly like ws-connector (`set_primal_protocol` not forwarded, zlib for native answers only) | drain under load verified (20 clients: idle closed at once, active after 30 s grace, clients reconnect to the new generation, old exits); zlib frames inflate to the identical body (byte identity with ws-connector is impossible: flate2 emits stored blocks where zlib compresses; Julia uses zlib) | M |
| **3** Replace ws-connector (**3a done 2026-10-04**, **3b done 2026-10-04**; 3c pending) | 3a: the 17 ws-connector funcalls, live-event subscriptions (poll + LISTEN), `wsconnvars`, request log — identical to ws-connector on the compare set. 3b: the `ocaml-handlers` catalogue whose SQL exists in primal1 — 32 more funcall names native (48 in `Funcall.t`), `Moderation` = port of `content_moderation_filtering_2` (incl. the default rules for requests without `user_pubkey`); 52/54 identical to Julia, the rest documented in `ocaml-api/README.md` (ocaml-handlers SQL was wrong in four places and was replaced by plain statements; what stays proxied and why is listed there). 3c: `primalctl replay` (done 2026-10-04: corpus → A/B multiset compare, per-funcall table, mismatch report; read-only funcalls only) measured 7.2k real requests at 99.6 % identical with every native funcall ≥ 99.0 % and the residue classified in `ocaml-api/README.md` (deliberate deviations, moving counters, Julia partial responses); cutover A done 2026-10-04 on <stage-host> (the dev.primal.net endpoint; ws-connector 9001 stopped, `ocaml-api/cutover-9001.sh`), soak until 2026-10-11, then the public cache hosts <production-host>/<production-host>/<production-host> | replay ≥ 99.5 % per native funcall; one week on one host | L |
| **4** Julia-heavy funcalls (4a done 2026-10-04: push subscriptions `notification_counts(_2)`, `directmsg_count(_2)`, `net_stats`, `rebroadcasting_status`; `get_notifications`, `set_notifications_seen`, `notifications`; the non-`cache` REQ filters. 4b done 2026-10-04: `scored_content` port — `explore`, `explore_global_*`, `scored_users(_24h)`, `trending_hashtags*`, `explore_zaps/people/topics/legend_counts`, the explore ids of the mega feeds; rolling restart now closes the listener on drain. 4c done 2026-10-04: the long tail — direct messages, zap feeds, event actions, followers, follow lists, replaceable events, settings, reports, relays, trusted users, articles, long-form thread view, highlights, feed_2 — and the in-memory `response_messages_for_posts` port behind enrich_feed_events/note_mentions. 4d done 2026-10-04: advanced search — PEG-equivalent parser, `to_sql` builder, cursor-based windowed `fetch_results`; `advanced_search`/`advanced_feed`/`parse_advanced_search_query` and every search-backed mega-feed id; 1000/1000 identical. 4e done 2026-10-04: the remaining readers — `search` forward, `explore_media`, `get_advanced_feeds`, `get_filterlist`, `get_recommended_reads`, `trending_images(_4h)`, DVM feed readers, `nostr_stats`; left proxied: `set_app_settings`, `search_filterlist`, `dvm_feed`, the importer/relay/nip46/upload/push writes and the membership funcalls) | feed/mega family, explore/trending (+plpgsql), advanced search parser + builder, `get_notifications` budget, outbound relay funcalls, broadcasters, non-`cache` filters, HTTP `/api`, membership funcalls from `ext/App.jl`; `Fallback_proxy` deleted | `proxied_funcalls` empty on shadow; compiler flags any `Proxied` leftover | L |
| **5** HTTP services | 14000+N, 24000+N, Blossom with reconstructed upload import, S3/CDN clients, link preview | curl golden tests vs Julia; Blossom client suite; identical `media_uploads`/`media_storage` rows | M |
| **6** Jobs daemon, non-media | DAG runner + 13 nodes, trustrank, analytics, DVM checker, pg listener, failover/monitoring, rebroadcast; per-role flags flipped host by host while Julia node 18 keeps the others | per-node row parity vs a Julia host over identical segments; `pubkey_trustrank` rank correlation ≥ 0.999; analytics JSON golden | L |
| **7** Fetcher | `primal-fetcher` on 9000+N with resume files, archive writer, firehose server; Julia fetcher stopped per host | 24 h soak: importer `recv` rate and `cache_any` unchanged vs Julia fetcher; RSS budget | M |
| **8** Media role | procgraph executor with all tasks, uploads, analysis, HLS providers, purger :22000; Rust `primal-media` stopped on the media host | node-id hash test; variant/preview outputs byte-compared for a sample; backlog drains; `requeue-cdn-backlog.py` still works | L |
| **9** Private extensions (`ocaml-ext/`) | registration points landed in public code during 3–8; `ocaml-ext` with Studio (`studio_operation`, SQL migrations, scheduled/RSS broadcasting, RSS importer), purger :22000, media analysis tasks + upload hook, push intake :20000, membership/wallet/crash-report funcalls; production binaries built from `ocaml-ext/bin`; Rust `rss-content-importer` and `studio/` stopped | `studio_operation` replay parity per op; one week of scheduled/RSS broadcasts with identical status rows; purger dry-run output identical on a corpus of past messages; analysis decisions identical on a sample | M/L |
| **10** API cutover | `primal-api` (ocaml-ext build) binds 8800+N / 14000+N / 24000+N / 21000+N on every host; Julia API nodes retired; `deploy.sh` replaced by the scripts + `/readyz` LB checks | replay parity on every host; dashboards unchanged | S/M |
| **11** Julia importer retirement | with 1, 6, 8, 9 done, `start_media_importer_2.jl` (node 18) stops; `EVAL` ports gone; DVM provider decided and ported if live | all §1.3 producers verified from OCaml daemons for a week | S |
| **12** Deletion (§15) | remove Julia/Rust/Python/C from both repos, old SQL loaders, docs updated (`CLAUDE.md`, `README.md`, parent `AGENTS.md`) | both repos build with `dune build @all` only; nix flake is `ocaml-common/flake.nix` | S |

Phases 1, 2 and 6 can start in parallel after 0; 7 and 8 are independent of 3–5; 9 starts as soon
as the first registration point exists (Studio's `studio_operation` can ship right after Phase 3).

---

## 14. Risks and open questions

1. **Config not in repo** (`primalnode_config*.jl`, media/wallet host configs, nginx/LB rules that
   read `/tmp/wsconn_blocked`). Phase 0 collects them; secrets become files.
2. **Blossom upload path missing at HEAD**; **`ext_after_import_upload_2` nodes have no executor**;
   confirm production reality before porting (check `processing_nodes` backlog on the media DB).
3. **Client-visible quirks** (zlib frames binary, NOTICE texts, kind collisions, pretty `nostr.json`,
   `PARTIAL_RESPONSE` scope): the replay corpus is the arbiter; no silent fixes.
4. **Fetcher scale in one process** (8k TLS WebSockets): measure tls-eio session memory in a spike;
   fallback is sharding relays across two fetcher processes by hash (both feed the same firehose
   subscribers via a tiny fan-in) — still OCaml.
5. **Language detection** quality for `reads.lang`: gate the trigram classifier against the
   existing labelled rows; if insufficient, a small ONNX-free option is `cld3`-style profiles, or
   store `lang` only when confidence ≥ threshold (as Julia does with `lang_prob`).
6. **Dynamic SQL** (advanced search, DAG table names): confined; golden `EXPLAIN` tests in CI.
7. **Per-domain pools**: no work stealing; size from measured concurrency; expose pool wait.
8. **No job framework**: jobs are plain loops as in Julia. If a job later needs retries or
   cross-host distribution, that is a separate decision; nothing in this plan depends on it.
9. **Membership failover** moves from "every Julia process may promote" to one singleton; verify the
   discovery JSON contract with whoever operates it.
10. **Security changes bundled** (sign-off): `EVAL`/`EXPR` ports disappear; `/api`, 24000+N, 22000
    remain unauthenticated on the internal network as today; secrets leave the config files.
11. **Memory/GC**: tsunami sets nothing; Primal's API at 10k connections and the trustrank graph
    (1.4M nodes) need measurement; set `OCAMLRUNPARAM=s=…,o=…` per daemon from the spikes.

---

## 15. Deletion checklist (Phase 12)

Delete only after every producer in §1.3 has been verified running from OCaml for a week on every
host, and after a final grep of all databases for `pg_primal` functions and `plpython` callers.

- Rust: `ws-connector/`, `primal-cache/`, `primal-media/`, `pg_primal/` (+ `DROP EXTENSION pg_primal`
  after confirming no callers); parent `push-notification-sender/` stays until its JSON-lines protocol
  is ported into the importer (optional, separate decision), `rss-content-importer/` is parent-repo.
- Julia: `src/`, `*.jl` at root, `dev/`, `ext/`, `Project.toml`, `Manifest.toml`, `pkg.jl`,
  `precompile*.jl`, `flake.nix`/`flake.lock`/`shell.nix` (Julia), `pgext/`, `pljava/`, `pgdir/`,
  `pgdata/` (if a dev artifact), `utils.vim`.
- Python/C: `s3.py`, `link-preview.py`, `har-analyze.py`, `bech32.c`, `libbech32.so`, `bech32/`,
  `Makefile`.
- Data files kept: `relays*.txt`, `default-relays.json`, `default-settings.json`, `nostr.json`,
  `sql/` (functions split into `ocaml-common/sql/migrations`, dumps kept as reference),
  `pgfuncs1.sql`, `multikindfeed-index.sql` (as migrations), `adv-search-queries.json` (tests),
  `docs/`, `TRENDING-BOOSTING-ANALYSIS.md`.
- `<config-dir>/ocaml-handlers` and `tr_sorted.jls` retired; `primalnode_config*.jl`
  replaced by the JSON configs.
- Parent repo (`primal-net-server`, after Phase 9): `src/*.jl`, `ext/*.jl`, `start_*.jl`, `load*.jl`,
  `*.jl` at root, `Project.toml`/`Manifest.toml`, `studio/` (Rust stub), `rss-content-importer/`
  (Rust), the wallet/IAP Python scripts once the wallet decision is made, `send-eval-request-to-julia.py`,
  `requeue-cdn-backlog.py` (after `primalctl media requeue`). Kept: `sql/` (as `ocaml-ext/sql`
  migrations), `pg-*.sql/.sh` replication scripts, `maintanance.sh`, `deploy.sh` → rewritten to call
  the rebuild-restart wrappers, `push-notification-sender/` (Rust, JSON-lines subprocess; porting it
  into the importer is a separate small decision).

## 16. Immediate next steps

1. Review §2 decisions (notably §6 restart protocol, §10.1 keeping `processing_nodes`, §11.1
   registration points as the public/private seam, §11.6 wallet).
2. Phase 0: `ocaml-common/`, importer on it, tsunami modules imported, config snapshot.
3. Phase 1 in parallel: `expire_scores` (live bug) and the import listener.
4. Spikes: 8k-relay fetcher memory; httpun-ws under 10k connections with zlib frames.
