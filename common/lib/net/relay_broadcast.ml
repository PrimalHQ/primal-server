(* Broadcast signed events to Nostr relays, mirroring Julia App.broadcast_event_to_relays_async
   (app_ext.jl:2333): one WebSocket per relay, send ["EVENT", e], read the first reply (the
   relay's ["OK", id, accepted, message]), close. Every relay is attempted concurrently and each
   attempt is bounded end-to-end (connect + TLS + send + read) by [timeout]; failures are reported
   per relay, never raised. Used by the importer's import listener (reply broadcasting), event
   rebroadcasting and Studio broadcasting. *)

open Eio.Std

type response = {
  url : string;
  reply : string option; (* the relay's first text frame, if any *)
  error : string option; (* connect/handshake/timeout failure *)
}

(* ws://host[:port][/path] or wss://… -> (tls, host, port, path). *)
let parse_relay_url (u : string) : (bool * string * int * string) option =
  let u = String.trim u in
  let lower = String.lowercase_ascii u in
  let prefixed p = String.length lower >= String.length p && String.sub lower 0 (String.length p) = p in
  let tls, rest =
    if prefixed "wss://" then (true, String.sub u 6 (String.length u - 6))
    else if prefixed "ws://" then (false, String.sub u 5 (String.length u - 5))
    else (true, "")
  in
  if rest = "" then None
  else
    let authority, path =
      match String.index_opt rest '/' with
      | Some i -> (String.sub rest 0 i, String.sub rest i (String.length rest - i))
      | None -> (rest, "/")
    in
    let default_port = if tls then 443 else 80 in
    let host, port =
      match String.rindex_opt authority ':' with
      | Some i when not (String.contains authority '[') -> (
          let h = String.sub authority 0 i in
          match int_of_string_opt (String.sub authority (i + 1) (String.length authority - i - 1)) with
          | Some p -> (h, p)
          | None -> (authority, default_port))
      | _ -> (authority, default_port)
    in
    if host = "" then None else Some (tls, host, port, path)

let send_one ~net ~clock ?proxy ~timeout ~url (payload : string) : response =
  match parse_relay_url url with
  | None -> { url; reply = None; error = Some "invalid relay url" }
  | Some (tls, host, port, path) -> (
      try
        Switch.run @@ fun sw ->
        match
          Eio.Time.with_timeout clock timeout (fun () ->
              let ws = Ws_client.connect ~tls ?proxy ~sw ~net ~clock ~host ~port ~path () in
              Ws_client.send_text ws payload;
              let r = match Ws_client.recv ws with `Msg m -> Some m | `Closed -> None in
              Ws_client.close ws;
              Ok r)
        with
        | Ok reply -> { url; reply; error = None }
        | Error `Timeout -> { url; reply = None; error = Some "timeout" }
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> { url; reply = None; error = Some (Printexc.to_string exn) })

(* [event_json] is the serialized event (Nostr.to_string). *)
let broadcast ~net ~clock ?proxy ?(timeout = 15.0) ?(max_fibers = 16) ~(relays : string list)
    (event_json : string) : response list =
  let payload = Printf.sprintf "[\"EVENT\",%s]" event_json in
  Fiber.List.map ~max_fibers (fun url -> send_one ~net ~clock ?proxy ~timeout ~url payload) relays

(* A relay accepted the event: ["OK", <id>, true, ...]. *)
let accepted (r : response) : bool =
  match r.reply with
  | Some m -> (
      try
        match Yojson.Safe.from_string m with
        | `List (`String "OK" :: _ :: `Bool true :: _) -> true
        | _ -> false
      with _ -> false)
  | None -> false

let accepted_count (rs : response list) : int = List.length (List.filter accepted rs)

(* JSON summary in the shape of Julia's EVENT_BROADCAST_RESPONSES entries: [(url, reply)...]. *)
let to_json (rs : response list) : Yojson.Safe.t =
  `List
    (List.map
       (fun r ->
         `Assoc
           [
             ("url", `String r.url);
             ("reply", match r.reply with Some m -> `String m | None -> `Null);
             ("error", match r.error with Some e -> `String e | None -> `Null);
           ])
       rs)
