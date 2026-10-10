(* dvm_service_provider.jl: Primal's NIP-90 content-discovery DVMs. Each feed of [feeds] is its own
   DVM with its own key, sha256(salt ‖ feed_id), so the pubkeys are stable for a fixed salt.

   On every relay connection (dvm_provider_relays, through relay_proxy) each feed announces itself:
   the NIP-89 handler information (kind 31990, d = feed id) for an active feed, a deletion (kind 5)
   of it for a deleted one, and a NIP-65 relay list (kind 10002) — all with the fixed
   dvm_provider_announce_created_at, so the events (and their ids) are the same on every connect
   and every host; the content is serialized in Julia's key order for that. Then one subscription
   takes the kind-5300 job requests addressed to any active feed (#p).

   A request (signature checked; "param max_results" and "param user" honoured, "relays" added to
   the answer relays) is recorded in the membership DB's dvm_usage and answered with a kind-6300
   result: the ids of the kind 1 / 30023 events of mega_feed_directive {spec, user_pubkey, limit 50}
   on this host's cache API code, in-process (as Julia's App.mega_feed_directive call, so without
   the client-facing moderation pass), sent to the answer relays. A request arriving over several
   relays is answered once (Julia answered once per relay it came over).

   Julia answered a verified-only feed for a user without a Primal name with a kind-7000 error;
   no active feed is verified-only, so that path is not carried over (a feed marked so is refused
   at start). With dvm_provider_dry_run, nothing is published and nothing is recorded: the
   announcements and answers are only logged. *)

open Eio.Std

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [dvm-provider] %s\n%!" (Procinfo.timestamp ()) s) fmt

let nip89_handler_information = 31990
let nip90_content_discovery_request = 5300
let nip90_content_discovery_result = 6300
let nip65_relay_list_metadata = 10002

type state = Active | Deleted

type feed = { id : string; state : state; name : string; about : string; image : string; spec : string; verified_only : bool; personalized : bool }

let feed id state name about image spec verified_only personalized = { id; state; name; about; image; spec; verified_only; personalized }

