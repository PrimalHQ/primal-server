(* primal-fetcher configuration: one JSON file, every key required (as the other daemons).
   The keys replace the PRIMALSERVER_* environment of m1_fetcher.sh / start_fetcher.jl. *)

exception Config_error of string

module U = Yojson.Safe.Util

type t = {
  node_idx : int; (* PRIMALSERVER_NODE_IDX; firehose port 9000+N, pushgateway job fetcher<N> *)
  admin_host : string;
  admin_port : int;
  firehose_host : string; (* FirehoseServer.HOST 127.0.0.1 *)
  firehose_port : int; (* FirehoseServer.PORT 9000+N *)
  state_dir : string; (* Fetching.EVENTS_DATA_DIR: $STORAGE/primalnode$N/fetcher — per-relay latest_timestamp *)
  archive_dir : string; (* DeduplicatedEventStorage rootdirectory: $STORAGE/primalnode$N/dedup — messages/YYYY/MM/DD.log, stats.json *)
  archive_enabled : bool;
  relays_dir : string; (* directory of relays-active.txt, relays.txt, relays-paid.txt, relays-mined-*.txt (Fetching.load_relays) *)
  relays_file : string option; (* PRIMALSERVER_RELAYS: use this list instead of relays_dir *)
  extra_relays : string list; (* start_fetcher.jl: the internal relay *)
  no_proxy_relays : string list; (* relays connected directly even when proxy is set *)
  proxy : (string * int) option; (* PRIMALSERVER_PROXY socks5h://host:port *)
  proxy_url : string option; (* the same, verbatim, for the message envelope *)
  fetcher_since : int option; (* PRIMALSERVER_FETCHER_SINCE; null = now *)
  timeout_s : float; (* Fetching.TIMEOUT 30: connect and read timeout *)
  base_delay_s : float; (* BASE_DELAY 1 *)
  max_delay_s : float; (* MAX_DELAY 300 *)
  dead_relay_max_delay_s : float; (* backoff cap for relays that never delivered a message (Julia: 300 — but its HTTP.jl pool cap of 10000 parked most of them) *)
  connect_concurrency : int; (* simultaneous connection attempts per domain (Julia: implicit via the 10000-connection pool) *)
  cache_db : Postgres.conninfo option; (* fetcher_relays polling (start_relays_from_db); null disables *)
  relays_db_poll_s : float; (* 1 *)
  pushgateway : (string * int * string) option; (* host, port, job (fetcher<N>) *)
  metrics_period_s : float; (* 15 *)
  num_domains : int; (* relay connections are spread over this many domains by url hash *)
  dedup_keep_s : int; (* in-memory dedup window (replaces the SQLite deduped_events shards) *)
  firehose_forward_raw : bool; (* Fetching.message_processors[:firehose_server]: every relay message to the firehose *)
  max_paths_per_host : int; (* relay-set control: non-root url variants kept per host (-1 = unlimited; the root url always) *)
  req_kinds : int list option; (* relay-set control: "kinds" of the REQs sent to non-exempt relays; null = unfiltered *)
  req_kinds_exempt_hosts : string list; (* hosts (host[:port]) that always get the unfiltered REQs *)
  firehose_queue : int; (* per-subscriber bounded queue, drop when full (Julia: Channel(20_000)) *)
  log_connections : bool;
}

let field j key = match j with `Assoc f -> ( match List.assoc_opt key f with Some v -> v | None -> raise (Config_error ("missing key " ^ key))) | _ -> raise (Config_error "config must be an object")
let rstr j k = try U.to_string (field j k) with U.Type_error _ -> raise (Config_error (k ^ ": expected a string"))
let rstr_opt j k = match field j k with `Null -> None | v -> Some (U.to_string v)
let rint j k = try U.to_int (field j k) with U.Type_error _ -> raise (Config_error (k ^ ": expected an integer"))
let rint_opt j k = match field j k with `Null -> None | v -> Some (U.to_int v)
let rfloat j k = match field j k with `Int i -> float_of_int i | `Float f -> f | _ -> raise (Config_error (k ^ ": expected a number"))
let rbool j k = try U.to_bool (field j k) with U.Type_error _ -> raise (Config_error (k ^ ": expected a boolean"))
let rlist j k = match field j k with `List l -> List.map U.to_string l | _ -> raise (Config_error (k ^ ": expected a list"))

let conninfo_of_json (j : Yojson.Safe.t) : Postgres.conninfo =
  { Postgres.host = rstr j "host"; port = rint j "port"; user = rstr j "user"; database = rstr j "database" }

(* "socks5h://host:port" / "socks5://host:port" -> (host, port) *)
let parse_proxy (s : string) : string * int =
  let rest = match String.index_opt s ':' with Some i when String.length s > i + 2 && String.sub s (i + 1) 2 = "//" -> String.sub s (i + 3) (String.length s - i - 3) | _ -> s in
  let rest = match String.index_opt rest '/' with Some i -> String.sub rest 0 i | None -> rest in
  match String.rindex_opt rest ':' with
  | Some i -> (String.sub rest 0 i, int_of_string (String.sub rest (i + 1) (String.length rest - i - 1)))
  | None -> (rest, 1080)

let of_json (j : Yojson.Safe.t) : t =
  let proxy_url = rstr_opt j "proxy" in
  {
    node_idx = rint j "node_idx";
    admin_host = rstr j "admin_host";
    admin_port = rint j "admin_port";
    firehose_host = rstr j "firehose_host";
    firehose_port = rint j "firehose_port";
    state_dir = rstr j "state_dir";
    archive_dir = rstr j "archive_dir";
    archive_enabled = rbool j "archive_enabled";
    relays_dir = rstr j "relays_dir";
    relays_file = rstr_opt j "relays_file";
    extra_relays = rlist j "extra_relays";
    no_proxy_relays = rlist j "no_proxy_relays";
    proxy = Option.map parse_proxy proxy_url;
    proxy_url;
    fetcher_since = rint_opt j "fetcher_since";
    timeout_s = rfloat j "timeout_s";
    base_delay_s = rfloat j "base_delay_s";
    max_delay_s = rfloat j "max_delay_s";
    dead_relay_max_delay_s = rfloat j "dead_relay_max_delay_s";
    connect_concurrency = rint j "connect_concurrency";
    cache_db = (match field j "cache_db" with `Null -> None | o -> Some (conninfo_of_json o));
    relays_db_poll_s = rfloat j "relays_db_poll_s";
    pushgateway = (match field j "pushgateway" with `Null -> None | o -> Some (rstr o "host", rint o "port", rstr o "job"));
    metrics_period_s = rfloat j "metrics_period_s";
    num_domains = rint j "num_domains";
    dedup_keep_s = rint j "dedup_keep_s";
    firehose_forward_raw = rbool j "firehose_forward_raw";
    max_paths_per_host = rint j "max_paths_per_host";
    req_kinds = (match field j "req_kinds" with `Null -> None | `List l -> Some (List.map U.to_int l) | _ -> raise (Config_error "req_kinds: expected a list of integers or null"));
    req_kinds_exempt_hosts = rlist j "req_kinds_exempt_hosts";
    firehose_queue = rint j "firehose_queue";
    log_connections = rbool j "log_connections";
  }

let of_json_file (path : string) : t =
  let j = try Yojson.Safe.from_file path with Yojson.Json_error m -> raise (Config_error ("invalid JSON: " ^ m)) in
  of_json j
