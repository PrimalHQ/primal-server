(* Worker pool: a bounded cross-domain queue feeding N worker domains.

   This replaces the Threads.@spawn in Julia's start_media_importer.jl. The firehose reader
   (main domain) submits raw messages to the queue; [Eio.Stream] provides backpressure (the
   reader blocks when the queue is full) and is safe to share across domains. Each worker runs
   in its own domain with its own DB connections (Eio sockets/switches are domain-local), so
   the workers import in parallel across cores. The spam detector and Filterlist are shared
   mutable state guarded by their own (cross-domain) mutexes. *)

open Eio.Std

(* A unit of import work, stamped with its enqueue time so a worker can report how long it sat
   in the queue. [Msg] is a raw firehose line (parsed + spam-checked by the worker); [Event] is
   an already-parsed Nostr event (e.g. pulled from a remote DB by Event_syncer), which skips
   firehose parsing and the spam detector and goes straight to import_event. *)
type payload = Msg of string | Event of Nostr.t
type job = { enq_at : float; payload : payload }

type t = { queue : job Eio.Stream.t }

let create ~capacity : t = { queue = Eio.Stream.create capacity }

(* Submit a job for import; blocks the caller if the queue is at capacity (backpressure). *)
let submit (t : t) (payload : payload) : unit =
  Eio.Stream.add t.queue { enq_at = Unix.gettimeofday (); payload }

(* Convenience submitters. *)
let submit_msg (t : t) (msg : string) : unit = submit t (Msg msg)
let submit_event (t : t) (e : Nostr.t) : unit = submit t (Event e)

(* Run [n] worker domains. [make_est ()] runs inside each worker domain (after its switch and
   Eio env are set up) and returns that domain's [est] with its own connections. [process est
   msg] handles one message. [on_worker_init i] runs once inside worker [i]'s domain before its
   loop (e.g. to register that domain's Stats phase slot). Never returns (workers loop until the
   program is cancelled). *)
let run ?(on_worker_init : int -> unit = fun _ -> ()) ~(domain_mgr : _ Eio.Domain_manager.t)
    ~(net : _ Eio.Net.t) ~(n : int) ~(make_est : unit -> Cache_storage.est)
    ~(process : Cache_storage.est -> job -> unit) (t : t) : unit =
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
