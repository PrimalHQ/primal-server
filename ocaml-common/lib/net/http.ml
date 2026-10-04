(* Minimal HTTPS GET client over Eio + tls-eio, optionally tunnelled through a SOCKS5 proxy.
   Just enough to fetch LNURL pay endpoints (small JSON). cohttp-eio is not in nixpkgs 25.11,
   so this is hand-rolled per the plan. A RNG must be installed in the calling domain
   (Mirage_crypto_rng_unix.use_default ()). *)

open Eio.Std

type url = { scheme : string; host : string; port : int; path : string }

(* Parse http(s)://host[:port][/path]. Returns None if it is not a well-formed http(s) URL. *)
let parse_url (u : string) : url option =
  let split_first sep s =
    match String.index_opt s sep with
    | Some i -> Some (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1))
    | None -> None
  in
  match Str_util.split_on_substring u "://" with
  | None -> None
  | Some (sc, rest) ->
      let scheme = String.lowercase_ascii sc in
      if scheme <> "http" && scheme <> "https" then None
      else
        let authority, path =
          match String.index_opt rest '/' with
          | Some i -> (String.sub rest 0 i, String.sub rest i (String.length rest - i))
          | None -> (rest, "/")
        in
        let host, port =
          match split_first ':' authority with
          | Some (h, p) -> (h, try int_of_string p with _ -> if scheme = "https" then 443 else 80)
          | None -> (authority, if scheme = "https" then 443 else 80)
        in
        if host = "" then None else Some { scheme; host; port; path }

(* Resolve via pure-Eio DNS (Dns_eio), NOT getaddrinfo: libc getaddrinfo runs in a systhread
   Eio cannot cancel, so a wedged nscd/resolver would escape the request timeout and hang the
   fiber (the 2026-07-11 incident). IP literals skip DNS entirely. *)
