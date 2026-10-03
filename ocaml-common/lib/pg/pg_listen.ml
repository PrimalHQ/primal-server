(* Dedicated LISTEN connection (from the tsunami kernel's lib/pg_listen.ml).

   PGOCaml 4.4 exposes no NotificationResponse API, so this module speaks just enough of the
   PostgreSQL v3 wire protocol on a raw Eio socket to LISTEN on a set of channels and dispatch
   notifications: StartupMessage -> AuthenticationOk (trust only, matching our pg_hba setup) ->
   ReadyForQuery -> one simple Query with the LISTEN statements -> blocking read loop for 'A'
   messages.

   The connection carries no other traffic, so a blocking Buf_read suspends the fiber until the
   server pushes a notification. [run] reconnects forever with backoff; consumers that must not
   miss a notification across reconnects pair it with a timeout-based fallback poll. *)

open Eio.Std

let log fmt = Printf.ksprintf (fun s -> Printf.printf "[pg-listen] %s\n%!" s) fmt

let be32 (n : int) : string =
  let b = Bytes.create 4 in
  Bytes.set b 0 (Char.chr ((n lsr 24) land 0xff));
  Bytes.set b 1 (Char.chr ((n lsr 16) land 0xff));
  Bytes.set b 2 (Char.chr ((n lsr 8) land 0xff));
  Bytes.set b 3 (Char.chr (n land 0xff));
  Bytes.to_string b

let read_be32 (s : string) (off : int) : int =
  let b k = Char.code s.[off + k] in
  (b 0 lsl 24) lor (b 1 lsl 16) lor (b 2 lsl 8) lor b 3

let read_cstring (s : string) (off : int) : string * int =
  match String.index_from_opt s off '\000' with
  | Some z -> (String.sub s off (z - off), z + 1)
  | None -> failwith "pg-listen: unterminated cstring"

type msg = { typ : char; body : string }

let read_msg reader : msg =
  let typ = Eio.Buf_read.any_char reader in
  let len_s = Eio.Buf_read.take 4 reader in
  let len = read_be32 len_s 0 in
  let body = if len > 4 then Eio.Buf_read.take (len - 4) reader else "" in
  { typ; body }

let error_message (body : string) : string =
  (* ErrorResponse: sequence of (code byte, cstring) fields until a zero byte. *)
  let buf = Buffer.create 64 in
  let rec go off =
    if off < String.length body && body.[off] <> '\000' then begin
      let field, off' = read_cstring body (off + 1) in
      if body.[off] = 'S' || body.[off] = 'C' || body.[off] = 'M' then begin
        Buffer.add_string buf field;
        Buffer.add_char buf ' '
      end;
      go off'
    end
  in
  go 0;
  String.trim (Buffer.contents buf)

let connect_and_listen ~net ~sw (ci : Postgres.conninfo) ~(channels : string list)
    ~(on_notify : channel:string -> payload:string -> unit) : unit =
  let sockaddr = Unix.ADDR_INET (Unix.inet_addr_of_string ci.Postgres.host, ci.Postgres.port) in
  let addr = Eio_unix.Net.sockaddr_of_unix_stream sockaddr in
  let sock = Eio.Net.connect ~sw net addr in
  let flow = (sock :> Eio_unix.Net.stream_socket_ty r) in
  let reader = Eio.Buf_read.of_flow (flow :> Eio.Flow.source_ty r) ~max_size:(4 * 1024 * 1024) in
  let send (s : string) = Eio.Flow.copy_string s (flow :> Eio.Flow.sink_ty r) in
  (* StartupMessage: length, protocol 3.0, key\0value\0 pairs, final \0. *)
  let params =
    Printf.sprintf "user\000%s\000database\000%s\000\000" ci.Postgres.user ci.Postgres.database
  in
  send (be32 (4 + 4 + String.length params) ^ be32 196608 ^ params);
  (* Authentication + startup phase, until ReadyForQuery. *)
  let rec until_ready () =
    let m = read_msg reader in
    match m.typ with
    | 'R' ->
        let code = read_be32 m.body 0 in
        if code <> 0 then
          failwith
            (Printf.sprintf "pg-listen: server requested auth method %d; only trust is supported"
               code)
        else until_ready ()
    | 'Z' -> ()
    | 'E' -> failwith ("pg-listen: " ^ error_message m.body)
    | _ -> until_ready () (* S ParameterStatus, K BackendKeyData, N Notice *)
  in
  until_ready ();
  let listens =
    channels |> List.map (fun c -> Printf.sprintf "listen %s;" c) |> String.concat " "
  in
  send ("Q" ^ be32 (4 + String.length listens + 1) ^ listens ^ "\000");
  until_ready ();
  log "listening on: %s" (String.concat ", " channels);
  (* Notification loop: the read suspends the fiber until the server pushes. *)
  let rec loop () =
    let m = read_msg reader in
    (match m.typ with
    | 'A' ->
        let channel, off = read_cstring m.body 4 in
        let payload, _ = read_cstring m.body off in
        on_notify ~channel ~payload
    | 'E' -> failwith ("pg-listen: " ^ error_message m.body)
    | _ -> ());
    loop ()
  in
  loop ()

(* Run forever; reconnect with backoff on any failure. *)
let run ~net ~clock (ci : Postgres.conninfo) ~channels ~on_notify : unit =
  let rec go delay =
    (* One switch per attempt: the socket dies with the attempt, so a failed connect while the DB
       is down cannot leak an fd every backoff round. *)
    match Switch.run (fun sw -> connect_and_listen ~net ~sw ci ~channels ~on_notify) with
    | () -> ()
    | exception (Eio.Cancel.Cancelled _ as e) -> raise e
    | exception exn ->
        log "connection lost (%s); reconnecting in %.0fs" (Printexc.to_string exn) delay;
        Eio.Time.sleep clock delay;
        go (Float.min 30.0 (delay *. 2.0))
  in
  go 1.0
