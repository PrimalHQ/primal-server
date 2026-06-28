(* Firehose client, mirroring Julia src/firehose_client.jl (module FirehoseClient).

   Connects to the firehose TCP server, sends the "STREAM-NEW-EVENTS" request, and reads
   newline-delimited JSON messages, invoking [on_message] for each. On disconnect or error it
   waits [reconnect_delay] and reconnects, for as long as [running] is true. *)

open Eio.Std

let stream_request = "STREAM-NEW-EVENTS\n"

let resolve ~net ~host ~port : Eio.Net.Sockaddr.stream =
  match Eio.Net.getaddrinfo_stream ~service:(string_of_int port) net host with
  | addr :: _ -> addr
  | [] -> failwith (Printf.sprintf "firehose: cannot resolve %s:%d" host port)

(* One connection attempt: stream lines to [on_message] until EOF / empty line / error. *)
let session ~net ~host ~port ~on_message =
  Switch.run @@ fun sw ->
  let addr = resolve ~net ~host ~port in
  let flow = Eio.Net.connect ~sw net addr in
  Eio.Flow.copy_string stream_request (flow :> _ Eio.Flow.sink);
  let r = Eio.Buf_read.of_flow (flow :> _ Eio.Flow.source) ~max_size:(64 * 1024 * 1024) in
  let rec loop () =
    match Eio.Buf_read.line r with
    | "" -> () (* Julia: empty line -> break and reconnect *)
    | line ->
        on_message line;
        loop ()
    | exception End_of_file -> ()
  in
  loop ()

let run ?(reconnect_delay = 1.0) ?(running = fun () -> true) ?(on_reconnect = fun () -> ())
    ~net ~clock ~host ~port ~(on_message : string -> unit) () =
  while running () do
    (try session ~net ~host ~port ~on_message with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Printf.eprintf "firehose: %s\n%!" (Printexc.to_string exn));
    (* the session ended (EOF / empty line / error): count the reconnect about to happen *)
    if running () then begin
      on_reconnect ();
      Eio.Time.sleep clock reconnect_delay
    end
  done
