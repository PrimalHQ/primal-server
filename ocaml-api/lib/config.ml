(* primal-api runtime configuration: one JSON file, every key required (ocaml-plan.md §5.7).
   Phase 2 carries only what the proxying skeleton needs; later phases add the DB pools, node
   indices, media and content-moderation sections. *)

exception Config_error of string

module U = Yojson.Safe.Util

(* Phase 5b: where media files live (Media.MEDIA_PATHS / MEDIA_PATHS_2 entries); [label] is the
   media_storage.storage_provider the entry stands for *)
type media_path = Local of { label : string; root : string } | S3_path of { label : string; provider : string }

let media_path_label = function Local { label; _ } -> label | S3_path { label; _ } -> label

type t = {
  ext : Yojson.Safe.t; (* the "ext" object for the private extensions (ocaml-plan.md §11.2); `Null when absent *)
  servername : string; (* ws-connector --servername; answered by server_name *)
  public_ws_host : string;
  public_ws_port : int; (* 9001 in production; a side port while shadowing *)
  cache_ws_port : int option; (* 8800+N: the Julia CacheServer port — the same WS service for health probes and cross-node calls; null while Julia holds it *)
  admin_host : string; (* 127.0.0.1 *)
  admin_port : int;
  num_domains : int; (* worker domains, each with its own accept loop *)
  upstream_julia_ws : string; (* ws://127.0.0.1:8817 — the fallback proxy target *)
  upstream_connect_timeout_s : float;
  idle_connection_timeout_s : float; (* ws-connector idle_connection_timeout (jittered 0.95–1.0) *)
  ws_max_message_bytes : int;
  ws_outbound_queue : int;
  ws_send_stall_s : float;
  anon_feed_cache_s : float; (* feed pages for the anonymous pubkey reused this long (0 = off), see Anon_cache *)
  request_concurrency : int; (* REQs of one connection handled at once (1 = in order, as ws-connector/Julia) *)
  drain_grace_s : float; (* after the stop signal: time for in-flight requests before WS close *)
  drain_ws_max_s : float; (* hard deadline for all connections *)
  status_interval_s : float; (* status line period (0 = off) *)
  log_handled : bool;
  log_not_handled : bool;
  (* Phase 3: native funcalls *)
  cache_db : Postgres.conninfo; (* 127.0.0.1:54017/primal1 *)
  membership_db : Postgres.conninfo; (* the membership Postgres (Julia :membership) *)
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
  (* Phase 4g *)
  relay_proxy : (string * int) option; (* SOCKS5 host, port for outbound relay connections (Main.PROXY) *)
  dvm_relays : string list; (* DVMFeedChecker.RELAYS: where DVM job requests are published *)
  dvm_requester_seckey : string option; (* raw 32 bytes; App.DVM_REQUESTER_KEYPAIR *)
  (* Phase 5: InternalServices *)
  internal_http_port : int; (* 14000+N: InternalServices router *)
  moderation_http_port : int; (* 24000+N: /purge-media, /pre-sign-urls *)
  upstream_julia_http : string option; (* Julia's /api, for funcalls still proxied *)
  index_dirs : (string * string) list; (* Host -> directory holding index.html (preview_handler) *)
  url_shortening_root_url : string; (* InternalServices.URL_SHORTENING_ROOT_URL *)
  download_proxies : string list; (* Media.DOWNLOAD_PROXIES ("null" = direct); empty = link previews disabled, as in Julia *)
  (* Phase 5b: media moderation *)
  s3_providers : S3.provider list; (* Main.S3_CONFIGS *)
  cloudflare : (string * string) option; (* zone id, API key: cache purge of the cloudflare providers' domains *)
  media_paths : media_path list; (* local roots and S3 providers a purge walks *)
  (* Phase 5c: Blossom *)
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
    ext = (match j with `Assoc f -> Option.value (List.assoc_opt "ext" f) ~default:`Null | _ -> `Null);
    servername = rstr j "servername";
    public_ws_host = rstr j "public_ws_host";
    public_ws_port = rint j "public_ws_port";
    cache_ws_port = (match field j "cache_ws_port" with `Null -> None | v -> Some (U.to_int v));
    admin_host = rstr j "admin_host";
    admin_port = rint j "admin_port";
    num_domains = rint j "num_domains";
    upstream_julia_ws = rstr j "upstream_julia_ws";
    upstream_connect_timeout_s = rfloat j "upstream_connect_timeout_s";
    idle_connection_timeout_s = rfloat j "idle_connection_timeout_s";
    ws_max_message_bytes = rint j "ws_max_message_bytes";
    ws_outbound_queue = rint j "ws_outbound_queue";
    ws_send_stall_s = rfloat j "ws_send_stall_s";
    anon_feed_cache_s = rfloat j "anon_feed_cache_s";
    request_concurrency = rint j "request_concurrency";
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
    relay_proxy =
      (match rstr_opt j "relay_proxy" with
      | None -> None
      | Some p -> (
          let strip pre s = let l = String.length pre in if String.length s >= l && String.sub s 0 l = pre then String.sub s l (String.length s - l) else s in
          let p = String.trim p |> strip "socks5h://" |> strip "socks5://" in
          match String.rindex_opt p ':' with
          | Some i -> ( match int_of_string_opt (String.sub p (i + 1) (String.length p - i - 1)) with Some port -> Some (String.sub p 0 i, port) | None -> raise (Config_error "relay_proxy: expected host:port"))
          | None -> raise (Config_error "relay_proxy: expected host:port")));
    dvm_relays = (match field j "dvm_relays" with `List l -> List.map U.to_string l | _ -> raise (Config_error "dvm_relays: expected a list"));
    dvm_requester_seckey =
      (match rstr_opt j "dvm_requester_seckey" with
      | None -> None
      | Some h -> ( match Hex_util.decode_opt h with Some b when String.length b = 32 -> Some b | _ -> raise (Config_error "dvm_requester_seckey: expected 64 hex characters")));
    internal_http_port = rint j "internal_http_port";
    moderation_http_port = rint j "moderation_http_port";
    upstream_julia_http = rstr_opt j "upstream_julia_http";
    index_dirs = (match field j "index_dirs" with `Assoc l -> List.map (fun (h, d) -> (h, U.to_string d)) l | _ -> raise (Config_error "index_dirs: expected an object"));
    url_shortening_root_url = rstr j "url_shortening_root_url";
    download_proxies = (match field j "download_proxies" with `List l -> List.map U.to_string l | _ -> raise (Config_error "download_proxies: expected a list"));
    s3_providers =
      (match field j "s3_providers" with
      | `List l ->
          List.map
            (fun o ->
              let str k = U.to_string (field o k) and opt k = match field o k with `Null -> None | v -> Some (U.to_string v) in
              { S3.name = str "name"; endpoint = str "endpoint"; region = str "region"; bucket = str "bucket"; bucket2 = opt "bucket2"; access_key = str "access_key"; secret_key = str "secret_key"; domain = opt "domain" })
            l
      | _ -> raise (Config_error "s3_providers: expected a list"));
    cloudflare = (match field j "cloudflare" with `Null -> None | o -> Some (U.to_string (field o "zone_id"), U.to_string (field o "api_key")));
    media_paths =
      (match field j "media_paths" with
      | `List l ->
          List.map
            (fun o ->
              match U.to_string (field o "type") with
              | "local" -> Local { label = (match field o "label" with `Null -> "local" | v -> U.to_string v); root = U.to_string (field o "root") }
              | "s3" -> let provider = U.to_string (field o "provider") in S3_path { label = (match field o "label" with `Null -> provider | v -> U.to_string v); provider }
              | t -> raise (Config_error ("media_paths: unknown type " ^ t)))
            l
      | _ -> raise (Config_error "media_paths: expected a list"));
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
