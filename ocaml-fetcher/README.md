# ocaml-fetcher — the relay fetcher and firehose (`primal_fetcherd`)

OCaml 5 / Eio port of the Julia fetcher process (`start_fetcher.jl`): `fetching.jl`
(`Fetching`), `firehose_server.jl` (`FirehoseServer`) and the message archive of
`DB.DeduplicatedEventStorage` (`cache_storage.jl`), as one daemon configured by one JSON file.
Phase 7 of `../ocaml-plan.md` (§8 there).

## What it does

| Julia | here |
| --- | --- |
| `Fetching.load_relays` (relays-active.txt verbatim; relays.txt, relays-paid.txt, relays-mined-from-events.txt, relays-mined-from-contact-lists.txt through `sanitize_valid_relay_url`), `start_fetcher.jl`'s extra relay | `Relay_set.load_files`, `Relay_url` (URIs.jl semantics: lowercase host, default port dropped, `normpath` + trailing slashes stripped, `.onion`/IPv6/localhost dropped, a query or fragment drops the url). The set is identical to Julia's for the current files (`bin/relays_dump.exe` vs `Fetching.relays`). |
| `Fetching.start_relays_from_db`: `fetcher_relays` polled every 1 s (`updated_at >=` previous poll), urls > 300 chars / unparsable / private IPv4 skipped | `Relay_set.db_poller` |
| `nostr_fetch_events` per relay: connect (30 s), REQ `{since}` and REQ `{since, authors 00..ff}`, read, `since = min(now, max(since, created_at-1))`, backoff 1 s doubling to 300 s (1 s again after a connection that produced messages), SOCKS5 proxy (`socks5h`, remote DNS) | `Relay_conn` fiber per relay, spread over `num_domains` domains by url hash; `Ws_client` with 30 s connect and read timeouts |
| envelope `[time(), {func, runid, relay_url, timeout, proxy, event, …}, m]` for started / connected / request / event / exception / sleep | `Julia_json.envelope`, the timestamp in Julia's Float64 repr (`1.791140507318978e9`) |
| `latest_timestamp` per relay under `$STORAGE/primalnode$N/fetcher/<url with non-alphanumerics → _>/`, saved at most every 5 s | `Resume`: same path and escaping, tmp + rename; all saved at stop |
| `DeduplicatedEventStorage`: id seen before → skipped (`seenearly`); else parse, verify (`created_at < now+300`, id, signature), append to `dedup/messages/YYYY/MM/DD.log` (UTC day of created_at), remember, broadcast | `Processor` on its own domain: `Dedup` (in-memory ids for `dedup_keep_s`, 6 h, replacing the 256 SQLite shards), `Archive` (same files, line per event, files closed after 2 min idle), `Firehose.broadcast` |
| `Fetching.message_processors[:firehose_server]`: every raw relay message also broadcast | `firehose_forward_raw` (see "Deviations") |
| `FirehoseServer` on `127.0.0.1:9000+N`: `STREAM-NEW-EVENTS` subscribers, `Channel(20_000)` drop-when-full, `bye` at stop | `Firehose`: per-subscriber bounded queue, batched writes, `bye` at stop; other lines ignored |
| `PushGatewayExporter` job `fetcher<N>`: `fetcher_message_count`, `fetcher_exception_count`, `fetcher_chars_received`, `fetcher_chars_sent` every 15 s; `dedup/stats.json` | the same metrics (+ `fetcher_relays_total/connected`, `fetcher_new_events`, `fetcher_firehose_dropped`, `fetcher_rss_bytes`); `stats.json` keys `seen`, `seenearly`, `parseerr`, `verifyerr`, `any` continue from the Julia totals |
| `Fetching.fetch` ad-hoc REQ fan-out | not ported (off in production) |

## Layout

