(* Julia's periodic broadcasters (cache_server_handlers.jl netstats_handler / ext_periodic): clients
   keep a REQ open for notification_counts(_2), directmsg_count(_2), net_stats or
   rebroadcasting_status and the server pushes the current value on a fixed period — every second
   for the two counters, every two seconds for the rebroadcasting status, every
   1/NETSTATS_RATE seconds for the network stats. Julia answered the REQ with an immediate EOSE
   and ran one query per subscription per tick; here the counters are fetched with one statement
   per tick for all subscribed pubkeys. Pushes are plain-text EVENT frames, like Julia's
   `@async send(conn, JSON.json(["EVENT", subid, d]))`, zlib mode or not. *)

open Eio.Std

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [bcast] %s\n%!" (Procinfo.timestamp ()) s) fmt

type kind = Notification_counts of bool | Directmsg_count of bool | Net_stats | Rebroadcasting

type sub = { send : string -> unit; subid : string; kind : kind; pubkey : string (* raw; "" for net_stats *) }
type sub_key = int * string

type t = {
  lock : Mutex.t;
  subs : (sub_key, sub) Hashtbl.t;
  conn_subs : (int, (string, unit) Hashtbl.t) Hashtbl.t;
}

let create () = { lock = Mutex.create (); subs = Hashtbl.create 1024; conn_subs = Hashtbl.create 1024 }

let with_lock t f =
  Mutex.lock t.lock;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.lock) f

let add t ~conn_id ~subid (s : sub) =
  Hashtbl.replace t.subs (conn_id, subid) s;
  let cs = match Hashtbl.find_opt t.conn_subs conn_id with Some c -> c | None -> let c = Hashtbl.create 4 in Hashtbl.replace t.conn_subs conn_id c; c in
  Hashtbl.replace cs subid ()

let register (t : t) ~conn_id ~subid ~(send : string -> unit) (r : Response.registration) : unit =
  with_lock t (fun () ->
      match r with
      | Response.Notification_counts { pubkey; v2 } -> add t ~conn_id ~subid { send; subid; kind = Notification_counts v2; pubkey }
      | Response.Directmsg_count { pubkey; v2 } -> add t ~conn_id ~subid { send; subid; kind = Directmsg_count v2; pubkey }
      | Response.Net_stats -> add t ~conn_id ~subid { send; subid; kind = Net_stats; pubkey = "" }
      | Response.Rebroadcasting_status { pubkey } -> add t ~conn_id ~subid { send; subid; kind = Rebroadcasting; pubkey }
      | Response.Live_events _ | Response.Live_events_from_follows _ -> ())

let unregister_sub (t : t) ~conn_id ~subid : unit =
  with_lock t (fun () ->
      Hashtbl.remove t.subs (conn_id, subid);
      match Hashtbl.find_opt t.conn_subs conn_id with Some cs -> Hashtbl.remove cs subid | None -> ())

let unregister_conn (t : t) ~conn_id : unit =
  with_lock t (fun () ->
      (match Hashtbl.find_opt t.conn_subs conn_id with
      | Some cs -> Hashtbl.iter (fun subid () -> Hashtbl.remove t.subs (conn_id, subid)) cs
      | None -> ());
      Hashtbl.remove t.conn_subs conn_id)

let stats (t : t) : int = with_lock t (fun () -> Hashtbl.length t.subs)

let snapshot (t : t) (pred : kind -> bool) : sub list =
  with_lock t (fun () -> Hashtbl.fold (fun _ s acc -> if pred s.kind then s :: acc else acc) t.subs [])

let push (s : sub) (msg : string) = try s.send (Protocol.event s.subid msg) with _ -> ()

(* {1 Message shapes} (app.jl / app_ext.jl) *)

(* get_notification_counts: {"kind":10000112,"pubkey":hex,"1":n,...} in NotificationType order *)
let notification_counts_msg ~(pubkey_hex : string) (counts : int64 list) : string =
  Yojson.Safe.to_string
    (`Assoc
      ([ ("kind", `Int Kind.notifications_summary); ("pubkey", `String pubkey_hex) ]
      @ List.map2 (fun t n -> (string_of_int t, `Int (Int64.to_int n))) Queries.notification_types counts))

let notification_counts_2_msg ~(pubkey_hex : string) (counts : int64 list) : string =
  let d = `Assoc (List.map2 (fun t n -> (string_of_int t, `Int (Int64.to_int n))) Queries.notification_types counts) in
  Yojson.Safe.to_string
    (`Assoc [ ("kind", `Int Kind.notifications_summary_2); ("pubkey", `String pubkey_hex); ("content", `String (Yojson.Safe.to_string d)) ])

let directmsg_count_msg (cnt : int64) : string =
  Yojson.Safe.to_string (`Assoc [ ("kind", `Int Kind.directmsg_count); ("cnt", `Int (Int64.to_int cnt)) ])

let directmsg_count_2_msg (cnt : int64) : string =
  Yojson.Safe.to_string (`Assoc [ ("kind", `Int Kind.directmsg_count_2); ("content", `String (Int64.to_string cnt)) ])

