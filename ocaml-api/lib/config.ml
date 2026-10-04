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