(* DVMServiceProvider.FEEDS *)
let feeds =
  [
    feed "primal-dvm-0" Active "Trending on Primal 4h" "Global trending notes in the past 4 hours" "https://m.primal.net/LsXL.png" {|{"id":"global-trending","kind":"notes","hours":4}|} false false;
    feed "primal-dvm-1" Deleted "Trending 4h Notes on Primal" "Trending notes on Primal posted in the last four hours" "" "" false false;
    feed "primal-dvm-2" Active "Trending on Primal 24h" "Global trending notes in the past 24 hours" "https://m.primal.net/LsDT.png" {|{"id":"global-trending","kind":"notes","hours":24}|} false false;
    feed "primal-dvm-3" Deleted "Nostr Topic Reads" "Nostr Topic Reads" "" "" true false;
    feed "primal-dvm-4" Deleted "Bitcoin Topic Reads" "Bitcoin Topic Reads" "" "" false false;
    feed "primal-dvm-5" Deleted "Linux Topic Reads - deletion test" "Linux Topic Reads - deletion test" "" "" false false;
    feed "primal-dvm-6" Active "Trending on Primal 1h" "Global trending notes in the past hour" "https://m.primal.net/LsDO.png" {|{"id":"global-trending","kind":"notes","hours":1}|} false false;
    feed "primal-dvm-7" Active "Trending on Primal 12h" "Global trending notes in the past 12 hours" "https://m.primal.net/LsDc.png" {|{"id":"global-trending","kind":"notes","hours":12}|} false false;
    feed "primal-dvm-8" Active "Trending on Primal 48h" "Global trending notes in the past 48 hours" "https://m.primal.net/LsDf.png" {|{"id":"global-trending","kind":"notes","hours":48}|} false false;
    feed "primal-dvm-9" Active "Trending on Primal 7d" "Global trending notes in the past 7 days" "https://m.primal.net/LsDh.png" {|{"id":"global-trending","kind":"notes","hours":168}|} false false;
    feed "primal-dvm-10" Active "Bitcoin Reads" "Bitcoin-related long form notes" "https://m.primal.net/LzCI.png" {|{"id":"reads-topic-bitcoin"}|} false false;
    feed "primal-dvm-11" Active "Art Reads" "Art-related long form notes" "https://m.primal.net/McZA.png" {|{"id":"reads-topic-art"}|} false false;
    feed "primal-dvm-12" Active "Finance Reads" "Finance-related long form notes" "https://m.primal.net/McZJ.png" {|{"id":"reads-topic-finance"}|} false false;
    feed "primal-dvm-13" Active "Food Reads" "Food-related long form notes" "https://m.primal.net/McZK.png" {|{"id":"reads-topic-food"}|} false false;
    feed "primal-dvm-14" Active "Gaming Reads" "Gaming-related long form notes" "https://m.primal.net/McZM.png" {|{"id":"reads-topic-gaming"}|} false false;
    feed "primal-dvm-15" Active "Human Rights Reads" "Human rights-related long form notes" "https://m.primal.net/McZN.png" {|{"id":"reads-topic-human-rights"}|} false false;
    feed "primal-dvm-16" Active "Music Reads" "Music-related long form notes" "https://m.primal.net/McZP.png" {|{"id":"reads-topic-music"}|} false false;
    feed "primal-dvm-17" Active "News Reads" "News-related long form notes" "https://m.primal.net/McZS.png" {|{"id":"reads-topic-news"}|} false false;
    feed "primal-dvm-18" Active "Nostr Reads" "Nostr-related long form notes" "https://m.primal.net/McZT.png" {|{"id":"reads-topic-nostr"}|} false false;
    feed "primal-dvm-19" Active "Philosophy Reads" "Philosophy-related long form notes" "https://m.primal.net/McZU.png" {|{"id":"reads-topic-philosophy"}|} false false;
    feed "primal-dvm-20" Active "Photography Reads" "Photography-related long form notes" "https://m.primal.net/McZW.png" {|{"id":"reads-topic-photography"}|} false false;
    feed "primal-dvm-21" Active "Podcasts Reads" "Podcasts-related long form notes" "https://m.primal.net/McZY.png" {|{"id":"reads-topic-podcasts"}|} false false;
    feed "primal-dvm-22" Active "Sports Reads" "Sports-related long form notes" "https://m.primal.net/McZZ.png" {|{"id":"reads-topic-sports"}|} false false;
    feed "primal-dvm-23" Active "Technology Reads" "Technology-related long form notes" "https://m.primal.net/McZc.png" {|{"id":"reads-topic-technology"}|} false false;
    feed "primal-dvm-24" Active "Travel Reads" "Travel-related long form notes" "https://m.primal.net/MYQe.png" {|{"id":"reads-topic-travel"}|} false false;
  ]

type keyed = { f : feed; seckey : string; pubkey : string }

let keyed ~(salt : string) (f : feed) : keyed =
  let seckey = Digestif.SHA256.(to_raw_string (digest_string (salt ^ f.id))) in
  { f; seckey; pubkey = Nostr.pubkey_of_seckey seckey }