(* membership_content_rebroadcast_status *)
let rebroadcast_msg (r : Queries_mem.rebroadcast) : string =
  let running = r.started_at <> None && r.finished_at = None in
  let progress =
    if running then
      let idx = Option.value r.event_idx_intermediate ~default:0L and cnt = Option.value r.event_count ~default:0L in
      if cnt = 0L then 1.0 else Float.min 1.0 (Int64.to_float idx /. Int64.to_float cnt)
    else 0.0
  in
  let kinds = match r.kinds_json with Some k -> ( try Yojson.Safe.from_string k with _ -> `Null) | None -> `Null in
  let content =
    `Assoc
      [
        ("running", `Bool running);
        ("kinds", kinds);
        ("status", match r.status with Some s -> `String s | None -> `Null);
        ("progress", `Float progress);
      ]
  in
  Yojson.Safe.to_string
    (`Assoc [ ("kind", `Int Kind.membership_content_rebroadcast_status); ("content", `String (Yojson.Safe.to_string content)) ])

(* {1 Loops} *)

let guard name f = try f () with Eio.Cancel.Cancelled _ as e -> raise e | e -> log "%s: %s" name (Printexc.to_string e)

(* every second: notification and direct-message counts *)
let counts_loop (t : t) ~clock : unit =
  while true do
    Eio.Time.sleep clock 1.0;
    let subs = snapshot t (function Notification_counts _ | Directmsg_count _ -> true | _ -> false) in
    if subs <> [] then
      guard "counts" (fun () ->
          let nc_subs = List.filter (fun s -> match s.kind with Notification_counts _ -> true | _ -> false) subs in
          let dm_subs = List.filter (fun s -> match s.kind with Directmsg_count _ -> true | _ -> false) subs in
          let hexes l = List.map (fun s -> Hex_util.encode s.pubkey) l |> List.sort_uniq compare in
          let nc, dm =
            Db.with_cache ~clock (fun c ->
                ( (if nc_subs = [] then [] else Queries.notification_counts c ~pubkeys_json:(Queries.hexes_json (hexes nc_subs))),
                  if dm_subs = [] then [] else Queries.directmsg_counts c ~pubkeys_json:(Queries.hexes_json (hexes dm_subs)) ))
          in
          List.iter
            (fun s ->
              let pubkey_hex = Hex_util.encode s.pubkey in
              match s.kind with
              | Notification_counts v2 -> (
                  (* Julia: one message per row, nothing when the user has no row *)
                  match List.assoc_opt pubkey_hex nc with
                  | Some counts -> push s (if v2 then notification_counts_2_msg ~pubkey_hex counts else notification_counts_msg ~pubkey_hex counts)
                  | None -> ())
              | Directmsg_count v2 ->
                  let cnt = Option.value (List.assoc_opt pubkey_hex dm) ~default:0L in
                  push s (if v2 then directmsg_count_2_msg cnt else directmsg_count_msg cnt)
              | _ -> ())
            subs)
  done

(* every two seconds: rebroadcasting status (membership DB) *)
let rebroadcast_loop (t : t) ~clock : unit =
  while true do
    Eio.Time.sleep clock 2.0;
    let subs = snapshot t (function Rebroadcasting -> true | _ -> false) in
    if subs <> [] then
      guard "rebroadcasting" (fun () ->
          let pks = List.map (fun s -> s.pubkey) subs |> List.sort_uniq compare in
          let rows = Db.with_membership ~clock (fun m -> List.map (fun pk -> (pk, Queries_mem.rebroadcast_status m ~pubkey:pk)) pks) in
          List.iter
            (fun s -> match List.assoc_opt s.pubkey rows with Some (Some r) -> push s (rebroadcast_msg r) | _ -> ())
            subs)
  done

(* network stats (Netstats: the importer's HTTP /api or its stats file), every netstats period *)
let netstats_loop (t : t) ~net ~clock ~(cfg : Config.t) : unit =
  while true do
    Eio.Time.sleep clock cfg.netstats_period_s;
    let subs = snapshot t (function Net_stats -> true | _ -> false) in
    if subs <> [] then
      guard "net_stats" (fun () ->
          match Netstats.content ~net ~clock cfg with
          | Some content ->
              let msg = Yojson.Safe.to_string (`Assoc [ ("kind", `Int Kind.net_stats); ("content", `String content) ]) in
              List.iter (fun s -> push s msg) subs
          | None -> ())
  done

let run (t : t) ~net ~clock ~(cfg : Config.t) : unit =
  Switch.run @@ fun sw ->
  Fiber.fork_daemon ~sw (fun () -> counts_loop t ~clock; `Stop_daemon);
  Fiber.fork_daemon ~sw (fun () -> rebroadcast_loop t ~clock; `Stop_daemon);
  if Netstats.configured cfg then Fiber.fork_daemon ~sw (fun () -> netstats_loop t ~net ~clock ~cfg; `Stop_daemon)
  else log "neither network_stats_url nor network_stats_file is set: net_stats subscriptions stay silent";
  Fiber.await_cancel ()
