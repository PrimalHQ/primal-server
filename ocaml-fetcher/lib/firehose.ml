(* Ported from Julia's firehose_server.jl: a line-oriented TCP server on
   firehose_host:firehose_port. A client that sends "STREAM-NEW-EVENTS" receives every broadcast
   line; any other line is logged and ignored. Each subscriber has a bounded queue
   (firehose_queue), dropped when full. On stop every client gets "bye" and is closed. *)

open Eio.Std

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [firehose] %s\n%!" (Procinfo.timestamp ()) s) fmt

type sub = { id : int; q : string Eio.Stream.t; peer : string }
type t = { mu : Mutex.t; subs : (int, sub) Hashtbl.t; mutable next_id : int; capacity : int; stats : Stats.t }

let create ~capacity ~stats = { mu = Mutex.create (); subs = Hashtbl.create 4; next_id = 1; capacity; stats }
let subscribers (t : t) : int = Mutex.protect t.mu (fun () -> Hashtbl.length t.subs)

(* called from any domain *)
let broadcast (t : t) (line : string) : unit =
  Mutex.protect t.mu (fun () ->
      Hashtbl.iter
        (fun _ s ->
          if Eio.Stream.length s.q >= t.capacity then Stats.incr t.stats.firehose_dropped
          else begin
            Eio.Stream.add s.q line;
            Stats.incr t.stats.firehose_sent
          end)
        t.subs)

let subscribe (t : t) ~peer : sub =
  Mutex.protect t.mu (fun () ->
      let id = t.next_id in
      t.next_id <- id + 1;
      let s = { id; q = Eio.Stream.create (t.capacity + 1); peer } in
      Hashtbl.replace t.subs id s;
      s)

let unsubscribe (t : t) (s : sub) : unit = Mutex.protect t.mu (fun () -> Hashtbl.remove t.subs s.id)

let handle (t : t) ~clock ~(stop : unit Promise.t) (flow : _ Eio.Net.stream_socket) (addr : Eio.Net.Sockaddr.stream) : unit =
  let peer = Http_server.string_of_sockaddr addr in
  let r = Eio.Buf_read.of_flow (flow :> _ Eio.Flow.source) ~max_size:(1 lsl 20) in
  let sub = ref None in
  let writer (s : sub) =
    let buf = Buffer.create 65536 in
    let rec loop () =
      let first = Eio.Stream.take s.q in
      Buffer.clear buf;
      Buffer.add_string buf first;
      Buffer.add_char buf '\n';
      let n = ref 1 in
      let rec drain () =
        if !n < 512 then
          match Eio.Stream.take_nonblocking s.q with
          | Some l -> Buffer.add_string buf l; Buffer.add_char buf '\n'; incr n; drain ()
          | None -> ()
      in
      drain ();
      Eio.Flow.copy_string (Buffer.contents buf) (flow :> _ Eio.Flow.sink);
      loop ()
    in
    loop ()
  in
  (try
     Switch.run (fun sw ->
         let reader () =
           let rec loop () =
             match Eio.Buf_read.line r with
             | "STREAM-NEW-EVENTS" ->
                 if !sub = None then begin
                   let s = subscribe t ~peer in
                   sub := Some s;
                   log "subscriber %d (%s)" s.id peer;
                   Fiber.fork ~sw (fun () -> writer s)
                 end;
                 loop ()
             | "" -> ()
             | other -> log "%s: ignored line %S" peer (String.sub other 0 (min 60 (String.length other))); loop ()
             | exception End_of_file -> ()
           in
           loop ()
         in
         Fiber.first reader (fun () -> Promise.await stop; (try Eio.Flow.copy_string "bye\n" (flow :> _ Eio.Flow.sink) with _ -> ()));
         Switch.fail sw Exit)
   with
  | Exit -> ()
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> log "%s: %s" peer (Printexc.to_string exn));
  (match !sub with Some s -> unsubscribe t s; log "subscriber %d gone (%s)" s.id peer | None -> ());
  try Eio.Flow.shutdown flow `All with _ -> ()

let serve (t : t) ~sw ~clock ~(stop : unit Promise.t) (socket : _ Eio.Net.listening_socket) : unit =
  let accept_loop () =
    while true do
      Eio.Net.accept_fork ~sw socket ~on_error:(fun exn -> log "accept: %s" (Printexc.to_string exn)) (fun flow addr -> handle t ~clock ~stop flow addr)
    done
  in
  Fiber.first accept_loop (fun () -> Promise.await stop)
