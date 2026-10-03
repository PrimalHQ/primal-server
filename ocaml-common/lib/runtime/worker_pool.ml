(* Worker pool: a bounded cross-domain queue feeding N worker domains.

   The producer (main domain) submits jobs to the queue; [Eio.Stream] provides backpressure (the
   producer blocks when the queue is full) and is safe to share across domains. Each worker runs
   in its own domain with its own per-domain state (DB connections — Eio sockets/switches are
   domain-local), so the workers process in parallel across cores. Any shared mutable state the
   workers touch must be guarded by cross-domain mutexes by the caller.

   Generic over the per-domain state ['est] (the importer's [Cache_storage.est], an API daemon's
   pool set, ...). *)

open Eio.Std

(* A unit of work, stamped with its enqueue time so a worker can report how long it sat in the
   queue. [Msg] is a raw line (parsed by the worker); [Event] is an already-parsed Nostr event. *)
type payload = Msg of string | Event of Nostr.t
type job = { enq_at : float; payload : payload }
type t = { queue : job Eio.Stream.t }

let create ~capacity : t = { queue = Eio.Stream.create capacity }

(* Submit a job; blocks the caller if the queue is at capacity (backpressure). *)
let submit (t : t) (payload : payload) : unit =
  Eio.Stream.add t.queue { enq_at = Unix.gettimeofday (); payload }

let submit_msg (t : t) (msg : string) : unit = submit t (Msg msg)
let submit_event (t : t) (e : Nostr.t) : unit = submit t (Event e)

(* Run [n] worker domains. [make_est ()] runs inside each worker domain (after its switch and Eio
   env are set up) and returns that domain's state with its own connections. [process est job]
   handles one job. [on_worker_init i] runs once inside worker [i]'s domain before its loop (e.g. to
   register that domain's phase slot). Never returns (workers loop until cancelled). *)
let run ?(on_worker_init : int -> unit = fun _ -> ()) ~(domain_mgr : _ Eio.Domain_manager.t)
    ~(net : _ Eio.Net.t) ~(n : int) ~(make_est : unit -> 'est) ~(process : 'est -> job -> unit)
    (t : t) : unit =
  let net = (net :> Postgres.net_t) in
  let worker i () =
    Eio.Domain_manager.run domain_mgr (fun () ->
        Switch.run @@ fun sw ->
        Postgres.set_env ~net ~sw;
        on_worker_init i;
        let est = make_est () in
        let rec loop () =
          let job = Eio.Stream.take t.queue in
          (try process est job with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn -> Printf.eprintf "worker: %s\n%!" (Printexc.to_string exn));
          loop ()
        in
        loop ())
  in
  Fiber.all (List.init n (fun i -> worker i))
