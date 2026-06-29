(* Pushgateway exporter, mirroring Julia src/pushgateway_exporter.jl (module PushGatewayExporter).

   Julia's PushGatewayExporter.set!(k, v; job, type) POSTs the Prometheus text-exposition body
   "# TYPE k type\nk v\n" to http://HOST:PORT/metrics/job/<job> (HOSTPORT default 127.0.0.1:9091,
   TIMEOUT 10, type usually :counter). A fiber here does the same on a timer: every [interval]
   seconds it pushes the importer's cumulative imported-event count (Stats.imported_total — the
   [tot] in the per-second log line) as a counter named "cache_imported", under job [job]
   (default "cache_any"). Pushgateway keeps the last value pushed per (job, metric); since the
   value is a monotonic counter, Prometheus derives the import rate via rate().

   This is plain HTTP to an internal host (no TLS, no SOCKS proxy), so it does not go through Http
   (HTTPS/LNURL-over-SOCKS5 only) — a tiny POST is hand-rolled over Eio.Net here, using the same
   socket idiom as Firehose_client.

   Best-effort: a push failure (pushgateway down, timeout, refused) is logged and skipped, never
   fatal — matching Julia's retry=false under errormonitor. *)

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

let metric_name = "cache_imported"

(* Loop forever (intended as a fiber on the main domain, where the Eio net/clock live): every
   [interval]s push the cumulative imported count under [job]. *)
let run ~net ~clock ~(stats : Stats.t) ~host ~port ~job ~(interval : float) () : unit =
  Printf.printf "pushgateway: http://%s:%d job=%s metric=%s every %.0fs\n%!" host port job
    metric_name interval;
  while true do
    let imported = Stats.imported_total stats in
    (try set ~net ~clock ~host ~port ~job metric_name imported with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Printf.eprintf "pushgateway: %s\n%!" (Printexc.to_string exn));
    Eio.Time.sleep clock interval
  done