let s v = `String v
let tag l : Nostr.tag = List.map s l

(* the handler information content, in Julia's JSON.json((; hinfo..., name, about, picture, image,
   primal_spec, personalized[, subscription])) key order *)
let handler_content (f : feed) : string =
  Yojson.Safe.to_string
    (`Assoc
      ([
         ("amount", s "free");
         ("cashuAccepted", `Bool false);
         ( "nip90Params",
           `Assoc
             [
               ( "max_results",
                 `Assoc [ ("values", `List []); ("required", `Bool false); ("description", s "The number of maximum results to return (default currently 100)") ] );
             ] );
         ("encryptionSupported", `Bool false);
         ("lud16", s "primal@primal.net");
         ("name", s f.name);
         ("about", s f.about);
         ("picture", s f.image);
         ("image", s f.image);
         ("primal_spec", s f.spec);
         ("personalized", `Bool f.personalized);
       ]
      @ if f.verified_only then [ ("subscription", `Bool true) ] else []))

let announcements ~(created_at : int) ~(relays : string list) (k : keyed) : Nostr.t list =
  let active =
    Nostr.create ~seckey:k.seckey ~created_at ~kind:nip89_handler_information
      ~tags:[ tag [ "d"; k.f.id ]; tag [ "k"; string_of_int nip90_content_discovery_request ] ]
      ~content:(handler_content k.f)
  in
  let main =
    match k.f.state with
    | Active -> active
    | Deleted ->
        Nostr.create ~seckey:k.seckey ~created_at ~kind:Nostr.kind_event_deletion
          ~tags:[ tag [ "e"; Nostr.id_hex active ]; tag [ "a"; Printf.sprintf "%d:%s:%s" nip89_handler_information (Hex_util.encode k.pubkey) k.f.id ] ]
          ~content:""
  in
  let relay_list =
    Nostr.create ~seckey:k.seckey ~created_at ~kind:nip65_relay_list_metadata
      ~tags:(List.filter_map (fun u -> if Str_util.find_substring u "192.168." <> None then None else Some (tag [ "r"; u ])) relays)
      ~content:""
  in
  [ main; relay_list ]

(* request ids answered recently (several relays deliver the same request) *)
let seen : (string, float) Hashtbl.t = Hashtbl.create 1024
let seen_lock = Mutex.create ()

let first_sight (id : string) : bool =
  Mutex.lock seen_lock;
  let now = Unix.gettimeofday () in
  let fresh = not (Hashtbl.mem seen id) in
  if fresh then Hashtbl.replace seen id now;
  if Hashtbl.length seen > 20_000 then Hashtbl.filter_map_inplace (fun _ t -> if now -. t < 3600. then Some t else None) seen;
  Mutex.unlock seen_lock;
  fresh

(* App.mega_feed_directive in-process; the ids of its kind 1 / 30023 events in feed order. The API
   emits a feed's events in no particular order and orders them with the feed range message
   ("elements"); Julia's in-process call returned them in feed order. *)
let feed_event_ids ~(ctx : Primal_api.Handlers.ctx) ~(spec : string) ~(user_pubkey : string) : string list option =
  let kw = `Assoc [ ("spec", s spec); ("user_pubkey", s (Hex_util.encode user_pubkey)); ("limit", `Int 50) ] in
  match Primal_api.Funcall.dispatch ctx Primal_api.Funcall.Mega_feed_directive kw with
  | Primal_api.Response.Handled r ->
      let events = ref [] and elements = ref None in
      List.iter
        (fun m ->
          match Yojson.Safe.from_string m with
          | `Assoc f -> (
              match (List.assoc_opt "kind" f, List.assoc_opt "id" f, List.assoc_opt "content" f) with
              | Some (`Int (1 | 30023)), Some (`String id), _ -> events := id :: !events
              | Some (`Int k), _, Some (`String c) when k = Kind.range -> (
                  match Yojson.Safe.from_string c with
                  | `Assoc rf -> (
                      match List.assoc_opt "elements" rf with
                      | Some (`List l) -> elements := Some (List.filter_map (function `String h -> Some h | _ -> None) l)
                      | _ -> ())
                  | _ -> ()
                  | exception _ -> ())
              | _ -> ())
          | _ -> ()
          | exception _ -> ())
        r.messages;
      let events = List.rev !events in
      Some
        (match !elements with
        | None -> events
        | Some els ->
            let ordered = List.filter (fun h -> List.mem h events) els in
            ordered @ List.filter (fun h -> not (List.mem h ordered)) events)
  | Primal_api.Response.Notice n -> log "mega_feed_directive %s: %s" spec n; None
  | Primal_api.Response.Not_handled -> log "mega_feed_directive %s: not handled" spec; None

let record_usage (cfg : Config.t) (e : Nostr.t) ~(feed_id : string) : unit =
  let dbh = Postgres.connect ~application_name:"primal-jobs-dvm-provider" cfg.membership_db in
  Fun.protect ~finally:(fun () -> try Postgres.close dbh with _ -> ()) (fun () ->
      ignore
        (Postgres.query dbh "insert into dvm_usage values (decode($1,'hex'), $2::int8, decode($3,'hex'), $4) on conflict do nothing"
           [ Some (Nostr.id_hex e); Some (string_of_int e.Nostr.created_at); Some (Nostr.pubkey_hex e); Some feed_id ]))

