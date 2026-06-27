(* Worker pool: a bounded cross-domain queue feeding N worker domains.

   This replaces the Threads.@spawn in Julia's start_media_importer.jl. The firehose reader
   (main domain) submits raw messages to the queue; [Eio.Stream] provides backpressure (the
   reader blocks when the queue is full) and is safe to share across domains. Each worker runs
   in its own domain with its own DB connections (Eio sockets/switches are domain-local), so
   the workers import in parallel across cores. The spam detector and Filterlist are shared
   mutable state guarded by their own (cross-domain) mutexes. *)

open Eio.Std

type t = { queue : string Eio.Stream.t }

let create ~capacity : t = { queue = Eio.Stream.create capacity }

(* Submit a message for import; blocks the caller if the queue is at capacity. *)
let submit (t : t) (msg : string) : unit = Eio.Stream.add t.queue msg

(* Run [n] worker domains. [make_est ()] runs inside each worker domain (after its switch and
   Eio env are set up) and returns that domain's [est] with its own connections. [process est
   msg] handles one message. Never returns (workers loop until the program is cancelled). *)
let run ~(domain_mgr : _ Eio.Domain_manager.t) ~(net : _ Eio.Net.t) ~(n : int)
    ~(make_est : unit -> Cache_storage.est) ~(process : Cache_storage.est -> string -> unit)
    (t : t) : unit =
  let net = (net :> Postgres.net_t) in
  let worker _i () =
    Eio.Domain_manager.run domain_mgr (fun () ->
        Switch.run @@ fun sw ->
        Postgres.set_env ~net ~sw;
        let est = make_est () in
        let rec loop () =
          let msg = Eio.Stream.take t.queue in
          (try process est msg with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn -> Printf.eprintf "worker: %s\n%!" (Printexc.to_string exn));
          loop ()
        in
        loop ())
  in
  Fiber.all (List.init n (fun i -> worker i))
