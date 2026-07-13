(* Pushgateway exporter, mirroring Julia src/pushgateway_exporter.jl (module PushGatewayExporter)
   and the persisted "any" counter from src/cache_storage.jl (load_stats / save_stats).

   Julia's PushGatewayExporter.set!(k, v; job, type) POSTs the Prometheus text-exposition body
   "# TYPE k type\nk v\n" to http://HOST:PORT/metrics/job/<job> (HOSTPORT default 127.0.0.1:9091,
   TIMEOUT 10, type usually :counter). The cache server publishes metric "cache_any" from
   App.network_stats's "any" field — est.commons.stats[:any], the cumulative count of every event
   imported, which Julia persists across restarts in <rootdirectory>/stats.json (the whole stats
   dict; written atomically via tmp + rename, throttled). Grafana graphs the import rate with
   rate(cache_any{exported_job="primalnode<idx>"}[...]), so the value must be a monotonic counter.

   A fiber here reproduces that: it loads the persisted "any" baseline from the same stats.json,
   then every [interval]s publishes baseline + (events imported this session) under metric
   "cache_any" and job [job], and writes the updated total back to the file (preserving the other
   stats keys verbatim). Reloading our own last write as the next baseline keeps the counter
   monotonic across restarts — no double counting, no reset.

   Plain HTTP to an internal host (no TLS, no SOCKS proxy), so it does not go through Http
   (HTTPS/LNURL-over-SOCKS5 only); a tiny POST is hand-rolled over Eio.Net here, using the same
   socket idiom as Firehose_client. Best-effort throughout: a push or save failure (gateway down,
   timeout, unwritable file) is logged and skipped, never fatal — matching Julia's retry=false
   under errormonitor. *)

open Eio.Std

let resolve ~net ~host ~port : Eio.Net.Sockaddr.stream =
  match Eio.Net.getaddrinfo_stream ~service:(string_of_int port) net host with
  | addr :: _ -> addr
  | [] -> failwith (Printf.sprintf "pushgateway: cannot resolve %s:%d" host port)

(* POST [body] as text/plain to http://host:port/path; read and discard the response (bounded and
   time-limited, so a slow/hung pushgateway can't stall the fiber). Raises on connect/IO failure;
   the caller in [run] guards it. *)
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

(* Push several (name, type, value) metrics in ONE body/POST. A pushgateway POST replaces the
   whole metric group for the job, so pushing them together keeps every metric alive. *)
let set_many ~net ~clock ?(timeout = 10.0) ~host ~port ~job
    (metrics : (string * string * int) list) : unit =
  let body =
    String.concat ""
      (List.map (fun (k, typ, v) -> Printf.sprintf "# TYPE %s %s\n%s %d\n" k typ k v) metrics)
  in
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

let metric_name = "cache_any"

(* Loop forever (intended as a fiber on the main domain, where the Eio net/clock live): every
   [interval]s, recompute the monotonic "any" total (persisted baseline + this session's imported
   count), persist it back to [stats_file], and push it under [job]. *)
let run ~net ~clock ~(stats : Stats.t) ~host ~port ~job ~stats_file ~(interval : float) () : unit =
  (* The stats file's directory may not exist on a fresh box; create it once so save_stats does
     not fail every cycle with Sys_error. *)
  (try mkdir_p (Filename.dirname stats_file)
   with exn -> Printf.eprintf "pushgateway: mkdir %s: %s\n%!" (Filename.dirname stats_file)
       (Printexc.to_string exn));
  let base_fields, base_any = load_stats stats_file in
  (* Device-push metrics window (Julia PushNotifications.monitor_subprocess_operation publishes
     push_notification_sent as the count since its last POST, then resets). *)
  let p_push_sent = ref 0 in
  Printf.printf
    "pushgateway: http://%s:%d job=%s metric=%s every %.0fs (stats file %s, baseline any=%d)\n%!"
    host port job metric_name interval stats_file base_any;
  while true do
    let any = base_any + Stats.imported_total stats in
    save_stats stats_file base_fields any;
    let lnurl_ok, lnurl_fail, lnurl_timeout = Stats.lnurl_totals stats in
    let metrics =
      [
        (metric_name, "counter", any);
        ("importer_queue_depth", "gauge", Stats.queue_depth stats);
        ("importer_busy_workers", "gauge", Stats.busy_workers stats);
        ("importer_errors_total", "counter", Stats.errors_total stats);
        ("importer_lnurl_ok_total", "counter", lnurl_ok);
        ("importer_lnurl_fail_total", "counter", lnurl_fail);
        ("importer_lnurl_timeout_total", "counter", lnurl_timeout);
      ]
    in
    (* Device-push metrics (Julia PushGatewayExporter push_notification_latest/_sent), merged into
       this job's group — a pushgateway POST replaces the whole group, so they must ride in the
       same body as cache_any to coexist. Published only once a send has happened, so
       "time() - push_notification_latest" panels don't alarm on a since-boot zero. *)
    let metrics =
      let latest = Stats.push_latest stats in
      if latest = 0 then metrics
      else begin
        let total = Stats.push_sent_total stats in
        let d_sent = total - !p_push_sent in
        p_push_sent := total;
        metrics
        @ [
            ("push_notification_latest", "gauge", latest);
            ("push_notification_sent", "gauge", d_sent);
          ]
      end
    in
    (try set_many ~net ~clock ~host ~port ~job metrics with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Printf.eprintf "pushgateway: %s\n%!" (Printexc.to_string exn));
    Eio.Time.sleep clock interval
  done
