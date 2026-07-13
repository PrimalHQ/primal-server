(* Pure-Eio DNS resolution for LNURL hosts.

   [Eio.Net.getaddrinfo_stream] runs libc getaddrinfo in a systhread that Eio cannot cancel
   mid-call, so the request timeout in Http.https_get could not bound the DNS step — and on this
   box the nscd/nss path has been observed to hang indefinitely (the 2026-07-11 incident left 13
   systhreads in select() for 36 h). This module resolves over ordinary Eio sockets instead:
   fully cancellable by the surrounding [Eio.Time.with_timeout], no systhreads, no nscd/nss.

   Implementation: [Dns_client.Make] (dns-client, which upstream no longer ships an Eio
   transport for) over a ~100-line direct-style Eio transport ('a io = 'a, the same pattern as
   Postgres.Eio_thread), modelled on dns-client-miou-unix. Nameservers come from
   /etc/resolv.conf (dns-client.resolvconf), falling back to Dns_client.default_resolvers.
   Queries go over UDP; a truncated response is retried over TCP (Dns_client returns truncation
   as an error rather than falling back itself). IPv4 only, matching what the previous
   getaddrinfo-based path effectively used. *)

open Eio.Std

type net_t = [ `Generic ] Eio.Net.ty r
type clock_t = float Eio.Time.clock_ty r

module Transport = struct
  type +'a io = 'a
  type io_addr = Ipaddr.t * int
  type stack = { net : net_t; clock : clock_t; sw : Switch.t }

  type t = {
    nameservers : Dns.proto * io_addr list;
    timeout_s : float; (* per connect / send+recv step *)
    stack : stack;
  }

  type conn =
    | Udp of [ `Generic ] Eio.Net.datagram_socket_ty r * Eio.Net.Sockaddr.datagram
    | Tcp of [ `Generic ] Eio.Net.stream_socket_ty r

  type context = { conn : conn; c_clock : clock_t; c_timeout_s : float }

  let create ?nameservers ~timeout stack =
    let nameservers =
      match nameservers with
      | Some ns -> ns
      | None -> (`Udp, List.map (fun ip -> (ip, 53)) Dns_client.default_resolvers)
    in
    { nameservers; timeout_s = Int64.to_float timeout /. 1e9; stack }

  let nameservers t = t.nameservers
  let clock () = Mtime_clock.elapsed_ns ()
  let rng = Mirage_crypto_rng.generate ?g:None
  let bind x f = f x
  let lift = Fun.id

  let eio_ip (ip : Ipaddr.t) : Eio.Net.Ipaddr.v4v6 = Eio.Net.Ipaddr.of_raw (Ipaddr.to_octets ip)

  let with_timeout t (what : string) (f : unit -> ('a, [> `Msg of string ]) result) :
      ('a, [> `Msg of string ]) result =
    match Eio.Time.with_timeout t.stack.clock t.timeout_s f with
    | Ok _ as r -> r
    | Error (`Msg _) as r -> r
    | Error `Timeout -> Error (`Msg ("dns: timeout during " ^ what))

  let connect t =
    match t.nameservers with
    | _, [] -> Error (`Msg "dns: no nameservers")
    | proto, (ip, port) :: _ -> (
        let ctx conn = { conn; c_clock = t.stack.clock; c_timeout_s = t.timeout_s } in
        try
          with_timeout t "connect" (fun () ->
              match proto with
              | `Udp ->
                  let bind_addr =
                    match ip with
                    | Ipaddr.V4 _ -> `Udp (Eio.Net.Ipaddr.V4.any, 0)
                    | Ipaddr.V6 _ -> `Udp (Eio.Net.Ipaddr.V6.any, 0)
                  in
                  let sock = Eio.Net.datagram_socket ~sw:t.stack.sw t.stack.net bind_addr in
                  Ok (`Udp, ctx (Udp ((sock :> _ r), `Udp (eio_ip ip, port))))
              | `Tcp ->
                  let flow = Eio.Net.connect ~sw:t.stack.sw t.stack.net (`Tcp (eio_ip ip, port)) in
                  Ok (`Tcp, ctx (Tcp (flow :> _ r))))
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn -> Error (`Msg ("dns: connect: " ^ Printexc.to_string exn)))

  (* For `Udp [str] is the raw DNS packet; for `Tcp it already carries the 2-byte length prefix
     (both added and consumed by Dns_client itself). *)
  let send_recv ctx (str : string) =
    try
      match
        Eio.Time.with_timeout ctx.c_clock ctx.c_timeout_s (fun () ->
            match ctx.conn with
            | Udp (sock, dst) ->
                Eio.Net.send sock ~dst [ Cstruct.of_string str ];
                let buf = Cstruct.create 4096 in
                let _, len = Eio.Net.recv sock buf in
                Ok (Cstruct.to_string ~len buf)
            | Tcp flow ->
                Eio.Flow.copy_string str (flow :> _ Eio.Flow.sink);
                let r = Eio.Buf_read.of_flow (flow :> _ Eio.Flow.source) ~max_size:65536 in
                let hdr = Eio.Buf_read.take 2 r in
                let len = String.get_uint16_be hdr 0 in
                let body = Eio.Buf_read.take len r in
                Ok (hdr ^ body))
      with
      | Ok _ as r -> r
      | Error `Timeout -> Error (`Msg "dns: timeout during query")
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Error (`Msg ("dns: query: " ^ Printexc.to_string exn))

  let close ctx =
    try
      match ctx.conn with
      | Udp (sock, _) -> Eio.Resource.close sock
      | Tcp flow -> Eio.Flow.close flow
    with _ -> ()
end

include Dns_client.Make (Transport)

(* Nameservers from /etc/resolv.conf (e.g. "nameserver 8.8.8.8"), falling back to the library
   defaults. Parsed per call — the file is tiny and rarely changes. *)
let system_nameservers () : (Ipaddr.t * int) list =
  let parsed =
    try
      match Dns_resolvconf.parse (In_channel.with_open_text "/etc/resolv.conf" In_channel.input_all) with
      | Ok l -> List.map (fun (`Nameserver ip) -> (ip, 53)) l
      | Error _ -> []
    with _ -> []
  in
  match parsed with [] -> List.map (fun ip -> (ip, 53)) Dns_client.default_resolvers | l -> l

let timeout_ns = 5_000_000_000L (* 5s budget per attempt, well under https_get's 10s *)

(* Resolve [host]'s IPv4 address. UDP first, one TCP retry if the response was truncated. *)
let resolve_v4 ~net ~clock ~sw (host : string) : (Ipaddr.V4.t, [> `Msg of string ]) result =
  let stack =
    { Transport.net = (net :> net_t); clock = (clock :> clock_t); sw }
  in
  match Result.bind (Domain_name.of_string host) Domain_name.host with
  | Error _ -> Error (`Msg ("dns: not a hostname: " ^ host))
  | Ok h -> (
      let ns = system_nameservers () in
      let query proto =
        gethostbyname (create ~nameservers:(proto, ns) ~timeout:timeout_ns stack) h
      in
      match query `Udp with
      | Error (`Msg m) when m = "Truncated UDP response" -> query `Tcp
      | r -> r)
