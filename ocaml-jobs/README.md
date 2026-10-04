# ocaml-jobs — primal-jobs

The background jobs daemon (ocaml-plan.md §9): one process, roles enabled by config, each role one
fiber running the loop its Julia module ran. Config is one JSON file
(`$PRIMAL_CONFIG_DIR/primal-jobs-config.json`, every key required); `rebuild-restart-jobs.sh`
builds and restarts the transient unit `primal-ocaml-jobs` (stop then start: roles are singletons).
Admin HTTP on `admin_host:admin_port`: `/healthz`, `/readyz`, `/status`, `/tasks`, `POST /stop`.
Log: `$PRIMAL_VAR_DIR/ocaml-jobs.log`.

## Roles

| Role | Julia | Status |
|---|---|---|
| `dvm_checker` | `dvm_feed_checker.jl` | **native (6a, 2026-10-04)**: every `dvm_check_period_s`, each content-discovery DVM handler of the last 90 days gets the NIP-90 request (`Primal_common.Dvm_client`, shared with the API's `dvm_feed`) with the requester key, randomized start delays, `dvm_parallel` at a time; `dvm_feeds` upserted with the ids of the first 20 notes/articles of the answer that exist in the cache, `kind` notes/reads by majority, `ok` when any. Runs safely next to Julia's checker (same upserts). |
| `pg_listener` | `cache_storage_pg_listener.jl` | **native (6a)**: `LISTEN cache_storage`; a live_event payload notifies the host's followers once per event (`live_event_notification_created`), unless blocked, rate-limited to one per host/follower per `pg_listener_rate_limit_s`, and only when `live_feed_is_hidden` allows, through the importer's notification writer (`primal_importer` is linked). Safe next to Julia's listener: the dedupe row stops the second process. |
| `trustrank` | `trustrank_maker.jl` | **native (6b, 2026-10-04)**: every `trustrank_period_s` (3 h; Julia waits one period first, `trustrank_run_at_start` skips that) the follow graph is read once through a cursor from `pubkey_followers` into CSR arrays (67 M edges, 7.6 M nodes, ~2 min), personalized PageRank from the verified seeds (α 0.85, 20 iterations, spam/csam pubkeys zeroed, ranks > 0 kept), written in 10k-row batches to `pubkey_trustrank_new` and swapped under the live name with the dependent view recreated — or to `trustrank_target_table` when that is not `pubkey_trustrank` (shadow). Shadow run vs Julia's table: top-100 identical, top-10k 99.9 %, median rank difference 0.4 %, humaness threshold within 0.5 %. |
| `analytics` | `App.precalculate_analytics` | **native (6c, 2026-10-04)**: every `analytics_period_s` the sixteen selectors run through the API's `scored_content` (the `primal_api` library with `api_config_path`), are filtered to the client kinds, notes of the gaming-detection selectors get `[G] ` when the Ollama classifier (`ollama_host`, gemma3n:e4b) answers yes, and land in `cache` as `precalculated_analytics_<selector><analytics_key_suffix>`; then `explore_topics`. The gaming report goes to `gaming_report_command`'s stdin. Shadow keys (`_ocaml`) vs Julia's: identical note sets up to the minutes between the runs. |
| `dag` | `dag_runner.jl` + 13 nodes | **native (6d, 2026-10-04), live on <stage-host>**: `Dag` runs the DAG_20240803_1 pipeline every `dag_period_s` over `[since, now]`, splitting each node's window into the imported_at segments `coverages_1_8656fc443b` has not covered (1-day or 90-day steps, `dag_tasks` in parallel, a_tags sequential with 8 parallel workers), every segment in its own transaction, coverage recorded after it. Nodes: basic_tags, zap_receipts, poll_stats, a_tags, reads (5 phases; `Langid` gives lang/lang_prob), pubkey_media_cnt, pubkey_content_zap_cnt, advsearch (30 days), event_mentions, note_length (15 days), note_stats (30 days), update_user_search (3 days); the per-event indexers are the importer's `Dag_index`. `dag_dry_run` rolls every segment back and writes no coverage (`dag_dry_run_window_s` exercises all nodes once over the last N seconds); the hour-long dry run passed before the switch. Metrics `dag_runner_duration`/`dag_runner_all_ok` go to `pushgateway`. |
| `rebroadcast` | `event_rebroadcasting.jl` | **native (6e, 2026-10-04), off by default**: `Rebroadcast` polls membership `event_rebroadcasting` every second; each started-unfinished row gets its next batch (up to 100 of the user's events since `event_created_at`, `kinds` filtered, replaceable kinds collapsed to the latest — `App.get_user_events`) broadcast to `target_relays` (one connection per relay, 10 events/s, done when every event has an OK or after 30 s), `event_idx_intermediate` on each first accept, `last_batch_status` as Julia's `JSON.json(res, 2)`, the row advances on success and finishes when a batch repeats (same sha256). Julia's `EventRebroadcasting` is not running on <stage-host>'s nodes and its host is not known from here, so this role is not in `roles` yet: enabling it while Julia's runs elsewhere would send every batch twice. Verified only idle (0 pending rows). |
| `failover` | `postgres.jl` server_tracking (membership) | **native (6e, 2026-10-04), off by default**: `Failover` takes a Postgres advisory lock on the membership DB (singleton), then every second reads `membership_discovery_url` ({"primal": connstr, "postgres": connstr}) and, when that host answers `pg_is_in_recovery()`, calls `pg_promote()`. Re-pointing the daemons' own pools at a new primary is not done yet (the Julia nodes still run their tracker; this role stays off until they are retired). |
| `media` | Rust `primal-media` scheduler + Julia `ProcessingGraphExecutionScheduler` + the media nodes (`cache_storage_media.jl`, `media.jl`, `app_media.jl` `import_upload_3`, `internal_services.jl` `purge_media_`, MediaAnalysis `block_media`/`inc_counter`) | **native (8a, 2026-10-04)**: `lib_media/` — `Pgj` (typed Julia JSON, binary cache, node ids), `Procgraph` (executor: atomic claims with `for update skip locked`, ancestry edges, extra/log, cleanup), `Proc` (Eio.Process with deadlines, LD_LIBRARY_PATH stripped), `Media_tools` (downloads with proxy rotation and the 2 GB cap, file/identify/ffprobe/exiftool/ffmpeg/magick, link-preview.py, AI feature endpoints), `Media_store` (v1 key-addressed and v2 sha-addressed layouts, local + S3), `Hls` (AWS MediaConvert over SigV4 with endpoint discovery, Mux, Bunny Stream, Cloudflare Stream), nodes in `Nodes_media`/`Nodes_upload`/`Nodes_moderation`/`Nodes_text`, `Scheduler` (the Rust task list at `max_concurrent_per_name`, the Julia duties `import_upload_3`/`block_media`/`purge_media_` at `julia_duty_concurrency`, 60 s stats, stuck reset, `pn_time_for_pubkeys` refresh every 600 s). Config: the `media` object (table below). `bin/media_tool.exe CONFIG check-ids|execute-node|show-node|pending`. Private nodes (`ext_after_import_upload_2`, `analyze_*`, `purge_user_content` without a purger URL) are never claimed. |
| `failover`, `rebroadcast`, `dvm_provider` | `postgres.jl`, `event_rebroadcasting.jl`, `dvm_service_provider.jl` | planned (6e) |

| key | meaning |
| --- | --- |
| `pushgateway` | optional `{host, port, job}`: `dag_runner_duration` / `dag_runner_all_ok` after each DAG run |
| `membership_discovery_url` | optional; the membership server's `tracking_url` (used by the `failover` role only) |

## The `media` config object

| key | meaning |
| --- | --- |
| `binary_data_cache_dir` | ProcessingGraph.BINARY_DATA_CACHE_DIR (shared with the blossom server) |
| `media_path`, `media_path_2`, `media_url_root`, `tmp_dir` | Media.MEDIA_PATH / MEDIA_PATH_2 / MEDIA_URL_ROOT / MEDIA_TMP_DIR |
| `proxies`, `metadata_proxy`, `download_timeout_s` | Media.DOWNLOAD_PROXIES (rotated), MEDIA_METADATA_PROXY (link-preview.py), 30 s |
| `strip_image_metadata` | primal-media's flag |
| `s3_providers` | `{name, bucket, bucket2, endpoint, region, domain, access_key, secret_key}` (S3_CONFIGS) |
| `hls_providers`, `hls_processing_timeout_s` | primal-media's list (`type`, `enabled`, keys, region, library_id, cdn_hostname, role_arn, s3_output_bucket/path, abr_profiles) |
| `media_paths`, `media_paths_2` | Media.MEDIA_PATHS / MEDIA_PATHS_2: `{uploadfast, upload, cache}` of `{type:"local", host, path}` or `{type:"s3", provider, dir}` |
| `ai_host`, `ai_timeout_s` | ollama 11434 and the feature endpoints 5013/5014 |
| `blossom_host` | Media.BLOSSOM_HOST (media_import_2's return) |
| `ffmpeg_remote_host` | optional ssh host running ffmpeg for variants |
| `python_path`, `link_preview_script` | for import_preview_pn |
| `scheduler_period_s`, `max_concurrent_per_name`, `julia_duty_concurrency`, `refresh_matview_period_s` | 1, 200 (Rust), 10 (Julia), 600 |
| `cloudflare_cache` | `{zone_id, api_key}` for purge cache invalidation (null = off) |
| `blossom_hosts`, `upload_url_root` | purge_media_'s blossom hosts and `https://_media.primal.net` |
| `user_content_purger_api` | MediaAnalysis.USER_CONTENT_PURGER_API (null = `purge_user_content` nodes are not claimed) |
| `execute_funcs` | the funcs this executor claims (null = the default list) |
| `log` | per-node log lines |

## Cutover state on <media-host>, the media host (2026-10-04)

The OCaml tree on <media-host> is the git worktree `<config-dir>/primal-server-ocaml5`
(branch fetched from <stage-host> over ssh into `refs/remotes/<stage-host>/ocaml5`); it builds with
`PRIMAL_BUILD_PGHOST=<stage-host>` because the `[%pgsql]` checks need <stage-host>'s schema. The unit
`primal-ocaml-jobs` there runs `roles: ["media"]` with `execute_funcs` = the Rust scheduler's list
(`import_media_fast_pn`, `import_media_fast_pn_2`, `import_media_pn`, `import_preview_pn`,
`import_media_hls_pn`, `import_text_event_pn`), `MemoryMax=30G`. Rust `primal-media` is stopped: the
interactive zsh that looped `timeout 1800 systemd-run ... primal-media run-processing-graph-scheduler`
is SIGSTOPped (`kill -CONT` it and it restarts the Rust scheduler — the rollback). Julia node 18's
`ProcessingGraphExecutionScheduler` keeps `import_upload_3`, `block_media` and `purge_media_`: its
`import_upload_3` runs the private CSAM/NSFW analysis inline, which the public build only has a hook
for (`Hooks.after_import_upload`, filled in Phase 9). Node ids: `media_tool check-ids` on <media-host> showed
every Julia/blossom-created node matching the Julia-style hash and every Rust-created node the
sorted-key hash. First hour: all claimed queues at 0 pending; failures are download errors (403/404/
timeouts) as before. `<tmp>/cache/procgraph` is shared with the blossom server.

## Cutover state on <stage-host> (2026-10-04)

Julia node 18 no longer runs: the DAG runner (`DAGRunner.stop()`), the DVM feed checker, the
TrustRank maker, the PG listener and `precalculate_analytics` (`unregister_cached_function`); the
jobs daemon runs all five (`roles` in the config). The Julia API node 17 used to receive the DAG
output table names from node 18 over rex after every run; `primalnode_config.jl` now includes
`<config-dir>/dag_outputs_pinned.jl` (the last pushed value) so a Julia API restart
keeps working. **Rollback** of any role: stop primal-jobs (or remove the role), then in the node 18
REPL `DAGRunner.start()`, `DVMFeedChecker.start()`, `TrustRankMaker.start(cache_storage)`,
`CacheStoragePgListener.start(cache_storage)`, `App.register_cache_function(:precalculate_analytics,
App.precalculate_analytics, 600)`. Two DAG runners must never run at once (additive nodes).

## Notes

- The DVM checker counts only the answer's own notes/articles; Julia counted the kinds in the full
  `dvm_feed` response, which also carries quoted/referenced notes, so Julia's `ok`/`kind` could
  flip on a feed whose own posts are not in the cache but whose references are.
- Push notifications for live events are not sent from here (the OCaml importer runs with
  `push_notifications_enabled` false on this host, as Julia node 18 does).
