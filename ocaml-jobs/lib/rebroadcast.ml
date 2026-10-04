(* event_rebroadcasting.jl: every second, each membership event_rebroadcasting row that is started
   and not finished gets its next batch — up to 100 of the user's events (kinds as requested) since
   event_created_at, replaceable kinds collapsed to their latest — broadcast to the target relays
   (each relay gets the events in order at 10 per second; done when every event has one OK or after
   30 s); the row records the intermediate index as events are accepted, the batch status, and
   advances when the batch succeeded; a batch identical to the previous one (same sha256) means the
   user has nothing new and the job finishes. *)

open Eio.Std
module PGOCaml = Postgres.PGOCaml

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [rebroadcast] %s\n%!" (Procinfo.timestamp ()) s) fmt
let i64 = Int64.of_int

let event_of_row (id, pubkey, created_at, kind, tags, content, sig_) : Nostr.t option =
  match (id, pubkey, created_at, kind, sig_) with
  | Some id, Some pubkey, Some created_at, Some kind, Some sig_ ->
      Some { Nostr.id; pubkey; created_at = Int64.to_int created_at; kind = Int64.to_int kind; tags = Importer.Cache_storage_ext.tags_of_json (Option.value tags ~default:"[]"); content = Option.value content ~default:""; sig_ }
  | _ -> None

(* App.get_user_events: (events sorted by created_at, count) *)
let get_user_events (dbh : Postgres.dbh) ~pubkey ~(kinds : int list option) ~since ~limit : Nostr.t list * int =
  let since = i64 since and limit = i64 limit in
  let rows =
    match kinds with
    | None -> [%pgsql dbh "select id, pubkey, created_at, kind, tags::text, content, sig from events where pubkey = $pubkey and created_at >= $since order by created_at asc limit $limit"]
    | Some ks ->
        let kinds_json = Yojson.Safe.to_string (`List (List.map (fun k -> `Int k) ks)) in
        [%pgsql dbh
          "select id, pubkey, created_at, kind, tags::text, content, sig from events where pubkey = $pubkey and created_at >= $since \
             and kind = any(array(select (a::text)::int8 from jsonb_array_elements_text($kinds_json::jsonb) x(a))) order by created_at asc limit $limit"]
  in
  let re = Hashtbl.create 16 and res = ref [] in
  List.iter
    (fun row ->
      match event_of_row row with
      | None -> ()
      | Some e ->
          if e.kind = 0 || e.kind = 3 || (e.kind >= 10000 && e.kind < 20000) then Hashtbl.replace re (e.pubkey, e.kind, "") e
          else if e.kind >= 30000 && e.kind < 40000 then
            let d = Option.value (List.find_map (function `String "d" :: `String v :: _ -> Some v | _ -> None) e.tags) ~default:"" in
            Hashtbl.replace re (e.pubkey, e.kind, d) e
          else res := e :: !res)
    rows;
  let all = List.rev !res @ Hashtbl.fold (fun _ e acc -> e :: acc) re [] in
  let sorted = List.stable_sort (fun (a : Nostr.t) (b : Nostr.t) -> compare a.created_at b.created_at) all in
  (sorted, List.length sorted)

type result = { success : bool; relays_done : int; events_done : int; sends : int; duplicates : int; per_eid : (string * int) list; timedout : bool }

(* broadcast_events: one connection per relay, events in order at [rate]/s, OKs counted per event;
   done when every event was accepted somewhere, or after [timeout] *)
let broadcast_events ~net ~clock ~(proxy : (string * int) option) ~(relays : string list) ~(events : Nostr.t list) ~(timeout : float) ~(on_first_accept : Nostr.t -> unit) : result =
  let per_eid : (string, int) Hashtbl.t = Hashtbl.create 128 and sends = ref 0 and duplicates = ref 0 and relays_done = ref 0 in
  let by_id = Hashtbl.create 128 in
  List.iter (fun (e : Nostr.t) -> Hashtbl.replace by_id (Nostr.id_hex e) e) events;
  let all_done, resolve = Promise.create () in
  let check_done () = if Hashtbl.length per_eid = List.length events && not (Promise.is_resolved all_done) then Promise.resolve resolve () in
  let timed_out = ref false in
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
                         Fiber.both
                           (fun () ->
                             List.iter
                               (fun (e : Nostr.t) ->
                                 Ws_client.send_text ws (Printf.sprintf "[\"EVENT\",%s]" (Nostr.to_string e));
                                 Eio.Time.sleep clock 0.1)
                               events)
                           (fun () ->
                             let rec loop () =
                               match Ws_client.recv_timeout ws ~timeout with
                               | `Msg m ->
                                   (match Yojson.Safe.from_string m with
                                   | `List (`String "OK" :: `String id :: `Bool accepted :: _) -> (
                                       match Hashtbl.find_opt by_id id with
                                       | Some e ->
                                           incr sends;
                                           if not accepted then incr duplicates;
                                           if not (Hashtbl.mem per_eid id) then on_first_accept e;
                                           Hashtbl.replace per_eid id (1 + Option.value (Hashtbl.find_opt per_eid id) ~default:0);
                                           check_done ()
                                       | None -> ())
                                   | _ -> ()
                                   | exception _ -> ());
                                   loop ()
                               | `Closed | `Timeout -> ()
                             in
                             loop ()))
               with
              | Eio.Cancel.Cancelled _ as ex -> raise ex
              | exn -> log "relay %s: %s" url (Printexc.to_string exn));
              incr relays_done;
              `Stop_daemon))
        relays;
      Fiber.first (fun () -> Promise.await all_done) (fun () -> Eio.Time.sleep clock timeout; timed_out := true));
  let success = Hashtbl.length per_eid = List.length events in
  { success; relays_done = !relays_done; events_done = Hashtbl.length per_eid; sends = !sends; duplicates = !duplicates; per_eid = Hashtbl.fold (fun k v acc -> (k, v) :: acc) per_eid []; timedout = (not success) && !timed_out }