```
lib/config.ml       the JSON config (every key required)
lib/relay_url.ml    URIs.jl-equivalent sanitising
lib/relay_set.ml    relay files, fetcher_relays poller, dispatch to domains
lib/relay_conn.ml   the per-relay loop and the envelope
lib/processor.ml    dedup → verify → archive → firehose
lib/dedup.ml        time-bounded id set
lib/archive.ml      messages/YYYY/MM/DD.log writer
lib/firehose.ml     the STREAM-NEW-EVENTS server
lib/resume.ml       latest_timestamp files
lib/stats.ml        counters, stats.json
lib/julia_json.ml   Julia Float64 repr for the envelope timestamp
lib/admin.ml        /healthz /readyz /status /relays /tasks, POST /gc /stop
bin/primal_fetcherd.ml   the daemon
bin/firehose_tap.ml      subscribe to a firehose and count (comparison tool)
bin/relays_dump.ml       print the relay set a config loads
rebuild-restart-fetcher.sh   build + stop-then-start as systemd --user unit primal-ocaml-fetcher
```

## Configuration

| key | meaning (Julia) |
| --- | --- |
| `node_idx` | PRIMALSERVER_NODE_IDX |
| `admin_host`, `admin_port` | admin HTTP |
| `firehose_host`, `firehose_port` | FirehoseServer HOST/PORT (127.0.0.1, 9000+N) |
| `state_dir` | Fetching.EVENTS_DATA_DIR (`$STORAGE/primalnode$N/fetcher`) |
| `archive_dir`, `archive_enabled` | DeduplicatedEventStorage rootdirectory (`$STORAGE/primalnode$N/dedup`) |
| `relays_dir`, `relays_file` | directory of the relays-*.txt files; PRIMALSERVER_RELAYS override |
| `extra_relays`, `no_proxy_relays` | `push!(Fetching.relays, "ws://<internal-relay-host>:7777")`, `.proxy = nothing` |
| `proxy` | PRIMALSERVER_PROXY (`socks5h://host:port` or null) |
| `fetcher_since` | PRIMALSERVER_FETCHER_SINCE (null = now) for relays without a resume file |
| `timeout_s`, `base_delay_s`, `max_delay_s` | TIMEOUT 30, BASE_DELAY 1, MAX_DELAY 300 |
| `dead_relay_max_delay_s` | backoff cap for relays that never delivered a message (3600) |
| `connect_concurrency` | simultaneous connection attempts per domain (256) |
| `cache_db`, `relays_db_poll_s` | fetcher_relays polling (null disables) |
| `pushgateway`, `metrics_period_s` | `{host, port, job}` (job `fetcher<N>`), 15 |
| `num_domains` | domains for relay connections (8) |
| `dedup_keep_s` | in-memory dedup window (21600) |
| `firehose_forward_raw` | also forward every raw relay message (Julia behaviour; false in production here) |
| `firehose_queue` | per-subscriber queue (20000) |
| `log_connections` | reserved |

## Deviations from the Julia fetcher (deliberate)

- **Julia never ran most of its relays.** `HTTP.ConnectionPool.default_connection_limit[] = 10000`
  capped the whole process at 10k connections; with ~61k relays (files + `fetcher_relays`) the
  other tasks waited on the pool, so the Julia firehose carried events from ~320 relays and a
  few reconnects per minute. This fetcher connects to every relay. To keep that from flooding the
  SOCKS proxy with the attempts of ~55k dead relays, attempts are limited per domain
  (`connect_concurrency`) and a relay that has never delivered a message backs off to
  `dead_relay_max_delay_s` (1 h) instead of 300 s. Relays that have delivered keep Julia's schedule.
- **The firehose carries each new verified event once** (`firehose_forward_raw: false`). The Julia
  wiring broadcast every raw relay message AND every new event a second time; with every relay
  connected that raw stream is ~25k lines/s (90 % duplicates), i.e. ten times what the Julia
  fetcher sent, for the same ~600–700 distinct events/s. The importers only act on new EVENTs, so
  `cache_any` is unchanged; `recv` on the importer drops and `rej`/`dup` go to ~0.
- Dedup is a 6 h in-memory window, not the all-time SQLite set: an event re-sent after 6 h is
  archived twice and reaches the importer again (rejected there by `ON CONFLICT`).
- The firehose ignores non-`STREAM-NEW-EVENTS` lines instead of dispatching them (the fetcher's
  Julia server had no processors registered).
