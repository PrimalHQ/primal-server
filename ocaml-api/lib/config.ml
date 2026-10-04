(* primal-api runtime configuration: one JSON file, every key required (ocaml-plan.md §5.7).
   Phase 2 carries only what the proxying skeleton needs; later phases add the DB pools, node
   indices, media and content-moderation sections. *)

exception Config_error of string

module U = Yojson.Safe.Util

type t = {
  servername : string; (* ws-connector --servername; answered by server_name *)
  public_ws_host : string;
  public_ws_port : int; (* 9001 in production; a side port while shadowing *)
  admin_host : string; (* 127.0.0.1 *)
  admin_port : int;
  num_domains : int; (* worker domains, each with its own accept loop *)
  upstream_julia_ws : string; (* ws://127.0.0.1:8817 — the fallback proxy target *)
  upstream_connect_timeout_s : float;
  idle_connection_timeout_s : float; (* ws-connector idle_connection_timeout (jittered 0.95–1.0) *)
  ws_max_message_bytes : int;
  ws_outbound_queue : int;
  ws_send_stall_s : float;
  drain_grace_s : float; (* after the stop signal: time for in-flight requests before WS close *)
  drain_ws_max_s : float; (* hard deadline for all connections *)
  status_interval_s : float; (* status line period (0 = off) *)
  log_handled : bool;
  log_not_handled : bool;
  (* Phase 3: native funcalls *)
  cache_db : Postgres.conninfo; (* 127.0.0.1:54017/primal1 *)
  membership_db : Postgres.conninfo; (* <membership-db-host>:5432/primal *)
  cache_pool_size : int; (* per domain; ws-handlers used 16 process-wide *)
  membership_pool_size : int;
  content_moderation_root : string; (* default-settings.json, app-releases.json, ... *)
  primal_pubkey : string; (* raw 32 bytes; the default user_pubkey (ws-connector constant) *)
  request_log : string option; (* ws-connector --log-request JSONL path *)
  live_events_enabled : bool; (* poll + LISTEN primal_events distribution *)
  wsconnvars_poll_s : float;
  (* Phase 4a: push subscriptions *)
  network_stats_url : string option; (* App.NETWORK_STATS_URL: the importer's HTTP /api answering network_stats *)
  netstats_period_s : float; (* 1 / CacheServerHandlers.NETSTATS_RATE *)
  trending_blocked_domains : string list; (* App.TRENDING_BLOCKED_DOMAINS: nip05 domains hidden from trending *)
  (* Phase 4e *)
  search_api_url : string option; (* App.search forwards to another node's HTTP /api *)
  primal_dvm_pubkeys : string list; (* hex; DVMServiceProvider.keypairs pubkeys (is_primal in DVM feed metadata) *)
  (* Phase 4f *)
  import_events_line_server : (string * int) option; (* App.IMPORT_EVENTS_LINE_SERVER: the importer's import listener *)
  algos_user_pubkey : string option; (* raw; App.ALGOS_USER.pk, whose mute list is the primal_nsfw group *)
  monitoring_db : Postgres.conninfo option; (* events_nip46: the monitoring host's monitoring_events table *)
}

let field j key =
  match j with
  | `Assoc fields -> (
      match List.assoc_opt key fields with
      | Some v -> v
      | None -> raise (Config_error (Printf.sprintf "missing required key %S" key)))
  | _ -> raise (Config_error "config must be a JSON object")

let rstr j key = U.to_string (field j key)
let rint j key = U.to_int (field j key)
let rbool j key = U.to_bool (field j key)
let rfloat j key = U.to_number (field j key)
let rstr_opt j key = match field j key with `Null -> None | v -> Some (U.to_string v)

let conninfo_of_json (j : Yojson.Safe.t) : Postgres.conninfo =
  { Postgres.host = rstr j "host"; port = rint j "port"; user = rstr j "user"; database = rstr j "database" }

let of_json (j : Yojson.Safe.t) : t =
  {
    servername = rstr j "servername";
    public_ws_host = rstr j "public_ws_host";
    public_ws_port = rint j "public_ws_port";
    admin_host = rstr j "admin_host";
    admin_port = rint j "admin_port";
    num_domains = rint j "num_domains";
    upstream_julia_ws = rstr j "upstream_julia_ws";
    upstream_connect_timeout_s = rfloat j "upstream_connect_timeout_s";
    idle_connection_timeout_s = rfloat j "idle_connection_timeout_s";
    ws_max_message_bytes = rint j "ws_max_message_bytes";
    ws_outbound_queue = rint j "ws_outbound_queue";
    ws_send_stall_s = rfloat j "ws_send_stall_s";
    drain_grace_s = rfloat j "drain_grace_s";
    drain_ws_max_s = rfloat j "drain_ws_max_s";
    status_interval_s = rfloat j "status_interval_s";
    log_handled = rbool j "log_handled";
    log_not_handled = rbool j "log_not_handled";
    cache_db = conninfo_of_json (field j "cache_db");
    membership_db = conninfo_of_json (field j "membership_db");
    cache_pool_size = rint j "cache_pool_size";
    membership_pool_size = rint j "membership_pool_size";
    content_moderation_root = rstr j "content_moderation_root";
    primal_pubkey =
      (let h = rstr j "primal_pubkey" in
       match Hex_util.decode_opt h with
       | Some b when String.length b = 32 -> b
       | _ -> raise (Config_error "primal_pubkey: expected 64 hex characters"));
    request_log = rstr_opt j "request_log";
    live_events_enabled = rbool j "live_events_enabled";
    wsconnvars_poll_s = rfloat j "wsconnvars_poll_s";
    network_stats_url = rstr_opt j "network_stats_url";
    netstats_period_s = rfloat j "netstats_period_s";
    trending_blocked_domains = (match field j "trending_blocked_domains" with `List l -> List.map U.to_string l | _ -> raise (Config_error "trending_blocked_domains: expected a list"));
    search_api_url = rstr_opt j "search_api_url";
    primal_dvm_pubkeys =
      (match field j "primal_dvm_pubkeys" with
      | `List l -> List.map (fun v -> String.lowercase_ascii (U.to_string v)) l
      | _ -> raise (Config_error "primal_dvm_pubkeys: expected a list"));
    import_events_line_server =
      (match field j "import_events_line_server" with
      | `Null -> None
      | `Assoc _ as o -> Some (U.to_string (field o "host"), U.to_int (field o "port"))
      | _ -> raise (Config_error "import_events_line_server: expected {host, port} or null"));
    algos_user_pubkey =
      (match rstr_opt j "algos_user_pubkey" with
      | None -> None
      | Some h -> (
          match Hex_util.decode_opt h with
          | Some b when String.length b = 32 -> Some b
          | _ -> raise (Config_error "algos_user_pubkey: expected 64 hex characters")));
    monitoring_db = (match field j "monitoring_db" with `Null -> None | o -> Some (conninfo_of_json o));
  }

let of_json_file (path : string) : t =
  let j =
    try Yojson.Safe.from_file path
    with Yojson.Json_error msg -> raise (Config_error (Printf.sprintf "%s: invalid JSON: %s" path msg))
  in
  try of_json j with U.Type_error (msg, _) -> raise (Config_error (Printf.sprintf "%s: %s" path msg))

(* ws[s]://host[:port][/path] of the upstream, parsed once. *)
let upstream (t : t) : bool * string * int * string =
  match Relay_broadcast.parse_relay_url t.upstream_julia_ws with
  | Some u -> u
  | None -> raise (Config_error ("upstream_julia_ws: not a ws:// url: " ^ t.upstream_julia_ws))
