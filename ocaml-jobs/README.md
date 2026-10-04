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
| `dag` | `dag_runner.jl` + 13 nodes | planned (6d) |
| `failover`, `rebroadcast`, `dvm_provider` | `postgres.jl`, `event_rebroadcasting.jl`, `dvm_service_provider.jl` | planned (6e) |

## Notes

- The DVM checker counts only the answer's own notes/articles; Julia counted the kinds in the full
  `dvm_feed` response, which also carries quoted/referenced notes, so Julia's `ok`/`kind` could
  flip on a feed whose own posts are not in the cache but whose references are.
- Push notifications for live events are not sent from here (the OCaml importer runs with
  `push_notifications_enabled` false on this host, as Julia node 18 does).
