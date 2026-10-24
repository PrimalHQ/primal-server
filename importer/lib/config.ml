(* The importer's configuration: the JSON config file the daemon reads ([of_json_file]), and
   [from_env], the environment variant the dev tools in bin/ use. *)

(* Event_syncer.backfill: pull [remote]'s events with imported_at in [from_ts, to_ts) in keyset
   batches of [batch] rows and submit them to the import queue (the normal import path, no relay
   broadcast); progress is kept in [state_file] so a restart resumes. null = no backfill. *)
type backfill = { remote : string; from_ts : int; to_ts : int; batch : int; state_file : string }

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
  event_sync_backfill : backfill option;
      (* one-off: replay a peer's event table over a past imported_at range into the import queue (gap repair) *)
  pushgateway_enabled : bool; (* publish the imported count to a Prometheus pushgateway *)
  pushgateway_host : string;
  pushgateway_port : int;
  pushgateway_job : string; (* job label (exported_job in Prometheus) *)
  pushgateway_stats_file : string; (* stats.json (Julia's format): persists the always-increasing "any" total *)
  pushgateway_interval : float; (* seconds between pushes *)
  push_notifications_enabled : bool; (* device push delivery (Julia PUSH_NOTIFICATIONS_ENABLED) *)
  push_notification_sender_bin : string; (* the push-notification-sender subprocess binary *)
  push_notifications_period : float; (* seconds between transmission batches (Julia PERIOD) *)
  push_notifications_log : bool; (* dump sender request/response JSON to stdout (Julia LOG) *)
  push_intake_host : string; (* Push_intake: the wallet server's notification line protocol (Julia PushNotifications.PORT) *)
  push_intake_ports : int list; (* [] = off *)
  cs : Cache_storage.config;
  cache_db : Postgres.conninfo; (* the cache DB (Julia's :p0) *)
  membership_db : Postgres.conninfo; (* the membership DB (Julia's :membership) *)
  humaness_threshold : float option; (* None = compute from pubkey_trustrank at startup *)
  import_listener_enabled : bool; (* Import_listener: synchronous imports for the API's import_events *)
  import_listener_host : string;
  import_listener_port : int;
  expire_scores_enabled : bool; (* Julia CacheStorage.periodic expire_scores; one importer per cache DB *)
  scheduled_hooks_enabled : bool; (* run_scheduled_hooks; one importer per cache DB (two runners = double decrements) *)
  content_moderation_rules_enabled : bool; (* cmr_* recompute on mute/allow list changes *)
  default_settings_file : string option; (* content-moderation default-settings.json (cmr defaults) *)
  relay_broadcast_timeout : float; (* seconds per relay for reply broadcasting *)
  poll_vote_import_enabled : bool; (* Julia DAG.POLL_VOTE_IMPORT_ENABLED for the instant indexers *)
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
  let storage_path =
    match getenv "PRIMALSERVER_STORAGE_PATH" with
    | Some p -> p
    | None -> Filename.concat (Option.value (getenv "HOME") ~default:".") "var/primalserver"
  in
  {
    firehose_host = Option.value (getenv "PRIMALSERVER_FIREHOSE_HOST") ~default:"127.0.0.1";
    firehose_port = int_env "PRIMALSERVER_FIREHOSE_PORT" 9017;
    num_workers = int_env "IMPORTER_WORKERS" 4;
    queue_capacity = int_env "IMPORTER_QUEUE_CAPACITY" 10_000;
    proxy = Option.bind (getenv "PRIMALSERVER_PROXY") normalize_proxy;
    event_sync_enabled = bool_env "IMPORTER_EVENT_SYNC" true;
    event_sync_remotes =
      (match getenv "IMPORTER_EVENT_SYNC_REMOTES" with
      | Some s when String.trim s <> "" ->
          String.split_on_char ',' s |> List.map String.trim |> List.filter (fun h -> h <> "")
      | _ -> [] (* the peers are deployment-specific: the JSON config names them *));
    event_sync_interval = float_env "IMPORTER_EVENT_SYNC_INTERVAL" 60.0;
    event_sync_overlap = int_env "IMPORTER_EVENT_SYNC_OVERLAP" 600;
    event_sync_backfill = None;
    pushgateway_enabled = bool_env "IMPORTER_PUSHGATEWAY" true;
    pushgateway_host = Option.value (getenv "IMPORTER_PUSHGATEWAY_HOST") ~default:"127.0.0.1";
    pushgateway_port = int_env "IMPORTER_PUSHGATEWAY_PORT" 9091;
    (* The job and stats-file names are the Julia node's whose metrics the importer took over;
       the dashboards query cache_any{exported_job="primalnode18"}. *)
    pushgateway_job = Option.value (getenv "IMPORTER_PUSHGATEWAY_JOB") ~default:"primalnode18";
    pushgateway_stats_file =
      Option.value (getenv "IMPORTER_STATS_FILE")
        ~default:(Filename.concat storage_path "primalnode18/cache/db/stats.json");
    pushgateway_interval = float_env "IMPORTER_PUSHGATEWAY_INTERVAL" 15.0;
    push_notifications_enabled = bool_env "IMPORTER_PUSH_NOTIFICATIONS" false;
    push_notification_sender_bin =
      Option.value (getenv "IMPORTER_PUSH_NOTIFICATION_SENDER_BIN")
        ~default:
          ((* the sender is a sibling project of this repo in the parent checkout:
              <repo>/_build/default/importer/bin/primal_importerd.exe -> <repo>/../push-notification-sender *)
           let rec up n d = if n = 0 then d else up (n - 1) (Filename.dirname d) in
           Filename.concat (up 5 Sys.executable_name) "push-notification-sender/target/release/push-notification-sender");
    push_notifications_period = float_env "IMPORTER_PUSH_NOTIFICATIONS_PERIOD" 5.0;
    push_notifications_log = bool_env "IMPORTER_PUSH_NOTIFICATIONS_LOG" false;
    push_intake_host = Option.value (getenv "IMPORTER_PUSH_INTAKE_HOST") ~default:"0.0.0.0";
    push_intake_ports =
      (match getenv "IMPORTER_PUSH_INTAKE_PORTS" with
      | None | Some "" -> []
      | Some s -> List.map (fun p -> int_of_string (String.trim p)) (String.split_on_char ',' s));
    cs =
      {
        Cache_storage.verification_enabled = bool_env "IMPORTER_VERIFY" true;
        verify_zappers = bool_env "VERIFY_ZAPPERS" true;
        trusted_zappers = [];
        disable_trustrank = bool_env "IMPORTER_DISABLE_TRUSTRANK" false;
        import_reporting = bool_env "IMPORTER_IMPORT_REPORTING" false;
        reporting_whitelist = pubkey_list_env "IMPORTER_REPORTING_WHITELIST";
        download_media = bool_env "IMPORTER_DOWNLOAD_MEDIA" false;
        download_previews = bool_env "IMPORTER_DOWNLOAD_PREVIEWS" false;
        lean = Lean.off;
      };
    cache_db = Postgres.cache_conninfo ();
    membership_db = Postgres.membership_conninfo ();
    (* Explicit override for ext_is_human; None => computed at startup from pubkey_trustrank
       (mirrors Julia TrustRank.load; see cache_storage_ext.load_humaness_threshold). *)
    humaness_threshold =
      (match getenv "IMPORTER_HUMANESS_THRESHOLD" with
      | Some v -> ( try Some (float_of_string v) with _ -> None)
      | None -> None);
    import_listener_enabled = bool_env "IMPORTER_IMPORT_LISTENER" false;
    import_listener_host = Option.value (getenv "IMPORTER_IMPORT_LISTENER_HOST") ~default:"0.0.0.0";
    import_listener_port = int_env "IMPORTER_IMPORT_LISTENER_PORT" 12018;
    expire_scores_enabled = bool_env "IMPORTER_EXPIRE_SCORES" false;
    scheduled_hooks_enabled = bool_env "IMPORTER_SCHEDULED_HOOKS" true;
    content_moderation_rules_enabled = bool_env "IMPORTER_CONTENT_MODERATION_RULES" true;
    default_settings_file = getenv "IMPORTER_DEFAULT_SETTINGS_FILE";
    relay_broadcast_timeout = float_env "IMPORTER_RELAY_BROADCAST_TIMEOUT" 15.0;
    poll_vote_import_enabled = bool_env "IMPORTER_POLL_VOTE_IMPORT" true;
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

(* The one optional key: "lean" (absent or null = the classic write path). Its own keys are all
   optional, but an unknown one is an error (see Lean.of_json). *)
let lean_of_json (j : Yojson.Safe.t) : Lean.t =
  match j with
  | `Assoc l -> (
      match List.assoc_opt "lean" l with
      | None -> Lean.off
      | Some v -> ( match Lean.of_json v with Ok x -> x | Error msg -> raise (Config_error msg)))
  | _ -> Lean.off

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
    event_sync_backfill =
      (match field j "event_sync_backfill" with
      | `Null -> None
      | b ->
          Some
            { remote = rstr b "remote"; from_ts = rint b "from_ts"; to_ts = rint b "to_ts"; batch = rint b "batch";
              state_file = rstr b "state_file" });
    pushgateway_enabled = rbool j "pushgateway_enabled";
    pushgateway_host = rstr j "pushgateway_host";
    pushgateway_port = rint j "pushgateway_port";
    pushgateway_job = rstr j "pushgateway_job";
    pushgateway_stats_file = rstr j "pushgateway_stats_file";
    pushgateway_interval = rfloat j "pushgateway_interval";
    push_notifications_enabled = rbool j "push_notifications_enabled";
    push_notification_sender_bin = rstr j "push_notification_sender_bin";
    push_notifications_period = rfloat j "push_notifications_period";
    push_notifications_log = rbool j "push_notifications_log";
    push_intake_host = rstr j "push_intake_host";
    push_intake_ports = List.map U.to_int (U.to_list (field j "push_intake_ports"));
    cs =
      {
        Cache_storage.verification_enabled = rbool j "verification_enabled";
        verify_zappers = rbool j "verify_zappers";
        trusted_zappers = rpubkeys j "trusted_zappers";
        disable_trustrank = rbool j "disable_trustrank";
        import_reporting = rbool j "import_reporting";
        reporting_whitelist = rpubkeys j "reporting_whitelist";
        download_media = rbool j "download_media";
        download_previews = rbool j "download_previews";
        lean = lean_of_json j;
      };
    cache_db = conninfo_of_json (field j "cache_db");
    membership_db = conninfo_of_json (field j "membership_db");
    humaness_threshold = rfloat_opt j "humaness_threshold";
    import_listener_enabled = rbool j "import_listener_enabled";
    import_listener_host = rstr j "import_listener_host";
    import_listener_port = rint j "import_listener_port";
    expire_scores_enabled = rbool j "expire_scores_enabled";
    scheduled_hooks_enabled = rbool j "scheduled_hooks_enabled";
    content_moderation_rules_enabled = rbool j "content_moderation_rules_enabled";
    default_settings_file = rstr_opt j "default_settings_file";
    relay_broadcast_timeout = rfloat j "relay_broadcast_timeout";
    poll_vote_import_enabled = rbool j "poll_vote_import_enabled";
  }

(* Wrap Yojson/Util exceptions in Config_error so callers get one file-scoped error type. *)
let of_json_file (path : string) : t =
  let j =
    try Yojson.Safe.from_file path
    with Yojson.Json_error msg -> raise (Config_error (Printf.sprintf "%s: invalid JSON: %s" path msg))
  in
  try of_json j
  with U.Type_error (msg, _) -> raise (Config_error (Printf.sprintf "%s: %s" path msg))
