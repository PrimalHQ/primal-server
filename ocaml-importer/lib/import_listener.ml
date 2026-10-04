(* Import listener: the typed replacement for the Julia FirehoseServer's `EVAL`/`EXPR` channel on
   port 12000+N (ocaml-plan.md §7.2). It accepts ONLY event imports, newline-delimited JSON:

     ["EVENT", <subid>, <event>]       -> ["OK", <id hex>, "imported"|"duplicate"|"rejected"]
     ["IMPORT", [<event>, ...]]        -> ["OK", {"imported":n,"duplicates":n,"rejected":n,"errors":n}]
     anything else                     -> ["NOTICE", "unsupported message"]

   Used by the API's import_events (events a user just posted through Primal): each event is
   imported synchronously on this fiber's own est (so the caller gets the outcome), then the
   per-event DAG indexers run (Dag_index) and, for text notes, the thread root/reply events are
   re-broadcast to the author's relays (Julia App.ext_import_event -> broadcast_reply). Mirrors the
   body of the Julia `rex` expression in app.jl:1955-1967, minus the remote code execution.

   One connection is served at a time per est (a PGOCaml connection is single-fiber); concurrent
   clients queue on [lock]. Volume is user-posted events, not the firehose. *)

open Eio.Std
module CS = Cache_storage
module CSE = Cache_storage_ext

let log fmt = Printf.ksprintf (fun s -> Printf.printf "[import-listener] %s\n%!" s) fmt

type outcome = { imported : int; duplicates : int; rejected : int; errors : int }

let zero = { imported = 0; duplicates = 0; rejected = 0; errors = 0 }

(* Julia App.broadcast_reply (app_ext.jl:2444): for a text note, push the thread's root/reply
   target events (the ones its e-tags mark "root"/"reply") to the author's relays, so the
   author's relays hold the context of the reply. Relay lookup needs the DB (under the lock);
   the network part runs detached, bounded by [timeout]. *)
let broadcast_reply ~sw ~net ~clock ?proxy ~timeout (est : CS.est) (e : Nostr.t) : unit =
  if e.kind = Nostr.kind_text_note then begin
    let relays = CSE.get_user_relays est e.pubkey in
    let targets =
      List.filter_map
        (fun tg ->
          if Nostr.tag_len tg >= 4 && Nostr.tag_name tg = Some "e"
             && (Nostr.tag_field tg 3 = Some "root" || Nostr.tag_field tg 3 = Some "reply")
          then Option.bind (Nostr.tag_field tg 1) CS.decode32
          else None)
        e.tags
      |> List.filter_map (fun eid -> CS.get_event est eid)
    in
    if relays <> [] && targets <> [] then
      Fiber.fork ~sw (fun () ->
          List.iter
            (fun (t : Nostr.t) ->
              let rs =
                Relay_broadcast.broadcast ~net ~clock ?proxy ~timeout ~relays (Nostr.to_string t)
              in
              log "broadcast_reply %s -> %d/%d relays accepted" (Nostr.id_hex t)
                (Relay_broadcast.accepted_count rs) (List.length relays))
            targets)
  end

(* Import one event the way the Julia rex body does: human override, import, instant indexers,
   ext_import_event. Returns the status string for the reply. *)
let import_one ~sw ~net ~clock ?proxy ~timeout ~reconnect_est ~poll_votes_enabled (est : CS.est)
    (e : Nostr.t) : string =
  try
    CS.add_human_override est ~pubkey:e.pubkey ~is_human:true ~source:"import_events";
    let t0 = Unix.gettimeofday () in
    let r = CS.import_event est e in
    Dag_index.index_event ~poll_votes_enabled est e;
    broadcast_reply ~sw ~net ~clock ?proxy ~timeout est e;
    let status =
      match r with CS.Imported -> "imported" | CS.Duplicate -> "duplicate" | CS.Rejected -> "rejected"
    in
    log "kind %d %s -> %s (%.0f ms)" e.kind (Nostr.id_hex e) status
      ((Unix.gettimeofday () -. t0) *. 1000.);
    status
  with
  | Eio.Cancel.Cancelled _ as ex -> raise ex
  | exn ->
      log "import error %s: %s" (Nostr.id_hex e) (Printexc.to_string exn);
      if Postgres.is_connection_error exn then reconnect_est est;
      "error"

