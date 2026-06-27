(* Minimal SOCKS5 client (no-auth CONNECT), used to reach LNURL endpoints through
   PRIMALSERVER_PROXY. We use ATYP=domain (the "socks5h" behaviour: the proxy resolves the
   destination host), matching the Julia HTTP.jl proxy usage. Raises on protocol failure. *)

open Eio.Std

let connect (flow : _ Eio.Flow.two_way) ~(dest_host : string) ~(dest_port : int) : unit =
  let w s = Eio.Flow.copy_string s (flow :> _ Eio.Flow.sink) in
  let r = Eio.Buf_read.of_flow (flow :> _ Eio.Flow.source) ~max_size:512 in
  let rd n = Eio.Buf_read.take n r in
  if String.length dest_host > 255 then failwith "socks5: host too long";
  (* greeting: VER=5, NMETHODS=1, METHODS=[0 no-auth] *)
  w "\x05\x01\x00";
  let g = rd 2 in
  if g.[0] <> '\x05' || g.[1] <> '\x00' then failwith "socks5: no acceptable auth method";
  (* request: VER=5, CMD=1(connect), RSV=0, ATYP=3(domain), len, host, port(BE) *)
  let b = Buffer.create 32 in
  Buffer.add_string b "\x05\x01\x00\x03";
  Buffer.add_char b (Char.chr (String.length dest_host));
  Buffer.add_string b dest_host;
  Buffer.add_char b (Char.chr ((dest_port lsr 8) land 0xff));
  Buffer.add_char b (Char.chr (dest_port land 0xff));
  w (Buffer.contents b);
  (* reply: VER, REP, RSV, ATYP, BND.ADDR, BND.PORT *)
  let hdr = rd 4 in
  if hdr.[1] <> '\x00' then
    failwith (Printf.sprintf "socks5: CONNECT failed (rep=%d)" (Char.code hdr.[1]));
  let addr_len =
    match Char.code hdr.[3] with
    | 1 -> 4 (* IPv4 *)
    | 4 -> 16 (* IPv6 *)
    | 3 -> Char.code (rd 1).[0] (* domain: 1 length byte then that many *)
    | a -> failwith (Printf.sprintf "socks5: bad ATYP %d" a)
  in
  ignore (rd (addr_len + 2)) (* skip BND.ADDR + BND.PORT; nothing else arrives until we speak *)