let result_json ~(relays : string list) ~(events : int) (r : result) : string =
  Primal_api.Jsonfmt.julia_pretty
    (`Assoc
      [ ("success", `Bool r.success); ("relays", `Int (List.length relays)); ("relays_started", `Int (List.length relays)); ("relays_done", `Int r.relays_done); ("events", `Int events);
        ("events_done", `Int r.events_done); ("sends", `Int r.sends); ("duplicates", `Int r.duplicates); ("per_eid", `Assoc (List.map (fun (k, v) -> (k, `Int v)) r.per_eid));
        ("timedout", `Bool r.timedout); ("relay_urls", `List (List.map (fun u -> `String u) relays)) ])

let run_once ~(cfg : Config.t) ~net ~clock ~(cache : Postgres.pool) ~(mem : Postgres.pool) : unit =
  let pending = Postgres.use mem Queries_mem.rebroadcasts_pending in
  Fiber.List.iter ~max_fibers:8
    (fun (rb : Queries_mem.rebroadcast) ->
      let pubkey = rb.rb_pubkey in
      try
        let kinds = match rb.rb_kinds with Some k -> ( match Yojson.Safe.from_string k with `List l -> Some (List.filter_map (function `Int i -> Some i | _ -> None) l) | _ -> None) | None -> None in
        let relays = match rb.rb_relays with Some r -> ( match Yojson.Safe.from_string r with `List l -> List.filter_map (function `String u -> Some u | _ -> None) l | _ -> []) | None -> [] in
        let events, cnt = Postgres.use cache (fun dbh -> get_user_events dbh ~pubkey ~kinds ~since:(Int64.to_int rb.rb_since) ~limit:100) in
        let batchhash = Digestif.SHA256.(to_raw_string (digest_string ("[" ^ String.concat "," (List.map Nostr.to_string events) ^ "]"))) in
        if rb.rb_batchhash = Some batchhash then Postgres.use mem (fun m -> Queries_mem.rebroadcast_finished m ~pubkey)
        else begin
          let intidx = ref 0 in
          let r =
            broadcast_events ~net ~clock ~proxy:cfg.relay_proxy ~relays ~events ~timeout:30.0 ~on_first_accept:(fun _ ->
                incr intidx;
                let idx = Int64.to_int rb.rb_event_idx + !intidx in
                try Postgres.use mem (fun m -> Queries_mem.rebroadcast_intermediate m ~pubkey ~idx) with _ -> ())
          in
          Postgres.use mem (fun m ->
              Queries_mem.rebroadcast_batch_status m ~pubkey ~status:(result_json ~relays ~events:(List.length events) r);
              if r.success then
                let last = match List.rev events with (e : Nostr.t) :: _ -> e.created_at | [] -> Int64.to_int rb.rb_since in
                Queries_mem.rebroadcast_advance m ~pubkey ~created_at:last ~cnt ~batchhash)
        end
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          log "%s: %s" (Hex_util.encode pubkey) (Printexc.to_string exn);
          (try Postgres.use mem (fun m -> Queries_mem.rebroadcast_failed m ~pubkey ~exn:(Printexc.to_string exn)) with _ -> ()))
    pending

let run ~(cfg : Config.t) ~net ~clock ~(stop : unit Promise.t) : unit =
  let cache = Postgres.make_pool ~size:9 cfg.cache_db and mem = Postgres.make_pool ~size:9 cfg.membership_db in
  Periodic.run ~clock ~stop ~period:1.0 ~label:"rebroadcast" (fun () -> run_once ~cfg ~net ~clock ~cache ~mem)
