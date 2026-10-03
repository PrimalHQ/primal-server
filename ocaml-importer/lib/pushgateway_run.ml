(* The importer's pushgateway exporter fiber, mirroring Julia src/pushgateway_exporter.jl usage
   and the persisted "any" counter from src/cache_storage.jl (load_stats / save_stats).

   The cache server publishes metric "cache_any" from App.network_stats's "any" field —
   est.commons.stats[:any], the cumulative count of every event imported, which Julia persists
   across restarts in <rootdirectory>/stats.json (the whole stats dict; written atomically via tmp
   + rename, throttled). Grafana graphs the import rate with
   rate(cache_any{exported_job="primalnode<idx>"}[...]), so the value must be a monotonic counter.

   This fiber reproduces that: it loads the persisted "any" baseline from the same stats.json,
   then every [interval]s publishes baseline + (events imported this session) under metric
   "cache_any" and job [job], and writes the updated total back to the file (preserving the other
   stats keys verbatim). Reloading our own last write as the next baseline keeps the counter
   monotonic across restarts — no double counting, no reset. The HTTP POST and the stats.json
   helpers live in primal_common's Pushgateway. *)

let metric_name = "cache_any"

(* Loop forever (intended as a fiber on the main domain, where the Eio net/clock live). *)
let run ~net ~clock ~(stats : Stats.t) ~host ~port ~job ~stats_file ~(interval : float) () : unit =
  (* The stats file's directory may not exist on a fresh box; create it once so save_stats does
     not fail every cycle with Sys_error. *)
  (try Pushgateway.mkdir_p (Filename.dirname stats_file)
   with exn ->
     Printf.eprintf "pushgateway: mkdir %s: %s\n%!" (Filename.dirname stats_file)
       (Printexc.to_string exn));
  let base_fields, base_any = Pushgateway.load_stats stats_file in
  (* Device-push metrics window (Julia PushNotifications.monitor_subprocess_operation publishes
     push_notification_sent as the count since its last POST, then resets). *)
  let p_push_sent = ref 0 in
  Printf.printf
    "pushgateway: http://%s:%d job=%s metric=%s every %.0fs (stats file %s, baseline any=%d)\n%!"
    host port job metric_name interval stats_file base_any;
  while true do
    let any = base_any + Stats.imported_total stats in
    Pushgateway.save_stats stats_file base_fields any;
    let lnurl_ok, lnurl_fail, lnurl_timeout = Stats.lnurl_totals stats in
    let zap_ok, zap_retry, zap_unverified, zap_dropped = Stats.zap_totals stats in
    let metrics =
      [
        (metric_name, "counter", any);
        ("importer_queue_depth", "gauge", Stats.queue_depth stats);
        ("importer_busy_workers", "gauge", Stats.busy_workers stats);
        ("importer_errors_total", "counter", Stats.errors_total stats);
        ("importer_lnurl_ok_total", "counter", lnurl_ok);
        ("importer_lnurl_fail_total", "counter", lnurl_fail);
        ("importer_lnurl_timeout_total", "counter", lnurl_timeout);
        (* zap_dropped rising is the alertable one: those zaps are uncounted for good. *)
        ("importer_zap_verified_total", "counter", zap_ok);
        ("importer_zap_retry_total", "counter", zap_retry);
        ("importer_zap_unverified_total", "counter", zap_unverified);
        ("importer_zap_dropped_total", "counter", zap_dropped);
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
    (try Pushgateway.set_many ~net ~clock ~host ~port ~job metrics with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Printf.eprintf "pushgateway: %s\n%!" (Printexc.to_string exn));
    Eio.Time.sleep clock interval
  done
