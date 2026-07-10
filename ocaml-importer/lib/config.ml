(* Runtime configuration from the environment, mirroring the globals set in
   start_media_importer.jl (FirehoseClient.PORT = 9000+NODEIDX, VERIFY_ZAPPERS, Main.PROXY). *)

type t = {
  firehose_host : string;
  firehose_port : int;
  num_workers : int;
  queue_capacity : int;
  proxy : string option; (* SOCKS5 "host:port" (or "socks5h://host:port") for LNURL *)
  event_sync_enabled : bool; (* pull recent events from peer nodes (Event_syncer) *)
  event_sync_remotes : string list; (* peer Postgres hosts (same port/credentials as local) *)
  event_sync_interval : float; (* seconds between sync cycles *)
  event_sync_overlap : int; (* seconds of lookback behind local max created_at *)
  pushgateway_enabled : bool; (* publish the imported count to a Prometheus pushgateway *)
  pushgateway_host : string;
  pushgateway_port : int;
  pushgateway_job : string; (* job label, Julia "primalnode<idx>" (the reporting node, see below) *)
  pushgateway_stats_file : string; (* Julia stats.json: persists the always-increasing "any" total *)
  pushgateway_interval : float; (* seconds between pushes *)
  cs : Cache_storage.config;
  cache_db : Postgres.conninfo; (* the importer's :p0 (cache) DB — was PG* *)
  membership_db : Postgres.conninfo; (* the importer's :membership DB — was PGMEMBERSHIP* *)
  humaness_threshold : float option; (* None = compute from pubkey_trustrank at startup *)
}

let getenv = Sys.getenv_opt
let int_env name default = match getenv name with Some v -> int_of_string v | None -> default
let float_env name default = match getenv name with Some v -> float_of_string v | None -> default

let bool_env name default =
  match getenv name with
  | Some ("1" | "true" | "yes" | "on") -> true
  | Some ("0" | "false" | "no" | "off") -> false
  | _ -> default

(* Comma-separated hex pubkeys -> raw 32-byte strings. *)
let pubkey_list_env name =
  match getenv name with
  | None | Some "" -> []
  | Some s ->
      String.split_on_char ',' s
      |> List.filter_map (fun h ->
             let h = String.trim h in
             if String.length h = 64 then Hex_util.decode_opt h else None)

(* Strip a leading socks5h:// or socks5:// scheme; keep host:port. *)
let normalize_proxy s =
  let strip_prefix p s =
    let lp = String.length p in
    if String.length s >= lp && String.sub s 0 lp = p then String.sub s lp (String.length s - lp)
    else s
  in
  let s = String.trim s in
  if s = "" then None else Some (s |> strip_prefix "socks5h://" |> strip_prefix "socks5://")

(* Split the proxy "host:port" into (host, port) for Socks5/Http. *)
let proxy_endpoint (t : t) : (string * int) option =
  Option.bind t.proxy (fun s ->
      match String.rindex_opt s ':' with
      | Some i -> (
          try Some (String.sub s 0 i, int_of_string (String.sub s (i + 1) (String.length s - i - 1)))
          with _ -> None)
      | None -> None)

let from_env () : t =
  let node_idx = int_env "NODE_IDX" (int_env "PRIMALSERVER_NODE_IDX" 17) in
  (* Reporting node identity for pushgateway/stats, distinct from the firehose node (node_idx).
     On this box only the node-17 firehose (port 9017) exists, but the importer replaces the
     production node-18 Julia importer, so its metrics/stats are published as node 18 (the Grafana
     panel queries cache_any{exported_job="primalnode18"}). Override with PRIMALSERVER_REPORT_NODE_IDX. *)
  let report_node = int_env "PRIMALSERVER_REPORT_NODE_IDX" 18 in
  let storage_path =
    Option.value (getenv "PRIMALSERVER_STORAGE_PATH") ~default:"/home/pr/var/primalserver"
  in
  {
    firehose_host = Option.value (getenv "PRIMALSERVER_FIREHOSE_HOST") ~default:"127.0.0.1";
    firehose_port = int_env "PRIMALSERVER_FIREHOSE_PORT" (9000 + node_idx);
    num_workers = int_env "IMPORTER_WORKERS" 4;
    queue_capacity = int_env "IMPORTER_QUEUE_CAPACITY" 10_000;
    proxy = Option.bind (getenv "PRIMALSERVER_PROXY") normalize_proxy;
    event_sync_enabled = bool_env "IMPORTER_EVENT_SYNC" true;
    event_sync_remotes =
      (match getenv "IMPORTER_EVENT_SYNC_REMOTES" with
      | Some s when String.trim s <> "" ->
          String.split_on_char ',' s |> List.map String.trim |> List.filter (fun h -> h <> "")
      | _ -> [ "192.168.40.7"; "192.168.42.7"; "192.168.43.7"; "192.168.44.7" ]);
    event_sync_interval = float_env "IMPORTER_EVENT_SYNC_INTERVAL" 60.0;
    event_sync_overlap = int_env "IMPORTER_EVENT_SYNC_OVERLAP" 600;
    pushgateway_enabled = bool_env "IMPORTER_PUSHGATEWAY" true;
    pushgateway_host = Option.value (getenv "IMPORTER_PUSHGATEWAY_HOST") ~default:"127.0.0.1";
    pushgateway_port = int_env "IMPORTER_PUSHGATEWAY_PORT" 9091;
    pushgateway_job =
      Option.value (getenv "IMPORTER_PUSHGATEWAY_JOB")
        ~default:(Printf.sprintf "primalnode%d" report_node);
    pushgateway_stats_file =
      Option.value (getenv "IMPORTER_STATS_FILE")
        ~default:(Printf.sprintf "%s/primalnode%d/cache/db/stats.json" storage_path report_node);
    pushgateway_interval = float_env "IMPORTER_PUSHGATEWAY_INTERVAL" 15.0;
    cs =
      {
        Cache_storage.verification_enabled = bool_env "IMPORTER_VERIFY" true;
        verify_zappers = bool_env "VERIFY_ZAPPERS" true;
        trusted_zappers = [];
        disable_trustrank = bool_env "IMPORTER_DISABLE_TRUSTRANK" false;
        import_reporting = bool_env "IMPORTER_IMPORT_REPORTING" false;
        reporting_whitelist = pubkey_list_env "IMPORTER_REPORTING_WHITELIST";
      };
    cache_db = Postgres.cache_conninfo ();
    membership_db = Postgres.membership_conninfo ();
    (* Explicit override for ext_is_human; None => computed at startup from pubkey_trustrank
       (mirrors Julia TrustRank.load; see cache_storage_ext.load_humaness_threshold). *)
    humaness_threshold =
      (match getenv "IMPORTER_HUMANESS_THRESHOLD" with
      | Some v -> ( try Some (float_of_string v) with _ -> None)
      | None -> None);
  }

(* {1 JSON configuration file} — the runtime config source. (The environment is only read by
   [from_env], which the dev tools use and which documents the defaults.) All settings live in one
   flat object; see README. *)

module U = Yojson.Safe.Util

(* The config file is authoritative: every key must be present. Defaults live ONLY in [from_env],
   so there is no second copy to drift. A missing key is an error rather than a silent fallback, so
   the file can never half-specify the importer. *)
exception Config_error of string

(* Look a key up in the top-level object; absent => error (present-but-null is a value, kept). *)
let field j key =
  match j with
  | `Assoc l -> (
      match List.assoc_opt key l with
      | Some v -> v
      | None -> raise (Config_error (Printf.sprintf "missing required key %S" key)))
  | _ -> raise (Config_error "config must be a JSON object")

(* Required-key getters. to_number accepts both JSON ints and floats. The nullable keys (proxy,
   humaness_threshold) must still be present, but their value may be null. *)
let rstr j key = U.to_string (field j key)
let rint j key = U.to_int (field j key)
let rbool j key = U.to_bool (field j key)
let rfloat j key = U.to_number (field j key)
let rstr_opt j key = match field j key with `Null -> None | v -> Some (U.to_string v)
let rfloat_opt j key = match field j key with `Null -> None | v -> Some (U.to_number v)
let rstrlist j key = List.map U.to_string (U.to_list (field j key))

(* JSON array of lowercase-hex pubkeys -> raw 32-byte strings (invalid entries dropped, like
   pubkey_list_env). *)
let rpubkeys j key =
  List.filter_map (fun h -> Hex_util.decode_opt (U.to_string h)) (U.to_list (field j key))

let conninfo_of_json (j : Yojson.Safe.t) : Postgres.conninfo =
  {
    Postgres.host = rstr j "host";
    port = rint j "port";
    user = rstr j "user";
    database = rstr j "database";
  }

let of_json (j : Yojson.Safe.t) : t =
  {
    firehose_host = rstr j "firehose_host";
    firehose_port = rint j "firehose_port";
    num_workers = rint j "num_workers";
    queue_capacity = rint j "queue_capacity";
    proxy = (match rstr_opt j "proxy" with Some s -> normalize_proxy s | None -> None);
    event_sync_enabled = rbool j "event_sync_enabled";
    event_sync_remotes = rstrlist j "event_sync_remotes";
    event_sync_interval = rfloat j "event_sync_interval";
    event_sync_overlap = rint j "event_sync_overlap";
    pushgateway_enabled = rbool j "pushgateway_enabled";
    pushgateway_host = rstr j "pushgateway_host";
    pushgateway_port = rint j "pushgateway_port";
    pushgateway_job = rstr j "pushgateway_job";
    pushgateway_stats_file = rstr j "pushgateway_stats_file";
    pushgateway_interval = rfloat j "pushgateway_interval";
    cs =
      {
        Cache_storage.verification_enabled = rbool j "verification_enabled";
        verify_zappers = rbool j "verify_zappers";
        trusted_zappers = rpubkeys j "trusted_zappers";
        disable_trustrank = rbool j "disable_trustrank";
        import_reporting = rbool j "import_reporting";
        reporting_whitelist = rpubkeys j "reporting_whitelist";
      };
    cache_db = conninfo_of_json (field j "cache_db");
    membership_db = conninfo_of_json (field j "membership_db");
    humaness_threshold = rfloat_opt j "humaness_threshold";
  }

(* Wrap Yojson/Util exceptions in Config_error so callers get one file-scoped error type. *)
let of_json_file (path : string) : t =
  let j =
    try Yojson.Safe.from_file path
    with Yojson.Json_error msg -> raise (Config_error (Printf.sprintf "%s: invalid JSON: %s" path msg))
  in
  try of_json j
  with U.Type_error (msg, _) -> raise (Config_error (Printf.sprintf "%s: %s" path msg))
