(* Minimal RFC 6455 WebSocket CLIENT over Eio (from the tsunami kernel's api/core/ws_client.ml,
   re-pointed at this library's Http for DNS/TLS). ws:// and wss:// (~tls:true), optional SOCKS5
   proxy. Pings are answered; [recv_frame] returns text and binary messages, [recv] text only.
   Client frames use a zero masking key (spec-shaped, identity transform).

   recv_timeout is desync-safe: the timeout only guards the wait for the FIRST header byte
   (Buf_read.ensure consumes nothing), so a timed-out call leaves the frame stream intact for
   subsequent reads. *)

type t = {
  flow : Eio.Flow.two_way_ty Eio.Std.r;
  mutable reader : Eio.Buf_read.t; (* replaced by a fresh small one after a large frame, see [shrink] *)
  mutable cap : int; (* the reader's buffer capacity as last accounted in [total_capacity] *)
  clock : float Eio.Time.clock_ty Eio.Std.r;
  mutable closed : bool;
  resp_headers : (string * string) list; (* the 101 response's headers, lowercased names *)
}

(* {1 Read-buffer accounting}
   A Buf_read's buffer is a Bigarray outside the OCaml heap; it doubles whenever a frame does not
   fit and never shrinks by itself, so with tens of thousands of relay connections these buffers
   are the bulk of the process RSS. The capacity is read from the Buf_read record's first field
   (eio 1.3: [{ mutable buf : Cstruct.buffer; ... }]); the live totals are atomics for the
   daemons' status pages. *)
let reader_capacity (r : Eio.Buf_read.t) : int =
  let buf : Cstruct.buffer = Obj.obj (Obj.field (Obj.repr r) 0) in
  Bigarray.Array1.dim buf

let total_capacity = Atomic.make 0
let live_clients = Atomic.make 0
let total_reader_capacity () = Atomic.get total_capacity
let client_count () = Atomic.get live_clients

let base64_encode (s : string) : string =
  let tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" in
  let n = String.length s in
  let b = Buffer.create ((n + 2) / 3 * 4) in
  let i = ref 0 in
  while !i + 2 < n do
    let x = (Char.code s.[!i] lsl 16) lor (Char.code s.[!i + 1] lsl 8) lor Char.code s.[!i + 2] in
    Buffer.add_char b tbl.[(x lsr 18) land 63];
    Buffer.add_char b tbl.[(x lsr 12) land 63];
    Buffer.add_char b tbl.[(x lsr 6) land 63];
    Buffer.add_char b tbl.[x land 63];
    i := !i + 3
  done;
  (match n - !i with
  | 1 ->
      let x = Char.code s.[!i] lsl 16 in
      Buffer.add_char b tbl.[(x lsr 18) land 63];
      Buffer.add_char b tbl.[(x lsr 12) land 63];
      Buffer.add_string b "=="
  | 2 ->
      let x = (Char.code s.[!i] lsl 16) lor (Char.code s.[!i + 1] lsl 8) in
      Buffer.add_char b tbl.[(x lsr 18) land 63];
      Buffer.add_char b tbl.[(x lsr 12) land 63];
      Buffer.add_char b tbl.[(x lsr 6) land 63];
      Buffer.add_char b '='
  | _ -> ());
  Buffer.contents b

exception Handshake_failed of string

(* ?headers appends extra handshake headers (e.g. Sec-WebSocket-Protocol). ?proxy is a SOCKS5
   (host, port). The TCP/SOCKS/TLS setup is unbounded here; callers wrap [connect] in
   Eio.Time.with_timeout. *)
let connect ?(headers : (string * string) list = []) ?(tls = false) ?proxy ~sw
    ~(net : _ Eio.Net.t) ~(clock : float Eio.Time.clock_ty Eio.Std.r) ~(host : string)
    ~(port : int) ~(path : string) () : t =
  let tcp = Http.two_way_of_proxy ~sw ~net ~clock ~proxy ~host ~port in
  let flow =
    if tls then Http.tls_wrap ~host tcp (* TLS needs the closeable TCP flow *)
    else (tcp :> Eio.Flow.two_way_ty Eio.Std.r)
  in
  let extra =
    String.concat "" (List.map (fun (k, v) -> Printf.sprintf "%s: %s\r\n" k v) headers)
  in
  let request =
    Printf.sprintf
      "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n%s\r\n"
      path
      (if (tls && port = 443) || ((not tls) && port = 80) then host
       else Printf.sprintf "%s:%d" host port)
      (base64_encode "primal-ws-key-01") extra
  in
  Eio.Flow.copy_string request flow;
  let reader =
    Eio.Buf_read.of_flow ~max_size:(64 * 1024 * 1024) (flow :> Eio.Flow.source_ty Eio.Std.r)
  in
  let status_line = Eio.Buf_read.line reader in
  if not (String.length status_line >= 12 && String.sub status_line 9 3 = "101") then
    raise (Handshake_failed ("websocket handshake rejected: " ^ status_line));
  let rec headers acc =
    let line = Eio.Buf_read.line reader in
    if String.trim line = "" then List.rev acc
    else
      match String.index_opt line ':' with
      | Some i ->
          headers
            (( String.lowercase_ascii (String.trim (String.sub line 0 i)),
               String.trim (String.sub line (i + 1) (String.length line - i - 1)) )
            :: acc)
      | None -> headers acc
  in
  let resp_headers = headers [] in
  Phases.phase "idle";
  let cap = reader_capacity reader in
  ignore (Atomic.fetch_and_add total_capacity cap);
  ignore (Atomic.fetch_and_add live_clients 1);
  { flow; reader; cap; clock; closed = false; resp_headers }

(* ------------------------------------------------------------------ frames *)

let send_frame (t : t) ~(opcode : int) (payload : string) : unit =
  if not t.closed then begin
    let n = String.length payload in
    let header = Buffer.create 16 in
    Buffer.add_char header (Char.chr (0x80 lor opcode));
    let mask_bit = 0x80 in
    if n < 126 then Buffer.add_char header (Char.chr (mask_bit lor n))
    else if n < 65536 then begin
      Buffer.add_char header (Char.chr (mask_bit lor 126));
      Buffer.add_char header (Char.chr (n lsr 8));
      Buffer.add_char header (Char.chr (n land 0xff))
    end
    else begin
      Buffer.add_char header (Char.chr (mask_bit lor 127));
      for i = 7 downto 0 do
        Buffer.add_char header (Char.chr ((n lsr (i * 8)) land 0xff))
      done
    end;
    (* zero masking key: masked payload = payload *)
    Buffer.add_string header "\000\000\000\000";
    Eio.Flow.copy_string (Buffer.contents header ^ payload) t.flow
  end

let send_text (t : t) (payload : string) : unit = send_frame t ~opcode:0x1 payload
let send_binary (t : t) (payload : string) : unit = send_frame t ~opcode:0x2 payload
let read_exact (t : t) (n : int) : string = Eio.Buf_read.take n t.reader

let read_frame (t : t) : int * bool * string =
  let b0 = Char.code (Eio.Buf_read.any_char t.reader) in
  let fin = b0 land 0x80 <> 0 in
  let opcode = b0 land 0x0f in
  let b1 = Char.code (Eio.Buf_read.any_char t.reader) in
  let masked = b1 land 0x80 <> 0 in
  let len0 = b1 land 0x7f in
  let len =
    if len0 < 126 then len0
    else if len0 = 126 then
      let raw = read_exact t 2 in
      (Char.code raw.[0] lsl 8) lor Char.code raw.[1]
    else begin
      let raw = read_exact t 8 in
      let v = ref 0 in
      String.iter (fun c -> v := (!v lsl 8) lor Char.code c) raw;
      !v
    end
  in
  let mask = if masked then read_exact t 4 else "" in
  let payload = read_exact t len in
  let payload =
    if masked then
      String.init len (fun i -> Char.chr (Char.code payload.[i] lxor Char.code mask.[i mod 4]))
    else payload
  in
  (opcode, fin, payload)

(* A Buf_read grows to the largest frame ever seen and never shrinks; with thousands of long-lived
   relay connections (the fetcher) that is most of the process. When nothing is buffered after a
   frame over 64 KB, the reader is replaced by a fresh 4 KB one over the same flow. *)
let shrink_threshold = 64 * 1024

(* keep [cap] and the total in step with the reader's buffer, which Buf_read grows on its own *)
let account (t : t) : unit =
  let c = reader_capacity t.reader in
  if c <> t.cap then begin
    ignore (Atomic.fetch_and_add total_capacity (c - t.cap));
    t.cap <- c
  end

let shrink (t : t) (last_len : int) : unit =
  if last_len > shrink_threshold && Eio.Buf_read.buffered_bytes t.reader = 0 then
    t.reader <- Eio.Buf_read.of_flow ~max_size:(64 * 1024 * 1024) (t.flow :> Eio.Flow.source_ty Eio.Std.r);
  account t

(* Receive the next complete message (text or binary; continuation frames assembled, pings
   answered). `Closed on close frame / EOF. *)
let rec recv_frame (t : t) : [ `Text of string | `Binary of string | `Closed ] =
  if t.closed then `Closed
  else
    let assemble first_opcode first_payload fin =
      if fin then first_payload
      else begin
        let buf = Buffer.create (String.length first_payload * 2) in
        Buffer.add_string buf first_payload;
        let rec more () =
          match read_frame t with
          | 0x0, true, chunk ->
              Buffer.add_string buf chunk;
              Buffer.contents buf
          | 0x0, false, chunk ->
              Buffer.add_string buf chunk;
              more ()
          | 0x9, _, ping ->
              send_frame t ~opcode:0xa ping;
              more ()
          | _ -> more ()
        in
        ignore first_opcode;
        more ()
      end
    in
    match read_frame t with
    | exception End_of_file ->
        t.closed <- true;
        `Closed
    | 0x8, _, _ ->
        (try send_frame t ~opcode:0x8 "" with _ -> ());
        t.closed <- true;
        `Closed
    | 0x9, _, payload ->
        send_frame t ~opcode:0xa payload;
        recv_frame t
    | 0x1, fin, payload -> let m = assemble 0x1 payload fin in shrink t (String.length m); `Text m
    | 0x2, fin, payload -> let m = assemble 0x2 payload fin in shrink t (String.length m); `Binary m
    | _ -> recv_frame t (* pong / unknown: ignore *)

(* Receive the next complete TEXT message, skipping binary ones. *)
let rec recv (t : t) : [ `Msg of string | `Closed ] =
  match recv_frame t with `Text m -> `Msg m | `Binary _ -> recv t | `Closed -> `Closed

let recv_timeout (t : t) ~(timeout : float) : [ `Msg of string | `Closed | `Timeout ] =
  if t.closed then `Closed
  else
    (* only the wait for the first buffered byte is cancellable *)
    match
      Eio.Time.with_timeout t.clock (Float.max 0.01 timeout) (fun () ->
          Eio.Buf_read.ensure t.reader 1;
          Ok ())
    with
    | Error `Timeout -> `Timeout
    | Ok () -> (recv t :> [ `Msg of string | `Closed | `Timeout ])
    | exception End_of_file ->
        t.closed <- true;
        `Closed

let close (t : t) : unit =
  if not t.closed then begin
    (try send_frame t ~opcode:0x8 "" with _ -> ());
    t.closed <- true;
    ignore (Atomic.fetch_and_add total_capacity (-t.cap));
    ignore (Atomic.fetch_and_add live_clients (-1));
    t.cap <- 0
  end