let parse_event (j : Yojson.Safe.t) : Nostr.t option = try Some (Nostr.of_json j) with _ -> None

let handle_line ~import (line : string) : string =
  let reply j = Yojson.Safe.to_string j in
  match Yojson.Safe.from_string line with
  | `List (`String "EVENT" :: _subid :: ev :: _) -> (
      match parse_event ev with
      | Some e -> reply (`List [ `String "OK"; `String (Nostr.id_hex e); `String (import e) ])
      | None -> reply (`List [ `String "NOTICE"; `String "invalid event" ]))
  | `List [ `String "IMPORT"; `List evs ] ->
      let o =
        List.fold_left
          (fun o ev ->
            match parse_event ev with
            | None -> { o with errors = o.errors + 1 }
            | Some e -> (
                match import e with
                | "imported" -> { o with imported = o.imported + 1 }
                | "duplicate" -> { o with duplicates = o.duplicates + 1 }
                | "rejected" -> { o with rejected = o.rejected + 1 }
                | _ -> { o with errors = o.errors + 1 }))
          zero evs
      in
      reply
        (`List
          [
            `String "OK";
            `Assoc
              [
                ("imported", `Int o.imported);
                ("duplicates", `Int o.duplicates);
                ("rejected", `Int o.rejected);
                ("errors", `Int o.errors);
              ];
          ])
  | _ -> reply (`List [ `String "NOTICE"; `String "unsupported message" ])
  | exception _ -> reply (`List [ `String "NOTICE"; `String "invalid json" ])

let ipaddr_of_host (host : string) : Eio.Net.Ipaddr.v4v6 =
  match host with
  | "0.0.0.0" | "" -> Eio.Net.Ipaddr.V4.any
  | "127.0.0.1" | "localhost" -> Eio.Net.Ipaddr.V4.loopback
  | h -> (
      match Ipaddr.of_string h with
      | Ok ip -> Eio.Net.Ipaddr.of_raw (Ipaddr.to_octets ip)
      | Error (`Msg m) -> failwith ("import listener: bad host " ^ h ^ ": " ^ m))

let max_line = 16 * 1024 * 1024

(* Serve forever. [est] is this listener's own connection pair (never shared with workers). *)
let run ~net ~clock ?proxy ~(host : string) ~(port : int) ~(est : CS.est) ~reconnect_est
    ~(broadcast_timeout : float) ~(poll_votes_enabled : bool) () : unit =
  Switch.run @@ fun sw ->
  let lock = Eio.Mutex.create () in
  let sock =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:64 net (`Tcp (ipaddr_of_host host, port))
  in
  log "listening on %s:%d" host port;
  let import e =
    Eio.Mutex.use_rw ~protect:true lock (fun () ->
        import_one ~sw ~net ~clock ?proxy ~timeout:broadcast_timeout ~reconnect_est
          ~poll_votes_enabled est e)
  in
  let handler flow _addr =
    let r = Eio.Buf_read.of_flow (flow :> _ Eio.Flow.source) ~max_size:max_line in
    let rec loop () =
      match Eio.Buf_read.line r with
      | "" -> ()
      | line ->
          let resp = handle_line ~import line in
          Eio.Flow.copy_string (resp ^ "\n") (flow :> _ Eio.Flow.sink);
          loop ()
      | exception End_of_file -> ()
    in
    loop ()
  in
  let on_error exn =
    match exn with
    | Eio.Cancel.Cancelled _ -> ()
    | _ -> log "connection error: %s" (Printexc.to_string exn)
  in
  while true do
    Eio.Net.accept_fork ~sw sock ~on_error handler
  done
