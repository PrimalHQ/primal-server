(* Dev tool: time each phase of the importer's LNURL fetch path (Dns_eio resolve, TCP connect,
   TLS handshake, request write, response read) so a slow/failing fetch can be attributed to a
   phase. Usage: lnurlprobe.exe [rounds] [url ...] *)
open Eio.Std

let phase name t f =
  let t0 = Unix.gettimeofday () in
  let r = f () in
  Printf.printf "  %-8s %.2fs\n%!" name (Unix.gettimeofday () -. t0);
  ignore t;
  r

let probe ~net ~clock (u : Importer.Http.url) =
  let t0 = Unix.gettimeofday () in
  let res =
    try
      Switch.run @@ fun sw ->
      (match Eio.Time.with_timeout clock 20.0 (fun () ->
          let addr = phase "dns" () (fun () ->
              Importer.Http.resolve ~net ~clock ~sw ~host:u.Importer.Http.host
                ~port:u.Importer.Http.port)
          in
          (match addr with
           | `Tcp (ip, p) -> Printf.printf "  addr     %s:%d\n%!" (Format.asprintf "%a" Eio.Net.Ipaddr.pp ip) p
           | _ -> ());
          let tcp = phase "connect" () (fun () -> Eio.Net.connect ~sw net addr) in
          let host_dn = Domain_name.(host_exn (of_string_exn u.Importer.Http.host)) in
          let auth = match Ca_certs.authenticator () with Ok a -> a | Error (`Msg m) -> failwith m in
          let cfg =
            match Tls.Config.client ~authenticator:auth ~peer_name:host_dn () with
            | Ok c -> c | Error (`Msg m) -> failwith m
          in
          let tls = phase "tls" () (fun () ->
              Tls_eio.client_of_flow cfg ~host:host_dn
                (tcp :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] r))
          in
          let req =
            Printf.sprintf
              "GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: primal-importer\r\nAccept: application/json\r\nConnection: close\r\n\r\n"
              u.Importer.Http.path u.Importer.Http.host
          in
          phase "write" () (fun () -> Eio.Flow.copy_string req (tls :> _ Eio.Flow.sink));
          let raw = phase "read" () (fun () ->
              let r = Eio.Buf_read.of_flow (tls :> _ Eio.Flow.source) ~max_size:(8 * 1024 * 1024) in
              Eio.Buf_read.take_all r)
          in
          Ok (String.length raw))
       with
       | Ok n -> Ok n
       | Error `Timeout -> Error `Timeout)
    with e -> Error (`Exn (Printexc.to_string e))
  in
  Printf.printf "  => %s (total %.2fs)\n\n%!"
    (match res with
     | Ok n -> Printf.sprintf "%d bytes" n
     | Error `Timeout -> "TIMEOUT"
     | Error (`Exn m) -> "EXN " ^ m)
    (Unix.gettimeofday () -. t0)

let () =
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  let rounds = if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 3 in
  let urls =
    if Array.length Sys.argv > 2 then Array.to_list (Array.sub Sys.argv 2 (Array.length Sys.argv - 2))
    else [ "https://walletofsatoshi.com/.well-known/lnurlp/btc_alm" ]
  in
  List.iter
    (fun us ->
      match Importer.Http.parse_url us with
      | None -> Printf.printf "bad url %s\n%!" us
      | Some u ->
          for i = 1 to rounds do
            Printf.printf "%s #%d\n%!" u.Importer.Http.host i;
            probe ~net ~clock u
          done)
    urls
