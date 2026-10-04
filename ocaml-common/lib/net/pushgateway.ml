(* Prometheus pushgateway client, mirroring Julia src/pushgateway_exporter.jl (PushGatewayExporter):
   set!(k, v; job, type) POSTs the text-exposition body "# TYPE k type\nk v\n" to
   http://HOST:PORT/metrics/job/<job> (HOSTPORT default 127.0.0.1:9091, TIMEOUT 10). A pushgateway
   POST replaces the whole metric group of the job, so metrics that must coexist go in ONE body
   ([set_many]).

   Plain HTTP to an internal host (no TLS, no SOCKS proxy), so it does not go through Http; a tiny
   POST is hand-rolled over Eio.Net. Also carries the Julia stats.json helpers (load_stats /
   save_stats from src/cache_storage.jl) that daemons use to persist monotonic counters across
   restarts. Best-effort throughout: callers log and skip failures, never die. *)

open Eio.Std

let resolve ~net ~host ~port : Eio.Net.Sockaddr.stream =
  match Eio.Net.getaddrinfo_stream ~service:(string_of_int port) net host with
  | addr :: _ -> addr
  | [] -> failwith (Printf.sprintf "pushgateway: cannot resolve %s:%d" host port)

(* POST [body] as text/plain to http://host:port/path; read and discard the response (bounded and
   time-limited, so a slow/hung pushgateway can't stall the fiber). Raises on connect/IO failure. *)
let post ~net ~clock ?(timeout = 10.0) ~host ~port ~path (body : string) : unit =
  Switch.run @@ fun sw ->
  let flow = Eio.Net.connect ~sw net (resolve ~net ~host ~port) in
  let req =
    Printf.sprintf
      "POST %s HTTP/1.1\r\nHost: %s:%d\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
      path host port (String.length body) body
  in
  Eio.Flow.copy_string req (flow :> _ Eio.Flow.sink);
  ignore
    (Eio.Time.with_timeout clock timeout (fun () ->
         let r = Eio.Buf_read.of_flow (flow :> _ Eio.Flow.source) ~max_size:(64 * 1024) in
         Ok (Eio.Buf_read.take_all r)))

(* Push one metric, mirroring PushGatewayExporter.set!(k, v; job, type). *)
let set ~net ~clock ?(timeout = 10.0) ?(typ = "counter") ~host ~port ~job (k : string) (v : int) :
    unit =
  let body = Printf.sprintf "# TYPE %s %s\n%s %d\n" k typ k v in
  post ~net ~clock ~timeout ~host ~port ~path:("/metrics/job/" ^ job) body

(* Push several (name, type, value) metrics in ONE body/POST. *)
let set_many ~net ~clock ?(timeout = 10.0) ~host ~port ~job
    (metrics : (string * string * int) list) : unit =
  let body =
    String.concat ""
      (List.map (fun (k, typ, v) -> Printf.sprintf "# TYPE %s %s\n%s %d\n" k typ k v) metrics)
  in
  post ~net ~clock ~timeout ~host ~port ~path:("/metrics/job/" ^ job) body

(* Push several metrics whose values are already formatted (floats allowed), one POST. *)
let set_values ~net ~clock ?(timeout = 10.0) ~host ~port ~job (metrics : (string * string * string) list) : unit =
  let body = String.concat "" (List.map (fun (k, typ, v) -> Printf.sprintf "# TYPE %s %s\n%s %s\n" k typ k v) metrics) in
  post ~net ~clock ~timeout ~host ~port ~path:("/metrics/job/" ^ job) body

let rec mkdir_p (d : string) : unit =
  if d <> "/" && d <> "." && not (Sys.file_exists d) then begin
    mkdir_p (Filename.dirname d);
    try Unix.mkdir d 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

(* Load the full stats.json object (kept verbatim so the other keys survive a write) and the
   current "any" total. Missing file / parse error -> ([], 0). Mirrors Julia load_stats. *)
let load_stats (path : string) : (string * Yojson.Safe.t) list * int =
  try
    match Yojson.Safe.from_file path with
    | `Assoc fields ->
        let any =
          match List.assoc_opt "any" fields with
          | Some (`Int n) -> n
          | Some (`Intlit s) -> ( try int_of_string s with _ -> 0)
          | Some (`Float f) -> int_of_float f
          | _ -> 0
        in
        (fields, any)
    | _ -> ([], 0)
  with _ -> ([], 0)

(* Atomically write [fields] with "any" set to [any] (tmp file + rename), mirroring Julia
   save_stats. Best-effort: failure is logged, never fatal. *)
let save_stats (path : string) (fields : (string * Yojson.Safe.t) list) (any : int) : unit =
  try
    let replaced = ref false in
    let fields =
      List.map
        (fun (k, v) -> if k = "any" then ( replaced := true; (k, `Int any)) else (k, v))
        fields
    in
    let fields = if !replaced then fields else fields @ [ ("any", `Int any) ] in
    let tmp = path ^ ".tmp" in
    let oc = open_out tmp in
    Fun.protect
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc (Yojson.Safe.to_string (`Assoc fields)));
    Sys.rename tmp path
  with exn -> Printf.eprintf "pushgateway: save_stats %s: %s\n%!" path (Printexc.to_string exn)
