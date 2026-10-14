(* Operator knobs polled from the `wsconnvars` table every wsconnvars_poll_s (ws-connector management_task /
   ws-handlers metrics logger): idle_connection_timeout, metrics_logging_enabled,
   metrics_logging_min_request_duration, logging_enabled. Plus the request log those knobs drive:
   JSON lines {t, time, funcall, kwargs, ws, subid} for handled requests slower than the minimum,
   appended to [request_log] — the input format of the replay tool. *)

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [wsconnvars] %s\n%!" (Procinfo.timestamp ()) s) fmt

(* Current values, readable from any domain. *)
let idle_connection_timeout_ms : int Atomic.t = Atomic.make 600_000
let metrics_logging_enabled : bool Atomic.t = Atomic.make false
let metrics_logging_min_request_duration_ms : int Atomic.t = Atomic.make 0

let idle_connection_timeout_s () = float_of_int (Atomic.get idle_connection_timeout_ms) /. 1000.

(* {1 Request log} *)

let request_log_oc : out_channel option ref = ref None
let request_log_lock = Mutex.create ()

let open_request_log (path : string option) : unit =
  match path with
  | None -> ()
  | Some p -> (
      try request_log_oc := Some (open_out_gen [ Open_append; Open_creat; Open_wronly ] 0o644 p)
      with Sys_error m -> log "cannot open request log %s: %s" p m)

let log_request ~(funcall : string) ~(kwargs : Yojson.Safe.t) ~(conn_id : int) ~(subid : string)
    ~(elapsed_s : float) : unit =
  if Atomic.get metrics_logging_enabled
     && elapsed_s *. 1000. >= float_of_int (Atomic.get metrics_logging_min_request_duration_ms)
  then
    match !request_log_oc with
    | None -> ()
    | Some oc ->
        let line =
          Yojson.Safe.to_string
            (`Assoc
              [
                ("t", `Float (Unix.gettimeofday ()));
                ("time", `Float elapsed_s);
                ("funcall", `String funcall);
                ("kwargs", kwargs);
                ("ws", `String (string_of_int conn_id));
                ("subid", `String subid);
              ])
        in
        Mutex.lock request_log_lock;
        (try output_string oc line; output_char oc '\n'; flush oc with _ -> ());
        Mutex.unlock request_log_lock

(* {1 Poller} (main domain; uses that domain's cache pool) *)

let read_var ~clock name : Yojson.Safe.t option =
  match Db.with_cache ~clock (fun c -> Queries.wsconnvar c ~name) with
  | Some s -> ( try Some (Yojson.Safe.from_string s) with _ -> None)
  | None -> None

let poll_once ~clock : unit =
  (match read_var ~clock "idle_connection_timeout" with
  | Some (`Int n) -> Atomic.set idle_connection_timeout_ms (n * 1000)
  | Some (`Float f) -> Atomic.set idle_connection_timeout_ms (int_of_float (f *. 1000.))
  | _ -> ());
  (match read_var ~clock "metrics_logging_enabled" with
  | Some (`Bool b) -> Atomic.set metrics_logging_enabled b
  | _ -> Atomic.set metrics_logging_enabled false);
  match read_var ~clock "metrics_logging_min_request_duration" with
  | Some (`Float f) -> Atomic.set metrics_logging_min_request_duration_ms (int_of_float (f *. 1000.))
  | Some (`Int n) -> Atomic.set metrics_logging_min_request_duration_ms (n * 1000)
  | _ -> Atomic.set metrics_logging_min_request_duration_ms 0

let run ~clock ~(period : float) ~(default_idle_s : float) : unit =
  Atomic.set idle_connection_timeout_ms (int_of_float (default_idle_s *. 1000.));
  while true do
    (try poll_once ~clock with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> log "poll: %s" (Printexc.to_string exn));
    Eio.Time.sleep clock period
  done
