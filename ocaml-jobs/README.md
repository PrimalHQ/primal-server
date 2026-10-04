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
| `trustrank` | `trustrank_maker.jl` | planned (6b) |
| `analytics` | `App.precalculate_analytics` | planned (6c) |
| `dag` | `dag_runner.jl` + 13 nodes | planned (6d) |
| `failover`, `rebroadcast`, `dvm_provider` | `postgres.jl`, `event_rebroadcasting.jl`, `dvm_service_provider.jl` | planned (6e) |

## Notes

- The DVM checker counts only the answer's own notes/articles; Julia counted the kinds in the full
  `dvm_feed` response, which also carries quoted/referenced notes, so Julia's `ok`/`kind` could
  flip on a feed whose own posts are not in the cache but whose references are.
- Push notifications for live events are not sent from here (the OCaml importer runs with
  `push_notifications_enabled` false on this host, as Julia node 18 does).
