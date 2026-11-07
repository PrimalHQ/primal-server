(* Ported from Julia's dvm_feed_checker.jl: every [dvm_check_period_s], for each content-discovery DVM (kind-31990 handler with a
   k=5300 tag seen in the last 90 days), run the NIP-90 request App.dvm_feed runs (usecache=false)
   with the requester key, and upsert dvm_feeds(pubkey, identifier, updated_at, results, kind,
   personalized, ok). The results are the ids of the first 20 notes/articles (created_at desc) of
   the answer that exist in the cache, as Julia's dvm_feed(limit=20) response yields. *)

open Eio.Std
module PGOCaml = Postgres.PGOCaml

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [dvm-checker] %s\n%!" (Procinfo.timestamp ()) s) fmt
let i64 = Int64.of_int

let handler_eids (dbh : Postgres.dbh) ~since : string list =
  let since = i64 since in
  [%pgsql dbh
    "select distinct encode(pre.event_id, 'hex') from parametrized_replaceable_events pre, event_tags et \
     where et.kind = 31990 and pre.event_id = et.id and et.tag = 'k' and et.arg1 = '5300' and et.created_at >= $since"]
  |> List.filter_map Fun.id

let event_json (dbh : Postgres.dbh) ~event_id : Yojson.Safe.t option =
  match [%pgsql dbh "select get_event_jsonb($event_id)::text"] with
  | Some j :: _ -> ( try Some (Yojson.Safe.from_string j) with _ -> None)
  | _ -> None

let relay_url (dbh : Postgres.dbh) ~event_id : string option =
  match [%pgsql dbh "select relay_url from event_relay where event_id = $event_id limit 1"] with Some u :: _ -> Some u | _ -> None

(* lean: the handler event's own relay hints instead of event_relay (which only the old importer wrote):
   every value of a "relays" tag and the first value of "relay"/"r" tags, ws:// or wss:// URLs only, at
   most [max_relay_hints] *)
let max_relay_hints = 3

let relay_hints (tags : Yojson.Safe.t list) : string list =
  let is_relay u = String.starts_with ~prefix:"wss://" u || String.starts_with ~prefix:"ws://" u in
  List.concat_map
    (function
      | `List (`String "relays" :: vs) -> List.filter_map (function `String u -> Some (String.trim u) | _ -> None) vs
      | `List (`String ("relay" | "r") :: `String u :: _) -> [ String.trim u ]
      | _ -> [])
    tags
  |> List.filter is_relay |> List.sort_uniq compare |> List.filteri (fun i _ -> i < max_relay_hints)

(* (hex, kind, created_at) of the answer's events that exist in the cache *)
let posts (dbh : Postgres.dbh) ~(ids_json : string) : (string * int64 * int64) list =
  [%pgsql dbh
    "select encode(id, 'hex'), kind, created_at from events \
     where id = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($ids_json::jsonb) x(a)))"]
  |> List.filter_map (function Some h, Some k, Some t -> Some (h, k, t) | _ -> None)

let upsert (dbh : Postgres.dbh) ~pubkey ~(identifier : string) ~(results_json : string) ~(kind : string) ~personalized ~ok : unit =
  ignore
    [%pgsql dbh
      "insert into dvm_feeds (pubkey, identifier, updated_at, results, kind, personalized, ok) \
       values ($pubkey, $identifier, now()::timestamp, $results_json::jsonb, $kind, $personalized, $ok) \
       on conflict (pubkey, identifier) do update set updated_at = now()::timestamp, results = $results_json::jsonb, kind = $kind, personalized = $personalized, ok = $ok"]

let hexes_json (l : string list) = Yojson.Safe.to_string (`List (List.map (fun h -> `String h) l))

(* Handlers that don't answer are checked less often. Every round used to check every handler, each
   failure costing [dvm_timeout_s] (plus the randomized delay) in one of [dvm_parallel] fibers: when
   ~500 dead handlers appeared at once, a round took ~5 h, longer than the hour a row stays fresh
   for the API (Queries.dvm_feed_eids), and the working feeds dropped out of the featured list.
   After the n-th failure in a row a handler waits min(max_s, period * 2^(n-1)) before its next
   check (the first failure: the next round), keyed by (pubkey, d) so a republished handler event
   doesn't start over. An answer resets it. In memory only: a restart checks everything once. *)
module Backoff = struct
  type entry = { failures : int; last : float }
  type t = (string * string, entry) Hashtbl.t

  let create () : t = Hashtbl.create 1024
  let delay ~period ~max_s n = if n <= 0 then 0.0 else Float.min max_s (period *. (2.0 ** float_of_int (n - 1)))

  let due (t : t) ~period ~max_s ~now key =
    max_s <= 0.0 || match Hashtbl.find_opt t key with None -> true | Some e -> now >= e.last +. delay ~period ~max_s e.failures

  let succeeded (t : t) key = Hashtbl.remove t key

  let failed (t : t) ~now key =
    let n = match Hashtbl.find_opt t key with Some e -> e.failures | None -> 0 in
    Hashtbl.replace t key { failures = n + 1; last = now }

  (* the round's handlers in check order: the due ones, those without failures (answered last time,
     or new) first; the entries of handlers no longer listed are dropped *)
  let plan (t : t) ~period ~max_s ~now (items : ('k * 'a) list) : ('k * 'a) list * int =
    let listed = Hashtbl.create (List.length items) in
    List.iter (fun (k, _) -> Hashtbl.replace listed k ()) items;
    Hashtbl.filter_map_inplace (fun k e -> if Hashtbl.mem listed k then Some e else None) t;
    let due, skipped = List.partition (fun (k, _) -> due t ~period ~max_s ~now k) items in
    let ok, failing = List.partition (fun (k, _) -> not (Hashtbl.mem t k)) due in
    (ok @ failing, List.length skipped)
