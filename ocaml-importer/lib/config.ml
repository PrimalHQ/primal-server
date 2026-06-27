(* Runtime configuration from the environment, mirroring the globals set in
   start_media_importer.jl (FirehoseClient.PORT = 9000+NODEIDX, VERIFY_ZAPPERS, Main.PROXY). *)

type t = {
  firehose_host : string;
  firehose_port : int;
  num_workers : int;
  queue_capacity : int;
  proxy : string option; (* SOCKS5 "host:port" (or "socks5h://host:port") for LNURL *)
  cs : Cache_storage.config;
}

let getenv = Sys.getenv_opt
let int_env name default = match getenv name with Some v -> int_of_string v | None -> default

let bool_env name default =
  match getenv name with
  | Some ("1" | "true" | "yes" | "on") -> true
  | Some ("0" | "false" | "no" | "off") -> false
  | _ -> default

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
  {
    firehose_host = Option.value (getenv "PRIMALSERVER_FIREHOSE_HOST") ~default:"127.0.0.1";
    firehose_port = int_env "PRIMALSERVER_FIREHOSE_PORT" (9000 + node_idx);
    num_workers = int_env "IMPORTER_WORKERS" 4;
    queue_capacity = int_env "IMPORTER_QUEUE_CAPACITY" 10_000;
    proxy = Option.bind (getenv "PRIMALSERVER_PROXY") normalize_proxy;
    cs =
      {
        Cache_storage.verification_enabled = bool_env "IMPORTER_VERIFY" true;
        verify_zappers = bool_env "VERIFY_ZAPPERS" true;
        trusted_zappers = [];
        disable_trustrank = bool_env "IMPORTER_DISABLE_TRUSTRANK" false;
      };
  }
