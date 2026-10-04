(* primal-jobs configuration: one JSON file, every key required (as the other daemons). *)

exception Config_error of string

module U = Yojson.Safe.Util

type role = Dvm_checker | Pg_listener | Trustrank | Analytics | Dag | Rebroadcast | Failover | Media | Ext of string (* a role the private extensions register (Roles) *)

let role_of_string = function
  | "dvm_checker" -> Dvm_checker
  | "pg_listener" -> Pg_listener
  | "trustrank" -> Trustrank
  | "analytics" -> Analytics
  | "dag" -> Dag
  | "rebroadcast" -> Rebroadcast
  | "failover" -> Failover
  | "media" -> Media
  | s -> Ext s

let string_of_role = function Dvm_checker -> "dvm_checker" | Pg_listener -> "pg_listener" | Trustrank -> "trustrank" | Analytics -> "analytics" | Dag -> "dag" | Rebroadcast -> "rebroadcast" | Failover -> "failover" | Media -> "media" | Ext s -> s

type t = {
  roles : role list;
  admin_host : string;
  admin_port : int;
  cache_db : Postgres.conninfo;
  membership_db : Postgres.conninfo;
  relay_proxy : (string * int) option; (* SOCKS5 for outbound relay connections (Main.PROXY) *)
  (* dvm_checker (dvm_feed_checker.jl) *)
  dvm_relays : string list; (* DVMFeedChecker.RELAYS *)
  dvm_requester_seckey : string; (* raw 32 bytes; App.DVM_REQUESTER_KEYPAIR *)
  dvm_requester_pubkey : string; (* raw 32 bytes; DVMFeedChecker.DVM_REQUESTER_PUBKEY (the "user" of personalized feeds) *)
  dvm_check_period_s : float; (* RUN_PERIOD 600 *)
  dvm_timeout_s : float; (* TIMEOUT 30 *)
  dvm_parallel : int; (* asyncmap ntasks 8 *)
  dvm_randomized_delays : bool;
  dvm_log : bool;
  (* pg_listener (cache_storage_pg_listener.jl) *)
  pg_listener_rate_limit_s : int; (* RATE_LIMIT_PERIOD 3600 *)
  pg_listener_log : bool;
  (* trustrank (trustrank_maker.jl) *)
  trustrank_period_s : float; (* RUN_PERIOD 3 h *)
  trustrank_iterations : int; (* 20 *)
  trustrank_alpha : float; (* 0.85 *)
  trustrank_target_table : string; (* "pubkey_trustrank" = live swap; anything else = shadow table *)
  trustrank_run_at_start : bool; (* Julia waits one period first *)
  (* analytics (App.precalculate_analytics) *)
  api_config_path : string; (* primal-api-config.json: scored_content runs with the API's settings *)
  analytics_period_s : float; (* 600 *)
  analytics_key_suffix : string; (* "" = the live cache keys; "_ocaml" = shadow keys *)
  ollama_host : string option; (* App.OLLAMA_HOST; null disables gaming detection *)
  gaming_report_command : string list option; (* App.GAMING_REPORT_COMMAND argv; the report is its stdin *)
  (* dag (dag_runner.jl) *)
  dag_period_s : float; (* RUN_PERIOD 5 *)
  dag_tasks : int; (* PROCESS_SEGMENTS_TASKS 8 *)
  dag_dry_run : bool; (* roll every segment back, write no coverage *)
  dag_since : int; (* initial since; Julia: 2023-01-01 *)
  dag_poll_votes_enabled : bool; (* DAG.POLL_VOTE_IMPORT_ENABLED *)
  dag_log : bool;
  dag_dry_run_window_s : int;
  pushgateway : (string * int * string) option;
  membership_discovery_url : string option;
  media : Primal_jobs_media.Media_config.t option;
  ext : Yojson.Safe.t; (* the "ext" object for the private extensions; `Null when absent *) (* the "media" sub-object (ocaml-plan.md §10); null unless the media role runs *) (* Postgres.Server.tracking_url of the membership server *) (* host, port, job: dag_runner_duration / dag_runner_all_ok as PushGatewayExporter did *) (* with dag_dry_run: exercise every node once over the last N seconds (coverage ignored), then idle; 0 = coverage-based dry run *)
}

let field j key = match j with `Assoc f -> ( match List.assoc_opt key f with Some v -> v | None -> raise (Config_error ("missing key " ^ key))) | _ -> raise (Config_error "config must be an object")
let rstr j k = try U.to_string (field j k) with U.Type_error _ -> raise (Config_error (k ^ ": expected a string"))
let rstr_opt j k = match field j k with `Null -> None | v -> Some (U.to_string v)
let rint j k = try U.to_int (field j k) with U.Type_error _ -> raise (Config_error (k ^ ": expected an integer"))
let rfloat j k = match field j k with `Int i -> float_of_int i | `Float f -> f | _ -> raise (Config_error (k ^ ": expected a number"))
let rbool j k = try U.to_bool (field j k) with U.Type_error _ -> raise (Config_error (k ^ ": expected a boolean"))
let rlist j k = match field j k with `List l -> List.map U.to_string l | _ -> raise (Config_error (k ^ ": expected a list"))

let conninfo_of_json (j : Yojson.Safe.t) : Postgres.conninfo =
  { Postgres.host = rstr j "host"; port = rint j "port"; user = rstr j "user"; database = rstr j "database" }

let hex32 j k = match Hex_util.decode_opt (rstr j k) with Some b when String.length b = 32 -> b | _ -> raise (Config_error (k ^ ": expected 64 hex characters"))

let proxy_of_json j k =
  match rstr_opt j k with
  | None -> None
  | Some p -> (
      let strip pre s = let l = String.length pre in if String.length s >= l && String.sub s 0 l = pre then String.sub s l (String.length s - l) else s in
      let p = String.trim p |> strip "socks5h://" |> strip "socks5://" in
      match String.rindex_opt p ':' with
      | Some i -> ( match int_of_string_opt (String.sub p (i + 1) (String.length p - i - 1)) with Some port -> Some (String.sub p 0 i, port) | None -> raise (Config_error (k ^ ": expected host:port")))
      | None -> raise (Config_error (k ^ ": expected host:port")))

let of_json (j : Yojson.Safe.t) : t =
  {
    roles = List.map role_of_string (rlist j "roles");
    admin_host = rstr j "admin_host";
    admin_port = rint j "admin_port";
    cache_db = conninfo_of_json (field j "cache_db");
    membership_db = conninfo_of_json (field j "membership_db");
    relay_proxy = proxy_of_json j "relay_proxy";
    dvm_relays = rlist j "dvm_relays";
    dvm_requester_seckey = hex32 j "dvm_requester_seckey";
    dvm_requester_pubkey = hex32 j "dvm_requester_pubkey";
    dvm_check_period_s = rfloat j "dvm_check_period_s";
    dvm_timeout_s = rfloat j "dvm_timeout_s";
    dvm_parallel = rint j "dvm_parallel";
    dvm_randomized_delays = rbool j "dvm_randomized_delays";
    dvm_log = rbool j "dvm_log";
    pg_listener_rate_limit_s = rint j "pg_listener_rate_limit_s";
    pg_listener_log = rbool j "pg_listener_log";
    trustrank_period_s = rfloat j "trustrank_period_s";
    trustrank_iterations = rint j "trustrank_iterations";
    trustrank_alpha = rfloat j "trustrank_alpha";
    trustrank_target_table = rstr j "trustrank_target_table";
    trustrank_run_at_start = rbool j "trustrank_run_at_start";
    api_config_path = rstr j "api_config_path";
    analytics_period_s = rfloat j "analytics_period_s";
    analytics_key_suffix = rstr j "analytics_key_suffix";
    ollama_host = rstr_opt j "ollama_host";
    gaming_report_command = (match field j "gaming_report_command" with `Null -> None | `List l -> Some (List.map U.to_string l) | _ -> raise (Config_error "gaming_report_command: expected a list or null"));
    dag_period_s = rfloat j "dag_period_s";
    dag_tasks = rint j "dag_tasks";
    dag_dry_run = rbool j "dag_dry_run";
    dag_since = rint j "dag_since";
    dag_poll_votes_enabled = rbool j "dag_poll_votes_enabled";
    dag_log = rbool j "dag_log";
    dag_dry_run_window_s = rint j "dag_dry_run_window_s";
    pushgateway = (match field j "pushgateway" with `Null -> None | o -> Some (rstr o "host", rint o "port", rstr o "job"));
    membership_discovery_url = rstr_opt j "membership_discovery_url";
    ext = (match j with `Assoc f -> Option.value (List.assoc_opt "ext" f) ~default:`Null | _ -> `Null);
    media = (match (match j with `Assoc f -> Option.value (List.assoc_opt "media" f) ~default:`Null | _ -> `Null) with `Null -> None | o -> ( try Some (Primal_jobs_media.Media_config.of_json o) with Primal_jobs_media.Media_config.Config_error m -> raise (Config_error m)));
  }

let of_json_file (path : string) : t =
  let j = try Yojson.Safe.from_file path with Yojson.Json_error msg -> raise (Config_error (Printf.sprintf "%s: invalid JSON: %s" path msg)) in
  of_json j
