(* Daemon lifecycle: Starting -> Serving -> Draining -> Stopped (ocaml-plan.md §4.5/§6).

   The drain protocol is the tsunami kernel's: SIGUSR1/SIGTERM/SIGINT handlers only broadcast an
   Eio.Condition (the eio-sanctioned way to wake a fiber from a signal handler); a normal fiber
   resolves the [stop] promise that every accept loop / periodic loop watches. The admin endpoint's
   POST /drain triggers the same transition. [ready] is what /readyz reports (false unless Serving),
   so a load balancer stops sending new connections before the listeners close. *)

open Eio.Std

type state = Starting | Serving | Draining | Stopped

let string_of_state = function
  | Starting -> "starting"
  | Serving -> "serving"
  | Draining -> "draining"
  | Stopped -> "stopped"

type t = {
  mutable state : state;
  stop : unit Promise.t;
  resolve_stop : unit Promise.u;
  cond : Eio.Condition.t;
  mutable reason : string;
  started_at : float;
}

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [lifecycle] %s\n%!" (Procinfo.timestamp ()) s) fmt

(* Why not Sys.set_signal: an OCaml signal handler only runs when the thread that received the
   signal returns to OCaml code. With several domains plus Eio's systhread pool, the kernel may hand
   SIGUSR1 to an idle pool thread that never does, and the drain happened minutes late (seen on
   2026-10-04). So the stop signals are BLOCKED in the calling thread (inherited by every domain and
   thread created afterwards) and consumed synchronously by one dedicated thread with
   Thread.wait_signal; it sets an atomic that a fiber polls every 250 ms. Call this before spawning
   domains. *)
let stop_signals = [ Sys.sigusr1; Sys.sigterm; Sys.sigint ]
let signal_name = function
  | s when s = Sys.sigusr1 -> "SIGUSR1"
  | s when s = Sys.sigterm -> "SIGTERM"
  | s when s = Sys.sigint -> "SIGINT"
  | s -> Printf.sprintf "signal %d" s

let create ~sw ~clock () : t =
  let stop, resolve_stop = Promise.create () in
  let t =
    { state = Starting; stop; resolve_stop; cond = Eio.Condition.create (); reason = "";
      started_at = Unix.gettimeofday () }
  in
  (* SIGPIPE would kill the process on a write to a closed socket. *)
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  let received : string option Atomic.t = Atomic.make None in
  ignore (Unix.sigprocmask Unix.SIG_BLOCK stop_signals);
  ignore
    (Thread.create
       (fun () ->
         let s = Thread.wait_signal stop_signals in
         Atomic.set received (Some (signal_name s)))
       ());
  Fiber.fork_daemon ~sw (fun () ->
      let rec wait () =
        match Atomic.get received with
        | Some name -> name
        | None ->
            if t.state = Draining || t.state = Stopped then t.reason
            else begin
              (* also wake on a programmatic drain request *)
              (match
                 Eio.Time.with_timeout clock 0.25 (fun () -> Eio.Condition.await_no_mutex t.cond; Ok ())
               with
              | Ok () | Error `Timeout -> ());
              if t.reason <> "" then t.reason else wait ()
            end
      in
      let reason = wait () in
      if t.state <> Draining && t.state <> Stopped then begin
        t.state <- Draining;
        t.reason <- reason;
        log "drain requested (%s)" reason;
        Promise.resolve t.resolve_stop ()
      end;
      `Stop_daemon);
  t

let stop (t : t) : unit Promise.t = t.stop
let state (t : t) : state = t.state
let is_ready (t : t) : bool = t.state = Serving
let uptime (t : t) : float = Unix.gettimeofday () -. t.started_at

let serving (t : t) : unit =
  if t.state = Starting then begin
    t.state <- Serving;
    log "serving"
  end

(* Programmatic drain (admin POST /drain, primalctl drain). *)
let request_drain ?(reason = "admin") (t : t) : unit =
  if t.state <> Draining && t.state <> Stopped then begin
    t.reason <- reason;
    Eio.Condition.broadcast t.cond
  end

let stopped (t : t) : unit =
  t.state <- Stopped;
  log "stopped"

(* Wait until [inflight ()] is zero or [grace] seconds passed; returns what is left. *)
let wait_drained ~clock ~(grace : float) (inflight : unit -> int) : int =
  let deadline = Eio.Time.now clock +. grace in
  while inflight () > 0 && Eio.Time.now clock < deadline do
    Eio.Time.sleep clock 0.25
  done;
  inflight ()
