(* cache_storage_pg_listener.jl: LISTEN cache_storage; a {type:"live_event", kind, pubkey,
   identifier} payload notifies every follower of the live event's host — once per
   (event, follower) through live_event_notification_created, unless the follower blocked the host
   (live_event_pubkey_filterlist), at most once per host/follower per hour, and only when
   live_feed_is_hidden says the event is visible to them — through the importer's notification
   writer (LIVE_EVENT_HAPPENING = 501). *)

open Eio.Std
module CS = Primal_importer.Cache_storage
module CSE = Primal_importer.Cache_storage_ext
module PGOCaml = Postgres.PGOCaml

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [pg-listener] %s\n%!" (Procinfo.timestamp ()) s) fmt
let i64 = Int64.of_int

let live_event (dbh : Postgres.dbh) ~kind ~pubkey ~(identifier : string) : Nostr.t option =
  let kind = i64 kind in
  match [%pgsql dbh "select get_event_jsonb(pre.event_id)::text from parametrized_replaceable_events pre where pre.kind = $kind and pre.pubkey = $pubkey and pre.identifier = $identifier limit 1"] with
  | Some j :: _ -> ( try Some (Nostr.of_json (Yojson.Safe.from_string j)) with _ -> None)
  | _ -> None

let followers (dbh : Postgres.dbh) ~pubkey : string list = [%pgsql dbh "select follower_pubkey from pubkey_followers where pubkey = $pubkey"] |> List.filter_map Fun.id

let mark_created (dbh : Postgres.dbh) ~kind ~pubkey ~(identifier : string) ~follower ~now : bool =
  let kind = i64 kind and now = i64 now in
  match [%pgsql dbh "insert into live_event_notification_created (kind, pubkey, identifier, follower_pubkey, created_at) values ($kind, $pubkey, $identifier, $follower, $now) on conflict do nothing returning 1"] with
  | [] -> false
  | _ -> true

let blocked (dbh : Postgres.dbh) ~follower ~host : bool =
  match [%pgsql dbh "select 1 from live_event_pubkey_filterlist where user_pubkey = $follower and blocked_pubkey = $host limit 1"] with [] -> false | _ -> true

let hidden (dbh : Postgres.dbh) ~event_id ~follower ~kind ~pubkey ~(identifier : string) : bool =
  let kind = i64 kind in
  match [%pgsql dbh "select live_feed_is_hidden($event_id, $follower, live_feed_hosts($kind, $pubkey, $identifier), 'moderated')"] with Some b :: _ -> b | _ -> false

let handle ~(cfg : Config.t) (est : CS.est) (last : (string * string, float) Hashtbl.t) (payload : string) : unit =
  match Yojson.Safe.from_string payload with
  | `Assoc d when List.assoc_opt "type" d = Some (`String "live_event") -> (
      let kind = match List.assoc_opt "kind" d with Some (`Int k) -> k | _ -> raise Not_found in
      let pubkey = match List.assoc_opt "pubkey" d with Some (`String h) -> Hex_util.decode_exn h | _ -> raise Not_found in
      let identifier = match List.assoc_opt "identifier" d with Some (`String s) -> s | _ -> raise Not_found in
      let dbh = est.CS.dbh in
      match live_event dbh ~kind ~pubkey ~identifier with
      | None -> ()
      | Some e -> (
          let host = List.find_map (fun tg -> match tg with `String "p" :: `String h :: _ :: `String marker :: _ when String.lowercase_ascii marker = "host" -> Hex_util.decode_opt h | _ -> None) e.Nostr.tags in
          match host with
          | None -> ()
          | Some host ->
              let coord = Printf.sprintf "%d:%s:%s" kind (Hex_util.encode pubkey) identifier in
              let n = ref 0 in
              List.iter
                (fun follower ->
                  if mark_created dbh ~kind ~pubkey ~identifier ~follower ~now:(Utils.current_time ()) && not (blocked dbh ~follower ~host) then begin
                    let k = (host, follower) and t = Unix.gettimeofday () in
                    let due = match Hashtbl.find_opt last k with Some t0 -> t -. t0 >= float_of_int cfg.pg_listener_rate_limit_s | None -> true in
                    if due then begin
                      Hashtbl.replace last k t;
                      if not (hidden dbh ~event_id:e.Nostr.id ~follower ~kind ~pubkey ~identifier) then begin
                        incr n;
                        CSE.notification est follower e.Nostr.created_at Notifications.live_event_happening [ CS.Aeid e.Nostr.id; CS.Apk host; CS.Astr coord ]
                      end
                    end
                  end)
                (followers dbh ~pubkey:host);
              if cfg.pg_listener_log then log "live event %s: %d notifications" coord !n))
  | _ -> ()

let run ~(cfg : Config.t) ~net ~clock ~(stop : unit Promise.t) : unit =
  let est = { CS.cfg = CS.default_config; dbh = Postgres.connect ~application_name:"primal-jobs" cfg.cache_db; mem_dbh = Postgres.connect ~application_name:"primal-jobs" cfg.membership_db } in
  ignore (CSE.init_notification_gating est);
  let last : (string * string, float) Hashtbl.t = Hashtbl.create 1024 in
  let on_notify ~channel:_ ~payload =
    try handle ~cfg est last payload with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> log "%s: %s" payload (Printexc.to_string exn)
  in
  Fiber.first (fun () -> Promise.await stop) (fun () -> Pg_listen.run ~net ~clock cfg.cache_db ~channels:[ "cache_storage" ] ~on_notify)
