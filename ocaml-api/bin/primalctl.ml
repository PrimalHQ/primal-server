(* primalctl: operator CLI for the OCaml daemons (ocaml-plan.md §7.3). Phase 2 subcommands:

     primalctl req <ws-url> <funcall> [kwargs-json] [--zlib]   one cache-API request, frames printed
     primalctl status [admin-url]                               GET /status of a primal-api
     primalctl drain  [admin-url]                               POST /drain
     primalctl metrics [admin-url]                              GET /metrics

   Default admin url: http://127.0.0.1:14001. *)

open Eio.Std

let default_admin = "http://127.0.0.1:14001"

let usage () =
  prerr_endline
    "usage: primalctl req <ws-url> <funcall> [kwargs-json] [--zlib]\n\
    \       primalctl status|drain|metrics [admin-url]";
  exit 2

let parse_http_url (u : string) : string * int * string =
  match Http.parse_url u with
  | Some { Http.host; port; path; _ } -> (host, port, path)
  | None -> failwith ("not an http url: " ^ u)

let admin ~net ~clock ~meth ~path (url : string) : unit =
  let host, port, _ = parse_http_url url in
  let status, body = Http.plain_request ~net ~clock ~meth ~host ~port ~path () in
  Printf.printf "%d\n%s\n%!" status body;
  if status >= 400 then exit 1

(* Send one REQ and print every frame until EOSE (binary frames are zlib-inflated). *)
let req ~net ~clock ~url ~funcall ~kwargs ~zlib : unit =
  match Relay_broadcast.parse_relay_url url with
  | None -> failwith ("not a ws url: " ^ url)
  | Some (tls, host, port, path) ->
      Switch.run @@ fun sw ->
      let ws = Ws_client.connect ~tls ~sw ~net ~clock ~host ~port ~path () in
      let send_req subid filter =
        Ws_client.send_text ws
          (Yojson.Safe.to_string (`List [ `String "REQ"; `String subid; filter ]))
      in
      let wait_eose subid =
        let rec loop () =
          match Ws_client.recv_frame ws with
          | `Closed -> prerr_endline "connection closed"; exit 1
          | `Text t ->
              print_endline t;
              if t = Primal_api.Protocol.eose subid then () else loop ()
          | `Binary b ->
              (try print_endline (Zlib_util.uncompress b) with _ -> Printf.printf "<binary %d bytes>\n" (String.length b));
              loop ()
        in
        loop ()
      in
      if zlib then begin
        send_req "proto" (`Assoc [ ("cache", `List [ `String "set_primal_protocol"; `Assoc [ ("compression", `String "zlib") ] ]) ]);
        wait_eose "proto"
      end;
      let t0 = Unix.gettimeofday () in
      send_req "primalctl" (`Assoc [ ("cache", `List [ `String funcall; kwargs ]) ]);
      wait_eose "primalctl";
      Printf.eprintf "(%.0f ms)\n%!" ((Unix.gettimeofday () -. t0) *. 1000.);
      Ws_client.close ws

let () =
  let args = Array.to_list Sys.argv |> List.tl in
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  match args with
  | "req" :: url :: funcall :: rest ->
      let zlib = List.mem "--zlib" rest in
      let rest = List.filter (fun a -> a <> "--zlib") rest in
      let kwargs = match rest with k :: _ -> Yojson.Safe.from_string k | [] -> `Assoc [] in
      req ~net ~clock ~url ~funcall ~kwargs ~zlib
  | [ "status" ] -> admin ~net ~clock ~meth:"GET" ~path:"/status" default_admin
  | [ "status"; u ] -> admin ~net ~clock ~meth:"GET" ~path:"/status" u
  | [ "metrics" ] -> admin ~net ~clock ~meth:"GET" ~path:"/metrics" default_admin
  | [ "metrics"; u ] -> admin ~net ~clock ~meth:"GET" ~path:"/metrics" u
  | [ "drain" ] -> admin ~net ~clock ~meth:"POST" ~path:"/drain" default_admin
  | [ "drain"; u ] -> admin ~net ~clock ~meth:"POST" ~path:"/drain" u
  | _ -> usage ()