end

type handler = { dvm_pubkey : string; dvm_id : string; personalized : bool; relay : string list }

(* the kind-31990 handler event's parts the check needs *)
let handler_of ~(cfg : Config.t) (dbh : Postgres.dbh) ~event_id : handler option =
  match (event_json dbh ~event_id, if cfg.lean then None else relay_url dbh ~event_id) with
  | Some (`Assoc f), relay when (match List.assoc_opt "kind" f with Some (`Int 31990) -> true | _ -> false) -> (
      let tags = match List.assoc_opt "tags" f with Some (`List l) -> l | _ -> [] in
      let relay = if cfg.lean then relay_hints tags else Option.to_list relay in
      let dvm_id = List.find_map (function `List (`String "d" :: `String v :: _) -> Some v | _ -> None) tags in
      let dvm_pubkey = match List.assoc_opt "pubkey" f with Some (`String pk) -> Hex_util.decode_opt pk | _ -> None in
      match (dvm_id, dvm_pubkey) with
      | Some dvm_id, Some dvm_pubkey ->
          let personalized =
            match List.assoc_opt "content" f with
            | Some (`String c) -> ( match Yojson.Safe.from_string c with `Assoc d -> List.assoc_opt "personalized" d = Some (`Bool true) | _ -> false | exception _ -> false)
            | _ -> false
          in
          Some { dvm_pubkey; dvm_id; personalized; relay }
      | _ -> None)
  | _ -> None

(* run_dvm_checks *)
let run_checks ~(cfg : Config.t) ~(backoff : Backoff.t) ~net ~clock ~(pool : Postgres.pool) ~(stop : unit Promise.t) : unit =
  let now = Utils.current_time () in
  let eids = Postgres.use pool (fun dbh -> handler_eids dbh ~since:(now - (90 * 24 * 3600))) in
  let handlers =
    Postgres.use pool (fun dbh -> List.filter_map (fun eid_hex -> handler_of ~cfg dbh ~event_id:(Hex_util.decode_exn eid_hex)) eids)
    |> List.map (fun h -> ((h.dvm_pubkey, h.dvm_id), h))
    |> List.sort_uniq (fun (a, _) (b, _) -> compare a b)
  in
  let todo, skipped = Backoff.plan backoff ~period:cfg.dvm_check_period_s ~max_s:cfg.dvm_backoff_max_s ~now:(Unix.gettimeofday ()) handlers in
  let good = Atomic.make 0 and bad = Atomic.make 0 in
  Fiber.List.iter ~max_fibers:cfg.dvm_parallel
    (fun (key, h) ->
      if not (Promise.is_resolved stop) then begin
        if cfg.dvm_randomized_delays then Eio.Time.sleep clock (Random.float 1.0 *. cfg.dvm_check_period_s *. 0.8);
        let relays = List.sort_uniq compare (cfg.dvm_relays @ h.relay) in
        let jobreq =
          Dvm_client.job_request ~seckey:cfg.dvm_requester_seckey ~dvm_pubkey:h.dvm_pubkey ~relays ~user:(if h.personalized then Some cfg.dvm_requester_pubkey else None) ~now:(Utils.current_time ())
        in
        let t0 = Unix.gettimeofday () in
        let r = Dvm_client.request ~net ~clock ?proxy:cfg.relay_proxy ~relays ~jobreq ~timeout:cfg.dvm_timeout_s () in
        if cfg.dvm_log then log "%s %s %s %.1fs" (Hex_util.encode h.dvm_pubkey) h.dvm_id (match r with Ok _ -> "+" | Error _ -> "X") (Unix.gettimeofday () -. t0);
        (match r with Ok _ -> Backoff.succeeded backoff key | Error _ -> Backoff.failed backoff ~now:(Unix.gettimeofday ()) key);
        Postgres.use pool (fun dbh ->
            match r with
            | Ok ids ->
                Atomic.incr good;
                let ps = if ids = [] then [] else posts dbh ~ids_json:(hexes_json ids) in
                let ps = List.stable_sort (fun (_, _, a) (_, _, b) -> compare b a) ps |> List.filteri (fun i _ -> i < 20) in
                let notes = List.length (List.filter (fun (_, k, _) -> k = 1L) ps) and reads = List.length (List.filter (fun (_, k, _) -> k = 30023L) ps) in
                let results = List.filter_map (fun (h, k, _) -> if k = 1L || k = 30023L then Some h else None) ps in
                upsert dbh ~pubkey:h.dvm_pubkey ~identifier:h.dvm_id ~results_json:(hexes_json results) ~kind:(if notes >= reads then "notes" else "reads") ~personalized:h.personalized
                  ~ok:(notes + reads > 0)
            | Error _ ->
                Atomic.incr bad;
                upsert dbh ~pubkey:h.dvm_pubkey ~identifier:h.dvm_id ~results_json:"null" ~kind:"" ~personalized:h.personalized ~ok:false)
      end)
    todo;
  log "checked %d of %d handlers: %d good, %d bad, %d backing off" (List.length todo) (List.length handlers) (Atomic.get good) (Atomic.get bad) skipped

let run ~(cfg : Config.t) ~net ~clock ~(stop : unit Promise.t) : unit =
  let pool = Postgres.make_pool ~size:(cfg.dvm_parallel + 1) cfg.cache_db in
  let backoff = Backoff.create () in
  Periodic.run ~clock ~stop ~period:cfg.dvm_check_period_s ~label:"dvm_checker" (fun () -> run_checks ~cfg ~backoff ~net ~clock ~pool ~stop)