- `Ws_client` now shrinks its read buffer after a frame over 64 KB (otherwise each long-lived
  connection kept its largest frame's buffer forever).

## Shadow comparison and cutover (<stage-host>, 2026-10-04)

Shadow run (port 9027, own state/archive dirs, `since = now`) next to the Julia fetcher,
`firehose_tap` on both for the same 180 s:

| | Julia 9017 | OCaml 9027 |
| --- | --- | --- |
| lines/s to the firehose | 2330 | 601 |
| distinct event ids/s | 557 | 601 |
| relays contributing | 272 | 1613 |
| ids only on this side | 12127 (a sample: 1–12 h old re-fetches from stale resume points, 453 seen earlier by the shadow) | 20022 |
| relays connected | ~8000 fds (mostly idle) | 15500 |
| RSS / CPU | 5.7 GB / ~1 core | 3.5 GB / ~3.5 cores at ~50k relay msgs/s |

Cutover at 20:02: `m1_fetcher.sh` loop and the Julia process stopped, the daemon started on 9017
with the production state and archive dirs (it resumed from Julia's `latest_timestamp` files; the
OCaml importer reconnected within a second). `stats.json` continues the Julia totals.

**Rollback:** `systemctl --user stop primal-ocaml-fetcher`, then in the `primal-server` dir
`PRIMALSERVER_PROXY=socks5h://<socks-proxy-host>:1080 bash ../m1_fetcher.sh` (the proxy variable was in
the old shell's environment, not in the script); it resumes from the same resume files.

## Incident 2026-10-05 and the watchdog

At 00:52:37 UTC every relay connection through the SOCKS proxy (`<socks-proxy-host>:1080`) went silent at
once (messages 32k/s → 7/s within 30 s, "connected" unchanged: half-open TCP). From 00:53:05 to
04:52:20 the whole process was frozen: no stats lines, the admin port did not answer, the importer
received nothing. It resumed by itself, then reconnected slowly (16.6k → 4.8k relays by 06:00, the
rest in the dead-relay backoff), with RSS at 10.8 GB (2.6 GB after a fresh start). Restarted at 08:08.
Root cause still open; suspects are a stop-the-world GC blocked by a domain stuck in a blocking
call, and the memory growth. Because the admin port froze too, the guard is external:
`watchdog.sh` runs from the transient user timer `primal-fetcher-watchdog` every 2 minutes and
restarts the unit after two consecutive checks where `/status` does not answer or
`message_count` has not moved (log `$PRIMAL_VAR_DIR/fetcher-watchdog.log`).

## Memory (2026-10-05)

With 16.6k relay connections the process sat at 7.5 GB RSS of which only 2.1 GB was OCaml heap.
The WebSocket read buffers (Bigarrays, now accounted as `ws_read_buffers_bytes` / `ws_clients` in
`/status` and `wsbuf` on the stats line) are a small part: 21 KB per connection, 353 MB in all.
The rest was glibc malloc arena fragmentation across the 9 domains: restarted with
`MALLOC_ARENA_MAX=2` the same 16.6k connections cost 3.6 GB RSS (1.4 GB outside the heap), so
`rebuild-restart-fetcher.sh` now sets it by default (`PRIMAL_MALLOC_ARENA_MAX` overrides). Per
connection: about 130 KB of heap (TLS engine state, fibers, parsed frames) plus 90 KB outside it.
Whether the remaining figure grows at a constant connection count is still to be measured over a
day (the overnight 10.8 GB was seen after a reconnect storm, not at steady state).

## Operating

- `./rebuild-restart-fetcher.sh` — build + restart (unit `primal-ocaml-fetcher`,
  `LimitNOFILE=262144`, `MemoryMax=12G`).
- `curl -s http://127.0.0.1:<admin_port>/status` — relays (providing|connected|total), rates,
  counters, dedup size, RSS/heap; `/relays` per relay; `POST /gc` compacts and reports.
- Rollback to Julia: stop the unit, start `m1_fetcher.sh` again (it resumes from the same
  `latest_timestamp` files).