let handle_request ~(cfg : Config.t) ~net ~clock ~ctx ~(keyed : keyed list) ~(base_relays : string list) (e : Nostr.t) : unit =
  if e.Nostr.kind = nip90_content_discovery_request && Nostr.verify e && first_sight e.Nostr.id then begin
    let user_pubkey = ref e.Nostr.pubkey and relays = ref base_relays and target = ref None in
    List.iter
      (fun tg ->
        match tg with
        | `String "param" :: `String "user" :: `String h :: _ -> ( match Hex_util.decode_opt h with Some pk when String.length pk = 32 -> user_pubkey := pk | _ -> ())
        | `String "relays" :: rest -> relays := !relays @ List.filter_map (function `String u -> Some u | _ -> None) rest
        | `String "p" :: `String h :: _ -> (
            match Hex_util.decode_opt h with
            | Some pk -> ( match List.find_opt (fun k -> k.pubkey = pk && k.f.state = Active) keyed with Some k -> target := Some k | None -> ())
            | None -> ())
        | _ -> ())
      e.Nostr.tags;
    match !target with
    | None -> ()
    | Some k -> (
        if not cfg.dvm_provider_dry_run then (try record_usage cfg e ~feed_id:k.f.id with x -> Fiber.check (); log "dvm_usage: %s" (Printexc.to_string x));
        match feed_event_ids ~ctx ~spec:k.f.spec ~user_pubkey:!user_pubkey with
        | None -> ()
        | Some ids ->
            let result =
              Nostr.create ~seckey:k.seckey ~created_at:(Utils.current_time ()) ~kind:nip90_content_discovery_result
                ~tags:[ tag [ "e"; Nostr.id_hex e ]; tag [ "p"; Nostr.pubkey_hex e ]; tag [ "request"; Nostr.to_string e ]; tag [ "status"; "success" ] ]
                ~content:(Yojson.Safe.to_string (`List (List.map (fun id -> `List [ s "e"; s id ]) ids)))
            in
            let relays = List.sort_uniq compare !relays in
            if cfg.dvm_provider_dry_run then
              log "dry run: %s for %s (user %s): %d ids, would send %s to %d relays: %s" k.f.id (Nostr.id_hex e) (Hex_util.encode !user_pubkey) (List.length ids)
                (Nostr.id_hex result) (List.length relays) result.Nostr.content
            else
              let rs = Relay_broadcast.broadcast ~net ~clock ?proxy:cfg.relay_proxy ~timeout:15.0 ~relays (Nostr.to_string result) in
              log "%s: request %s, %d ids, accepted by %d/%d relays" k.f.id (Nostr.id_hex e) (List.length ids) (Relay_broadcast.accepted_count rs) (List.length relays))
  end

(* one relay: connect, announce, subscribe, answer; reconnect after 10 s on any failure *)
let relay_loop ~(cfg : Config.t) ~net ~clock ~ctx ~(keyed : keyed list) ~(stop : unit Promise.t) (url : string) : unit =
  let announce = List.concat_map (announcements ~created_at:cfg.dvm_provider_announce_created_at ~relays:cfg.dvm_provider_relays) keyed in
  let active = List.filter (fun k -> k.f.state = Active) keyed in
  let sub =
    Yojson.Safe.to_string
      (`List [ s "REQ"; s "dvm-provider"; `Assoc [ ("limit", `Int 0); ("kinds", `List [ `Int nip90_content_discovery_request ]); ("#p", `List (List.map (fun k -> s (Hex_util.encode k.pubkey)) active)) ] ])
  in
  let session () =
    match Relay_broadcast.parse_relay_url url with
    | None -> log "%s: not a relay url" url; Promise.await stop
    | Some (tls, host, port, path) ->
        Switch.run @@ fun sw ->
        let ws = Eio.Time.with_timeout_exn clock 30.0 (fun () -> Ws_client.connect ~tls ?proxy:cfg.relay_proxy ~sw ~net ~clock ~host ~port ~path ()) in
        log "%s: connected" url;
        if not cfg.dvm_provider_dry_run then List.iter (fun ev -> Ws_client.send_text ws (Printf.sprintf "[\"EVENT\",%s]" (Nostr.to_string ev))) announce;
        Ws_client.send_text ws sub;
        (* plain blocking reads: cancelling a read (recv_timeout) leaves a TLS flow failed, so
           liveness is a watchdog instead: the subscription is re-sent every minute (the relay
           answers EOSE), and three silent minutes end the session *)
        let last = ref (Unix.gettimeofday ()) in
        let rec watchdog () =
          Eio.Time.sleep clock 60.0;
          if Unix.gettimeofday () -. !last > 180.0 then log "%s: silent for 3 min, reconnecting" url
          else begin
            Ws_client.send_text ws sub;
            watchdog ()
          end
        in
        let rec loop () =
          if not (Promise.is_resolved stop) then
            match Ws_client.recv ws with
            | `Closed -> log "%s: closed" url
            | `Msg m ->
                last := Unix.gettimeofday ();
                (match Yojson.Safe.from_string m with
                | `List [ `String "EVENT"; _; evj ] ->
                    Fiber.fork ~sw (fun () ->
                        try handle_request ~cfg ~net ~clock ~ctx ~keyed ~base_relays:cfg.dvm_provider_relays (Nostr.of_json evj)
                        with x ->
                          (* a Cancelled that leaks out of a callee while this fiber is not
                             cancelled is that request's failure, not a reason to drop the relay *)
                          Fiber.check ();
                          log "%s: request: %s" url (Printexc.to_string x))
                | `List (`String "OK" :: `String id :: `Bool false :: rest) ->
                    log "%s: announcement %s refused: %s" url id (match rest with `String r :: _ -> r | _ -> "")
                | `List [ `String "CLOSED"; _; `String why ] -> log "%s: subscription closed: %s" url why
                | _ -> ()
                | exception _ -> ());
                loop ()
        in
        Fiber.any [ loop; watchdog; (fun () -> Promise.await stop) ];
        (try Ws_client.close ws with _ -> ())
  in
  while not (Promise.is_resolved stop) do
    (try session () with x -> Fiber.check (); log "%s: %s" url (Printexc.to_string x));
    if not (Promise.is_resolved stop) then Fiber.first (fun () -> Eio.Time.sleep clock 10.0) (fun () -> Promise.await stop)
  done

let run ~(cfg : Config.t) ~net ~clock ~(stop : unit Promise.t) : unit =
  match cfg.dvm_provider_keypair_salt with
  | None -> log "no dvm_provider_keypair_salt: not started"
  | Some salt ->
      (match List.find_opt (fun f -> f.state = Active && f.verified_only) feeds with
      | Some f -> failwith ("dvm_provider: verified-only feed " ^ f.id ^ " is not supported")
      | None -> ());
      let keyed = List.map (keyed ~salt) feeds in
      List.iter
        (fun k ->
          let a = announcements ~created_at:cfg.dvm_provider_announce_created_at ~relays:cfg.dvm_provider_relays k in
          log "%s %s: pubkey %s, announcement %s" k.f.id (match k.f.state with Active -> "active" | Deleted -> "deleted") (Hex_util.encode k.pubkey)
            (String.concat " " (List.map (fun (e : Nostr.t) -> Printf.sprintf "%d:%s" e.kind (Nostr.id_hex e)) a)))
        keyed;
      let api_cfg = Primal_api.Config.of_json_file cfg.api_config_path in
      Api_context.init ~cfg ~net;
      let ctx = { Primal_api.Handlers.cfg = api_cfg; clock; conn_id = 0; subid = "dvm-provider" } in
      Fiber.List.iter (relay_loop ~cfg ~net ~clock ~ctx ~keyed ~stop) cfg.dvm_provider_relays