let resolve ~net ~clock ~sw ~host ~port : Eio.Net.Sockaddr.stream =
  match Ipaddr.of_string host with
  | Ok ip -> `Tcp (Eio.Net.Ipaddr.of_raw (Ipaddr.to_octets ip), port)
  | Error _ -> (
      match Dns_eio.resolve_v4 ~net ~clock ~sw host with
      | Ok ip -> `Tcp (Eio.Net.Ipaddr.of_raw (Ipaddr.V4.to_octets ip), port)
      | Error (`Msg m) -> failwith (Printf.sprintf "http: cannot resolve %s:%d: %s" host port m))

(* De-chunk an HTTP/1.1 chunked body. *)
let dechunk (s : string) : string =
  let buf = Buffer.create (String.length s) in
  let n = String.length s in
  let i = ref 0 in
  (try
     while !i < n do
       let j = ref !i in
       while !j < n && s.[!j] <> '\r' do incr j done;
       let line = String.sub s !i (!j - !i) in
       let hex = match String.index_opt line ';' with Some k -> String.sub line 0 k | None -> line in
       let size = int_of_string ("0x" ^ String.trim hex) in
       i := !j + 2 (* skip CRLF *);
       if size = 0 then raise Exit;
       if !i + size > n then raise Exit;
       Buffer.add_substring buf s !i size;
       i := !i + size + 2 (* skip chunk data + trailing CRLF *)
     done
   with _ -> ());
  Buffer.contents buf

(* Split headers/body and de-chunk if needed; returns the response body. *)
let extract_body (raw : string) : string =
  match Str_util.split_on_substring raw "\r\n\r\n" with
  | None -> raw
  | Some (headers, body) ->
      let lower = String.lowercase_ascii headers in
      let chunked =
        match Str_util.find_substring lower "transfer-encoding:" with
        | None -> false
        | Some i ->
            let eol = match String.index_from_opt lower i '\r' with Some e -> e | None -> String.length lower in
            Str_util.find_substring (String.sub lower i (eol - i)) "chunked" <> None
      in
      if chunked then dechunk body else body

type conn = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] r

(* Phases are recorded via Phases so a wedged request shows WHERE it is stuck (dns / connect /
   socks / tls / read) in the per-second stuck-slot report and the watchdog dump. *)
let two_way_of_proxy ~sw ~net ~clock ~proxy ~host ~port : conn =
  match proxy with
  | Some (ph, pp) ->
      Phases.phase "https:dns";
      let addr = resolve ~net ~clock ~sw ~host:ph ~port:pp in
      Phases.phase "https:connect";
      let f = Eio.Net.connect ~sw net addr in
      Phases.phase "https:socks";
      Socks5.connect (f :> _ Eio.Flow.two_way) ~dest_host:host ~dest_port:port;
      (f :> conn)
  | None ->
      Phases.phase "https:dns";
      let addr = resolve ~net ~clock ~sw ~host ~port in
      Phases.phase "https:connect";
      (Eio.Net.connect ~sw net addr :> conn)

(* Wrap a connected TCP flow in a TLS client session for [host] (SNI + system CA bundle).
   Requires Mirage_crypto_rng_unix.use_default () once per domain before the first call. Shared
   with Ws_client for wss://. *)
let tls_wrap ~(host : string) (tcp : [> Eio.Flow.two_way_ty ] r) : Eio.Flow.two_way_ty r =
  let host_dn = Domain_name.host_exn (Domain_name.of_string_exn host) in
  let authenticator =
    match Ca_certs.authenticator () with Ok a -> a | Error (`Msg m) -> failwith m
  in
  let cfg =
    match Tls.Config.client ~authenticator ~peer_name:host_dn () with
    | Ok c -> c
    | Error (`Msg m) -> failwith m
  in
  (Tls_eio.client_of_flow cfg ~host:host_dn tcp :> Eio.Flow.two_way_ty r)

(* GET an https URL, returning the response body (best-effort), or None on any failure /
   timeout. [proxy] is an optional SOCKS5 (host, port).

   The timeout covers the WHOLE request — DNS, TCP/SOCKS5 connect, TLS handshake, request write
   and response read — not just the body read. A wedged LNURL endpoint once hung every worker
   forever in the TLS handshake because only the read was bounded. One caveat remains:
   getaddrinfo runs in a systhread that Eio cannot interrupt mid-call, so a truly hung resolver
   still blocks past the deadline (a stall watchdog is the backstop). *)
let https_get ~net ~clock ?proxy ?(timeout = 10.0) (u : url) : string option =
  if u.scheme <> "https" then None
  else
    try
      Switch.run @@ fun sw ->
      let result =
        Eio.Time.with_timeout clock timeout (fun () ->
            let tcp = two_way_of_proxy ~sw ~net ~clock ~proxy ~host:u.host ~port:u.port in
            Phases.phase "https:tls";
            let tls = tls_wrap ~host:u.host tcp in
            let req =
              Printf.sprintf
                "GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: primal-importer\r\nAccept: application/json\r\nConnection: close\r\n\r\n"
                u.path u.host
            in
            Eio.Flow.copy_string req (tls :> _ Eio.Flow.sink);
            Phases.phase "https:read";
            let r = Eio.Buf_read.of_flow (tls :> _ Eio.Flow.source) ~max_size:(8 * 1024 * 1024) in
            Ok (Eio.Buf_read.take_all r))
      in
      Phases.phase "idle";
      (match result with Ok raw -> Some (extract_body raw) | Error `Timeout -> None)
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | _ -> None


(* {1 Plain HTTP/1.1 (no TLS) request} — admin endpoints on 127.0.0.1, pushgateway-style internal
   services. Returns (status, body). Bounded by [timeout] end to end; raises on failure. *)
let plain_request ~net ~clock ?(timeout = 10.0) ?(meth = "GET") ?(body = "") ~host ~port ~path () :
    int * string =
  Switch.run @@ fun sw ->
  match
    Eio.Time.with_timeout clock timeout (fun () ->
        let addr = resolve ~net ~clock ~sw ~host ~port in
        let flow = Eio.Net.connect ~sw net addr in
        let req =
          Printf.sprintf
            "%s %s HTTP/1.1\r\nHost: %s:%d\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" meth
            path host port (String.length body) body
        in
        Eio.Flow.copy_string req (flow :> _ Eio.Flow.sink);
        let r = Eio.Buf_read.of_flow (flow :> _ Eio.Flow.source) ~max_size:(64 * 1024 * 1024) in
        let raw = Eio.Buf_read.take_all r in
        let status =
          match String.index_opt raw ' ' with
          | Some i when String.length raw >= i + 4 -> (
              match int_of_string_opt (String.sub raw (i + 1) 3) with Some c -> c | None -> 0)
          | _ -> 0
        in
        Ok (status, extract_body raw))
  with
  | Ok r -> r
  | Error `Timeout -> failwith (Printf.sprintf "http: %s %s:%d%s timed out" meth host port path)
