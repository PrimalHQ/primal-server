(* NIP-90 content discovery client (App.dvm_feed's live path, dvm_feed_checker.jl): publish a
   signed kind-5300 job request on every relay and take the first kind-6300 result (or a 7000
   error) that references it, within [timeout] seconds. Shared by the API's dvm_feed and the jobs
   daemon's DVM feed checker. *)

open Eio.Std

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [dvm] %s\n%!" (Procinfo.timestamp ()) s) fmt

(* the job request event: p = DVM, alt, relays, and for personalized feeds max_results + user *)
let job_request ~(seckey : string) ~(dvm_pubkey : string) ~(relays : string list) ~(user : string option) ~(now : int) : Nostr.t =
  let tags =
    [ [ `String "p"; `String (Hex_util.encode dvm_pubkey) ]; [ `String "alt"; `String "NIP90 Content Discovery Request" ]; `String "relays" :: List.map (fun r -> `String r) relays ]
    @ match user with Some u -> [ [ `String "param"; `String "max_results"; `String "100" ]; [ `String "param"; `String "user"; `String (Hex_util.encode u) ] ] | None -> []
  in
  Nostr.create ~seckey ~created_at:now ~kind:5300 ~tags ~content:""

(* Ok: the result's referenced event ids (hex); Error: a 7000 error status or "timeout" *)
let request ~net ~clock ?proxy ~(relays : string list) ~(jobreq : Nostr.t) ~(timeout : float) () : (string list, string) result =
  let result, resolve = Promise.create () in
  let resolve_once v = if not (Promise.is_resolved result) then Promise.resolve resolve v in
  let sub = Printf.sprintf {|["REQ","dvm",{"limit":10,"kinds":[6300,7000],"#e":["%s"]}]|} (Nostr.id_hex jobreq) in
  let ev = Printf.sprintf "[\"EVENT\",%s]" (Nostr.to_string jobreq) in
  let deadline = Unix.gettimeofday () +. timeout in
  Switch.run (fun sw ->
      List.iter
        (fun url ->
          Fiber.fork_daemon ~sw (fun () ->
              (try
                 match Relay_broadcast.parse_relay_url url with
                 | None -> ()
                 | Some (tls, host, port, path) ->
                     Switch.run (fun csw ->
                         let ws = Ws_client.connect ~tls ?proxy ~sw:csw ~net ~clock ~host ~port ~path () in
                         Ws_client.send_text ws sub;
                         Ws_client.send_text ws ev;
                         let rec loop () =
                           let remaining = deadline -. Unix.gettimeofday () in
                           if remaining > 0. && not (Promise.is_resolved result) then
                             match Ws_client.recv_timeout ws ~timeout:remaining with
                             | `Msg m ->
                                 (match Yojson.Safe.from_string m with
                                 | `List (`String "EVENT" :: _ :: evj :: _) -> (
                                     match Nostr.of_json evj with
                                     | e when Nostr.verify e ->
                                         if e.Nostr.kind = 6300 then begin
                                           match Yojson.Safe.from_string e.Nostr.content with
                                           | `List l -> resolve_once (Ok (List.filter_map (function `List (`String "e" :: `String h :: _) -> Some h | _ -> None) l))
                                           | _ -> ()
                                           | exception _ -> ()
                                         end
                                         else if e.Nostr.kind = 7000 then
                                           List.iter
                                             (function `String "status" :: `String "error" :: rest -> resolve_once (Error (match rest with `String m :: _ -> m | _ -> "")) | _ -> ())
                                             e.Nostr.tags
                                     | _ -> ()
                                     | exception _ -> ())
                                 | _ -> ()
                                 | exception _ -> ());
                                 loop ()
                             | `Closed | `Timeout -> ()
                         in
                         loop ();
                         Ws_client.close ws)
               with
              | Eio.Cancel.Cancelled _ as ex -> raise ex
              | exn -> log "relay %s: %s" url (Printexc.to_string exn));
              `Stop_daemon))
        relays;
      Fiber.first (fun () -> ignore (Promise.await result)) (fun () -> Eio.Time.sleep clock timeout));
  if Promise.is_resolved result then Promise.await result else Error "timeout"
