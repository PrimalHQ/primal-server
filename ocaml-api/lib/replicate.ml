(* app.jl replicate_request: a few write funcalls change per-host cache tables (the unread counters
   of notifications and DMs), so the API that took one tells the other cache hosts' APIs too —
   ["REQ","replicated_request",{"cache":[name,{...,"replicated":true}]}] over a short-lived
   WebSocket, fire and forget (Julia: 2 s connect/read timeouts, errors only logged). A request
   that already carries "replicated":true is not passed on, so two hosts can point at each other.
   Handlers only enqueue; one fiber of the main domain sends, so a slow or dead target never delays
   an answer, and a full queue drops (counted) rather than blocks. *)

open Eio.Std

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [replicate] %s\n%!" (Procinfo.timestamp ()) s) fmt

let targets : (string * (bool * string * int * string)) list ref = ref []
let queue : string Eio.Stream.t = Eio.Stream.create 1000
let dropped = Atomic.make 0

let configure (urls : string list) : unit =
  targets :=
    List.map
      (fun u ->
        match Relay_broadcast.parse_relay_url u with
        | Some t -> (u, t)
        | None -> raise (Config.Config_error ("replicate_to: not a ws:// url: " ^ u)))
      urls

(* [keys]: the kwargs Julia passed on (it rebuilt them from its named arguments) *)
let push (name : string) ~(keys : string list) (kw : Kw.t) : unit =
  if !targets <> [] && not (Kw.bool kw "replicated" ~default:false) then begin
    let kwargs = List.filter_map (fun k -> match Kw.member kw k with `Null -> None | v -> Some (k, v)) keys @ [ ("replicated", `Bool true) ] in
    let msg = Yojson.Safe.to_string (`List [ `String "REQ"; `String "replicated_request"; `Assoc [ ("cache", `List [ `String name; `Assoc kwargs ]) ] ]) in
    if Eio.Stream.length queue >= 1000 then Atomic.incr dropped else Eio.Stream.add queue msg
  end

let send_one ~net ~clock (url, (tls, host, port, path)) (msg : string) : unit =
  try
    Eio.Time.with_timeout_exn clock 2.0 (fun () ->
        Switch.run @@ fun sw ->
        let ws = Ws_client.connect ~tls ~sw ~net ~clock ~host ~port ~path () in
        Fun.protect ~finally:(fun () -> try Ws_client.close ws with _ -> ()) (fun () -> Ws_client.send_text ws msg))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e -> log "%s: %s" url (Printexc.to_string e)

let run ~net ~clock () : unit =
  while true do
    let msg = Eio.Stream.take queue in
    Fiber.List.iter (fun t -> send_one ~net ~clock t msg) !targets;
    let d = Atomic.exchange dropped 0 in
    if d > 0 then log "queue full: %d request(s) not replicated" d
  done
