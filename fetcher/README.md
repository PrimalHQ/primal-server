# fetcher: primal-fetcher (`primal_fetcherd`)

The relay fetcher. It keeps a WebSocket subscription open to every known Nostr relay, verifies and
deduplicates the events they send, and streams each new event once to its subscribers (the
importers) over the firehose, a line-oriented TCP server. Optionally it archives every new event
to daily log files. One process, configured by one JSON file; OCaml 5 / Eio.

The earlier Julia implementation is in the git tag `julia-final`.

## What it does

### The relay set

At start the relay URLs come from files, then the set grows from the cache DB:

- `relays_dir` (normally this directory's [`relays/`](relays)): `relays-active.txt` is taken
  verbatim; `relays.txt`, `relays-paid.txt`, `relays-mined-from-events.txt` and
  `relays-mined-from-contact-lists.txt` are sanitised first (below). `relays_file`, when set,
  replaces all of them (one URL per line, verbatim).
- `extra_relays` are appended.
- With `cache_db` set, the `fetcher_relays` table is polled every `relays_db_poll_s` for rows whose
  `updated_at` is at or after the previous poll. URLs over 300 characters, unparsable ones and those
  whose host is a literal private or loopback IPv4 address are skipped.

Sanitising (`Relay_url.sanitize_valid`): only the first line of the value is used; the host is
lowercased and stripped of spaces and of a trailing dot, the scheme lowercased, the default port
(`ws` 80, `wss` 443) dropped, `.` and `..` path segments resolved and trailing slashes removed.
URLs are dropped when empty, ending in `.onion`, carrying a query or fragment, having an IPv6
literal host, `localhost` or `127.0.0.1`, or a scheme other than `ws`/`wss`.

A relay is identified by its sanitised URL, so `wss://x/` and `wss://x` are one relay; the
first spelling seen is the one connected to and names its resume file. Per host (`host[:port]`)
the root URL is always kept, plus at most `max_paths_per_host` other paths in discovery order (files
first, so the curated lists win); further variants are skipped and counted in `relays_capped`.
Relays are never removed while the process runs.

### Relay connections

Every relay is one fiber; relays are spread over `num_domains` OCaml domains by URL hash. Each
fiber loops:

1. Connect (WebSocket, TLS for `wss`) within `timeout_s`, through the SOCKS5 `proxy` unless the
   URL is in `no_proxy_relays`. The proxy resolves host names (`socks5h` behaviour). Relays that
   have never delivered a message first take one of `connect_concurrency` connection slots per
   domain, so reconnecting live relays never queue behind dead ones.
2. Send two REQs: `{"since": S}` and `{"since": S, "authors": ["00", ..., "ff"]}`. When `req_kinds`
   is set and the relay's host is not in `req_kinds_exempt_hosts`, both carry
   `"kinds": req_kinds`.
3. Read until the connection closes, fails, or is silent for `timeout_s`.
4. Sleep, then reconnect. The delay starts at `base_delay_s`, doubles after every connection that
   produced no message, and is reset to `base_delay_s` after one that did. It is capped at
   `max_delay_s`, or at `dead_relay_max_delay_s` for relays that have never delivered a message.

A `CLOSED` answer to a kinds-filtered REQ is answered by re-sending that REQ without the filter,
once. When it is the plain REQ that was refused, the relay stays unfiltered for its later
connections too (counted in `kinds_fallbacks`). Every `CLOSED` counts in `closed_msgs`.

`S` (the relay's `since`) starts from the relay's resume file, else `fetcher_since`, else the
current time. Every event moves it to `min(now, max(S, created_at - 1))`.

### Processing

With `firehose_forward_raw` false (the normal setting), a relay fiber first looks for the event id
and `created_at` in the raw message text; an id already in the dedup set is counted as `seenearly`
and dropped without parsing. Everything else goes, as an envelope line (below), to one processor
fiber on its own domain (queue of 100,000 lines; overflow is counted in `processor_queue_full`).
For each `EVENT` the processor:

1. skips ids already in the dedup set (`seenearly`);
2. parses the event (`parseerr` on failure) and drops it silently when `created_at` is 300 s or
   more in the future;
3. checks id and signature (`verifyerr`);
4. counts it (`any`), appends the line to the archive, records the id in the dedup set, credits
   the relay with a "first" when no other relay delivered it before (and its kind is in
   `req_kinds`, when that is set), and broadcasts the line on the firehose.

With `firehose_forward_raw` true, every line a relay fiber produces (connection events, `EOSE`,
duplicates) is also broadcast, and new events go out twice.

The dedup set is in memory: ids seen within the last `dedup_keep_s` seconds, pruned at most once a
minute. An event delivered again after that window is processed again (archived and sent a second
time; the importer ignores events it already has).

### Envelope lines

Firehose and archive lines are JSON arrays `[ts, meta, m]`:

- `ts`: the time the line was produced, a float in shortest round-trip form with an exponent
  (`1.791140507318978e9`);
- `meta`: `func` (`"nostr_fetch_events"`), `runid` (a UUID per relay fiber), `relay_url`, `timeout`,
  `proxy` (the proxy URL or `null`), `event`, plus per-event fields;
- `m`: the payload.

| `event` | `m` | extra `meta` fields |
|---|---|---|
| `started` | `null` | |
| `connected` | `{"since": S}` | |
| `request` | `{"query": <the REQ>}` | |
| `event` | the relay message, parsed (`["EVENT", subid, {...}]`, `["EOSE", ...]`, ...) | |
| `kinds_fallback` | the `CLOSED` message | |
| `exception` | the error text | `subfunc` (`websocket`, `parsing`, `downstream`), `printout` |
| `sleep` | `null` | `delay`, `msg_cnt` |

With `firehose_forward_raw` false only `event` lines carrying a new verified `EVENT` reach the
firehose and the archive. The importer and any archive reader depend on this format.

### The firehose

TCP server on `firehose_host:firehose_port`. A client that sends the line `STREAM-NEW-EVENTS`
receives every broadcast line, newline-terminated, written in batches of up to 512 lines. Each
subscriber has a queue of `firehose_queue` lines; when it is full, lines for that subscriber are
dropped and counted in `firehose_dropped`. Other input lines are logged and ignored; an empty line
or EOF ends the session. At stop every client gets `bye` and is disconnected.

### The archive

With `archive_enabled`, each new event's envelope line is appended to
`<archive_dir>/messages/YYYY/MM/DD.log`, by the UTC day of the event's `created_at`. Files are opened
in append mode, written line by line, and closed after 2 minutes without writes. Archive write
errors are logged and counted (`archive_errors`); they do not stop the firehose. With `req_kinds`
set, the archive holds only what the filtered REQs return.

### Resume files

`<state_dir>/<url>/latest_timestamp` holds a relay's `since` as decimal text. The directory name is
the URL with every character outside `[A-Za-z0-9]` replaced by `_`
(`wss://relay.damus.io` -> `wss___relay_damus_io`). A file is written (temp file + rename) at most
every 5 s per relay while events arrive, when the relay's fiber ends, and for every changed relay at
stop.

### Counters and `stats.json`

`<archive_dir>/stats.json` is rewritten every `metrics_period_s` and at stop, whether or not the
archive is enabled. Its counters `seen`, `seenearly`, `parseerr`, `verifyerr` and `any` are
cumulative across restarts: the values found at start are the baseline and this run's counts are
added. Other keys in the file are kept as they are.

## Configuration

`primal_fetcherd <config.json>` reads one JSON object. **Every key is required**; where `null` is
listed, it is allowed; unknown keys are ignored. `primal_fetcherd --check-config <config.json>` parses the config, prints
`config ok` and exits 0; a config error exits 2 with the message.

| Key | Type | Meaning | Usual value |
|---|---|---|---|
| `node_idx` | int | Instance number, shown in the log and `/status` | |
| `admin_host`, `admin_port` | string, int | Admin HTTP listener | `127.0.0.1` |
| `firehose_host`, `firehose_port` | string, int | Firehose listener | `127.0.0.1` |
| `state_dir` | string | Directory of the per-relay resume files | |
| `archive_dir` | string | Archive root; also holds `stats.json` | |
| `archive_enabled` | bool | Write the message archive | |
| `relays_dir` | string | Directory of the `relays-*.txt` files | this directory's `relays/` |
| `relays_file` | string or null | A single relay list used instead of `relays_dir`, verbatim | `null` |
| `extra_relays` | string list | Relay URLs added to the file set (e.g. an internal relay) | |
| `no_proxy_relays` | string list | URLs connected directly even when `proxy` is set | |
| `proxy` | string or null | SOCKS5 proxy for relay connections, `socks5h://host:port` or `socks5://host:port` (port defaults to 1080) | |
| `fetcher_since` | int or null | `since` for relays without a resume file; `null` = now | `null` |
| `timeout_s` | number | Connect timeout and read-silence timeout | 30 |
| `base_delay_s` | number | First reconnect delay | 1 |
| `max_delay_s` | number | Reconnect delay cap for relays that have delivered | 300 |
| `dead_relay_max_delay_s` | number | Reconnect delay cap for relays that never delivered a message | 3600 |
| `connect_concurrency` | int | Simultaneous connection attempts per domain, for relays that never delivered | 256 |
| `cache_db` | object or null | `{host, port, user, database}` of the cache DB for `fetcher_relays` polling; `null` disables polling | |
| `relays_db_poll_s` | number | `fetcher_relays` poll period | 1 |
| `pushgateway` | object or null | `{host, port, job}` of a Prometheus Pushgateway; `null` disables pushing | |
| `metrics_period_s` | number | Pushgateway push, `stats.json` write and dedup pruning period | 15 |
| `num_domains` | int | Domains the relay connections are spread over | 8 |
| `dedup_keep_s` | int | Dedup window | 21600 |
| `firehose_forward_raw` | bool | Also broadcast every raw relay line (see Processing) | `false` |
| `firehose_queue` | int | Per-subscriber queue length, in lines | 20000 |
| `max_paths_per_host` | int | Non-root URL variants kept per host; -1 = unlimited | 2 |
| `req_kinds` | int list or null | `kinds` filter for the REQs; `null` = unfiltered | |
| `req_kinds_exempt_hosts` | string list | Hosts (`host[:port]`) whose REQs stay unfiltered, so kinds outside `req_kinds` still arrive through them | |

`req_kinds` has to be a positive list because a Nostr filter cannot express kind ranges. Exempting a
few large relays keeps rare and new kinds arriving.

## Operation

### Running

- Run one fetcher per `state_dir`/`archive_dir`, and restart it stop-then-start: two processes on
  the same directories would overwrite each other's resume files and archive events twice.
- Every relay is a socket: raise the open-file limit (production uses 262144).
- Set `MALLOC_ARENA_MAX=2`. With the glibc default the many domains fragment the malloc arenas and
  RSS roughly doubles at tens of thousands of connections. WebSocket read buffers shrink back after
  a frame over 64 KB.
- Logs go to stdout, one line per message with a timestamp and a component tag (`[primal-fetcher]`,
  `[relays]`, `[processor]`, `[firehose]`, `[lifecycle]`). Every 10 s a summary line:
  `relays P/C/T (providing|connected|total) connecting N waiting N | msgs N/s new N/s | seenearly N
  parseerr N verifyerr N | fh subs N dropped N | qlen N dedup N | rss X | wsbuf X/N`.

### Stopping

SIGTERM, SIGINT, SIGUSR1 or `POST /stop` start the stop: `/readyz` turns 503, the relay fibers end
their loops and firehose clients get `bye`. After 3 s the changed resume files and `stats.json` are
written, the archive files closed, and the process exits 0.

### Admin HTTP (`admin_host:admin_port`)

| Endpoint | Answer |
|---|---|
| `GET /healthz` | `ok` |
| `GET /readyz` | 200 `ready` while serving, else 503 with the state |
| `GET /status` | JSON: pid, state, uptime, relays (`total`, `connected`, `waiting`, `providing`), rates since the previous `/status` call, all counters, `dedup_size`, `firehose_subscribers`, `rss_bytes`, `heap_bytes`, `ws_clients`, `ws_read_buffers_bytes` |
| `GET /relays` | JSON array, one object per relay, sorted by messages: `url`, `host`, `firsts`, `filtered`, `connected`, `waiting`, `delay`, `messages`, `exceptions`, `since`, `last_exception` |
| `GET /tasks` | Per-domain phase report (what each domain is doing) |
| `POST /gc` | Runs `Gc.compact`; answers the heap size before and after, and RSS |
| `POST /stop` | Starts the stop |

`firsts` on `/relays` is the number of events a relay delivered before any other relay: the measure
for deciding which relays and URL variants are worth keeping.

### Metrics

With `pushgateway` set, every `metrics_period_s` the process pushes (one POST to
`/metrics/job/<job>`):

| Metric | Type, meaning |
|---|---|
| `fetcher_message_count` | counter: messages received from relays |
| `fetcher_exception_count` | counter: connection and parse errors |
| `fetcher_chars_received`, `fetcher_chars_sent` | counter: message bytes received, REQ bytes sent |
| `fetcher_relays_total`, `fetcher_relays_connected` | gauge |
| `fetcher_new_events` | counter: new verified events (`any`) |
| `fetcher_firehose_dropped` | counter |
| `fetcher_rss_bytes` | gauge |

### Watchdog (`watchdog.sh`)

An external liveness check, run every 2 minutes by a systemd user timer. It reads `admin_port` from
the config, fetches `/status` (15 s timeout) and compares `counters.message_count` with the previous
run's. After two consecutive failures (no answer, or the count has not moved) it runs
`systemctl --user restart primal-ocaml-fetcher.service`. It is external because a stalled process
can stop answering on its admin port as well.

| Variable | Meaning |
|---|---|
| `PRIMAL_FETCHER_CONFIG` | the fetcher's config (default `primal-fetcher-config.json` in `$PRIMAL_CONFIG_DIR`) |
| `PRIMAL_FETCHER_ADMIN` | the `/status` URL, overriding the one built from `admin_port` |
| `PRIMAL_VAR_DIR` | where `fetcher-watchdog.state` and `fetcher-watchdog.log` are written |

It needs `bash`, `curl` and `python3` on `PATH`; a systemd timer unit has to set `PATH` explicitly.

### Tools

- `firehose_tap HOST PORT SECONDS [IDS_FILE]`: subscribes to a firehose for the given time and
  prints lines/s, EVENTs/s, distinct event ids, contributing relays, the top kinds and the counts of
  other line types; with `IDS_FILE`, writes the distinct ids. Run it against two firehoses at once to
  compare them.
- `relays_dump CONFIG`: prints the relay set the config loads from files (before the per-host cap
  and the DB poll), one URL per line.

## Relay lists (`relays/`)

| File | Treatment |
|---|---|
| `relays-active.txt` | verbatim, loaded first |
| `relays.txt` | sanitised |
| `relays-paid.txt` | sanitised |
| `relays-mined-from-events.txt` | sanitised |
| `relays-mined-from-contact-lists.txt` | sanitised |

Order matters for the per-host cap: earlier files claim a host's path slots first. A URL listed in
several files is loaded once.

## Layout

```
bin/primal_fetcherd.ml   the daemon: domains, processor, firehose, poller, metrics, stop
bin/firehose_tap.ml      firehose client that counts what arrives
bin/relays_dump.ml       prints the relay set loaded from files
lib/config.ml            the JSON config
lib/relay_url.ml         URL parsing, sanitising, host keys
lib/relay_set.ml         relay files, per-host cap, fetcher_relays poller, dispatch to domains
lib/relay_conn.ml        the per-relay loop, REQs, kinds fallback, envelope lines
lib/processor.ml         dedup, verify, archive, firsts, firehose broadcast
lib/dedup.ml             time-bounded event-id set
lib/archive.ml           messages/YYYY/MM/DD.log writer
lib/firehose.ml          the STREAM-NEW-EVENTS server
lib/resume.ml            latest_timestamp files
lib/stats.ml             counters, stats.json
lib/julia_json.ml        float formatting of the envelope timestamp
lib/admin.ml             admin HTTP
relays/                  relay lists
test/test_fetcher.ml     unit tests
watchdog.sh              external liveness check
```

Shared code (WebSocket client, SOCKS5, Postgres, Nostr verification, HTTP server, lifecycle, the
Pushgateway client) is in `../common` (library `primal_common`).

## Build and test

From anywhere in the repo, with the shared dev shell:

    nix develop "path:$(git rev-parse --show-toplevel)/common" -c dune build @all
    nix develop "path:$(git rev-parse --show-toplevel)/common" -c dune test fetcher

`_build/` is at the repository root; the binaries are
`_build/default/fetcher/bin/{primal_fetcherd,firehose_tap,relays_dump}.exe`.

The fetcher has no `[%pgsql]` statements, but `dune build @all` builds the whole workspace, whose
other projects do: point `PGHOST`/`PGPORT` at a database created from `schema/`
(see `schema/README.md`).

The tests cover URL sanitising, private-host detection, the envelope timestamp format, resume
directory names and the fast id/`created_at` extraction.
