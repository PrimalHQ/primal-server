(* Live-event push subscriptions, the port of ws-connector's live importer + distribution
   (ws-connector.rs distribute_live_event / _from_follows, primal-cache live_importer, ws-importer
   process_event_import). The table WRITES of ws-importer are done by the importer; here only the
   fan-out to subscribed clients remains:

   - sources: a 1 s poll of `event` by imported_at (10 000-id dedup ring) plus LISTEN primal_events
     (payload = an event JSON; today only the synthetic kind-11000001 moderation pokes);
   - every event carrying `a` tags is pushed to live_feed subscribers of those addresses;
   - a kind-30311 event is pushed to its own address's subscribers and, follows-based, to
     subscribed users who follow one of its participants (host or verified hosts);
   - per subscriber the SQL checks live_feed_is_hidden (+ the user's live mute list in "moderated"
     mode) decide; p-tag roles are lowercased (fixup) before sending.

   The registry is shared by all domains (connections register from their own domain, the
   distributor runs on the main domain) and stores each subscriber's send closure, which is the
   connection's domain-safe outbound queue. *)

open Eio.Std

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [live] %s\n%!" (Procinfo.timestamp ()) s) fmt

type sub_key = int * string (* conn_id, subid *)

type live_sub = { send : string -> unit; user_pubkey : string; mode : string }
type follows_sub = { fsend : string -> unit; fuser_pubkey : string }

type t = {
  lock : Mutex.t;
  live : (Response.eaddr, (sub_key, live_sub) Hashtbl.t) Hashtbl.t;
  follows : (string, (sub_key, follows_sub) Hashtbl.t) Hashtbl.t; (* user pubkey -> subs *)
  sub_live_key : (sub_key, Response.eaddr) Hashtbl.t;
  sub_follows_key : (sub_key, string) Hashtbl.t;
  conn_subs : (int, (string, unit) Hashtbl.t) Hashtbl.t;
}

let create () =
  { lock = Mutex.create (); live = Hashtbl.create 64; follows = Hashtbl.create 64; sub_live_key = Hashtbl.create 64;
    sub_follows_key = Hashtbl.create 64; conn_subs = Hashtbl.create 1024 }

let with_lock t f =
  Mutex.lock t.lock;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.lock) f

let note_sub t conn_id subid =
  let s = match Hashtbl.find_opt t.conn_subs conn_id with Some s -> s | None -> let s = Hashtbl.create 4 in Hashtbl.replace t.conn_subs conn_id s; s in
  Hashtbl.replace s subid ()

let register (t : t) ~conn_id ~subid ~(send : string -> unit) (r : Response.registration) : unit =
  with_lock t (fun () ->
      let key = (conn_id, subid) in
      match r with
      | Response.Live_events { eaddr; user_pubkey; content_moderation_mode } ->
          let subs = match Hashtbl.find_opt t.live eaddr with Some s -> s | None -> let s = Hashtbl.create 4 in Hashtbl.replace t.live eaddr s; s in
          Hashtbl.replace subs key { send; user_pubkey; mode = content_moderation_mode };
          Hashtbl.replace t.sub_live_key key eaddr;
          note_sub t conn_id subid
      | Response.Live_events_from_follows { user_pubkey } ->
          let subs = match Hashtbl.find_opt t.follows user_pubkey with Some s -> s | None -> let s = Hashtbl.create 4 in Hashtbl.replace t.follows user_pubkey s; s in
          Hashtbl.replace subs key { fsend = send; fuser_pubkey = user_pubkey };
          Hashtbl.replace t.sub_follows_key key user_pubkey;
          note_sub t conn_id subid
      | _ -> () (* the periodic broadcasters live in Broadcasts *))

let unregister_locked t (key : sub_key) =
  (match Hashtbl.find_opt t.sub_live_key key with
  | Some eaddr ->
      Hashtbl.remove t.sub_live_key key;
      (match Hashtbl.find_opt t.live eaddr with
      | Some subs ->
          Hashtbl.remove subs key;
          if Hashtbl.length subs = 0 then Hashtbl.remove t.live eaddr
      | None -> ())
  | None -> ());
  match Hashtbl.find_opt t.sub_follows_key key with
  | Some pk ->
      Hashtbl.remove t.sub_follows_key key;
      (match Hashtbl.find_opt t.follows pk with
      | Some subs ->
          Hashtbl.remove subs key;
          if Hashtbl.length subs = 0 then Hashtbl.remove t.follows pk
      | None -> ())
  | None -> ()

(* CLOSE of one subscription (ws-connector only dropped them on disconnect; the plan fixes that). *)
let unregister_sub (t : t) ~conn_id ~subid : unit =
  with_lock t (fun () ->
      unregister_locked t (conn_id, subid);
      match Hashtbl.find_opt t.conn_subs conn_id with Some s -> Hashtbl.remove s subid | None -> ())

let unregister_conn (t : t) ~conn_id : unit =
  with_lock t (fun () ->
      (match Hashtbl.find_opt t.conn_subs conn_id with
      | Some s -> Hashtbl.iter (fun subid () -> unregister_locked t (conn_id, subid)) s
      | None -> ());
      Hashtbl.remove t.conn_subs conn_id)

let stats (t : t) : int * int * int =
  with_lock t (fun () -> (Hashtbl.length t.live, Hashtbl.length t.follows, Hashtbl.length t.conn_subs))

(* {1 Event parsing} *)

type parsed = {
  id : string option; (* raw bytes when the id is a 64-hex id *)
  kind : int;
  pubkey_hex : string;
  pubkey : string option;
  tags : Yojson.Safe.t list list;
  json : string; (* as received, p-tag roles fixed up for 30311 *)
}

let parse (s : string) : parsed option =
  match Yojson.Safe.from_string s with
  | `Assoc f ->
      let str k = match List.assoc_opt k f with Some (`String v) -> Some v | _ -> None in
      let kind = match List.assoc_opt "kind" f with Some (`Int k) -> k | _ -> -1 in
      let tags =
        match List.assoc_opt "tags" f with
        | Some (`List l) -> List.filter_map (function `List t -> Some t | _ -> None) l
        | _ -> []
      in
      let pubkey_hex = Option.value (str "pubkey") ~default:"" in
      let id = match str "id" with Some h when String.length h = 64 -> Hex_util.decode_opt h | _ -> None in
      let pubkey = if String.length pubkey_hex = 64 then Hex_util.decode_opt pubkey_hex else None in
      Some { id; kind; pubkey_hex; pubkey; tags; json = Handlers.fixup_live_event_p_tags s }
  | _ -> None
  | exception _ -> None

let tag_str (t : Yojson.Safe.t list) i = match List.nth_opt t i with Some (`String s) -> Some s | _ -> None

(* "kind:pubkey:identifier" -> eaddr *)
let eaddr_of_string (s : string) : Response.eaddr option =
  match String.split_on_char ':' s with
  | kind :: pk :: rest -> (
      match (int_of_string_opt kind, if String.length pk = 64 then Hex_util.decode_opt pk else None) with
      | Some kind, Some pubkey -> Some { Response.kind; pubkey; identifier = String.concat ":" rest }
      | _ -> None)
  | _ -> None

(* primal-cache verify_participant_proof: BIP340 over sha256("kind:host_pubkey_hex:identifier"). *)
let verify_participant_proof ~participant ~proof_hex ~kind ~event_pubkey_hex ~identifier : bool =
  match Hex_util.decode_opt proof_hex with
  | Some proof when String.length proof = 64 ->
      let msg = Printf.sprintf "%d:%s:%s" kind event_pubkey_hex identifier in
      let msg_hash = Digestif.SHA256.(to_raw_string (digest_string msg)) in
      Secp256k1.verify ~msg_hash ~serialized_pubkey:participant ~signature:proof
  | _ -> false

(* Hosts of a kind-30311 event (proof-verified when a proof is present), plus its identifier. *)
let live_event_hosts (p : parsed) : (string * string list) option =
  let identifier = List.find_map (fun t -> if tag_str t 0 = Some "d" then tag_str t 1 else None) p.tags in
  match identifier with
  | None -> None
  | Some identifier ->
      let hosts =
        List.filter_map
          (fun t ->
            if tag_str t 0 = Some "p" then
              match Option.bind (tag_str t 1) (fun h -> if String.length h = 64 then Hex_util.decode_opt h else None) with
              | Some pk ->
                  let is_host = match tag_str t 3 with Some r -> String.lowercase_ascii r = "host" | None -> false in
                  let ok =
                    match tag_str t 4 with
                    | Some proof_hex -> verify_participant_proof ~participant:pk ~proof_hex ~kind:p.kind ~event_pubkey_hex:p.pubkey_hex ~identifier
                    | None -> true
                  in
                  if is_host && ok then Some pk else None
              | None -> None
            else None)
          p.tags
      in
      Some (identifier, hosts)

(* {1 Distribution} (runs on the main domain with its own pools) *)

let distribute_live_event (t : t) ~clock (eaddr : Response.eaddr) (p : parsed) : unit =
  let subs = with_lock t (fun () -> match Hashtbl.find_opt t.live eaddr with Some s -> Hashtbl.fold (fun k v acc -> (k, v) :: acc) s [] | None -> []) in
  if subs <> [] then begin
    let sent = ref [] in
    List.iter
      (fun ((_, subid), (s : live_sub)) ->
        let hidden =
          match p.id with
          | None -> false
          | Some event_id ->
              Db.with_cache ~clock (fun c ->
                  Queries.live_feed_is_hidden c ~event_id ~user_pubkey:s.user_pubkey ~content_moderation_mode:s.mode
                    ~kind:eaddr.kind ~pubkey:eaddr.pubkey ~identifier:eaddr.identifier
                  || (s.mode = "moderated"
                     && Queries.live_hosts_blocked_by_user c ~user_pubkey:s.user_pubkey ~kind:eaddr.kind ~pubkey:eaddr.pubkey
                          ~identifier:eaddr.identifier))
        in
        if not hidden then begin
          s.send (Protocol.event subid p.json);
          sent := subid :: !sent
        end)
      subs;
    if !sent <> [] then
      log "sent live event kind %d %s to %d sub(s) of %d:%s:%s" p.kind
        (Option.value (Option.map Hex_util.encode p.id) ~default:"?") (List.length !sent) eaddr.kind
        (Hex_util.encode eaddr.pubkey) eaddr.identifier
  end

let distribute_from_follows (t : t) ~(user_pubkey : string) (p : parsed) : unit =
  let subs = with_lock t (fun () -> match Hashtbl.find_opt t.follows user_pubkey with Some s -> Hashtbl.fold (fun k v acc -> (k, v) :: acc) s [] | None -> []) in
  List.iter (fun ((_, subid), (s : follows_sub)) -> s.fsend (Protocol.event subid p.json)) subs

let handle_event (t : t) ~clock (p : parsed) : unit =
  (* any event addressing live events via `a` tags (chat, zaps, reactions, ...) *)
  List.iter
    (fun tag ->
      if tag_str tag 0 = Some "a" then
        match Option.bind (tag_str tag 1) eaddr_of_string with
        | Some eaddr -> distribute_live_event t ~clock eaddr p
        | None -> ())
    p.tags;
  if p.kind = Nostr.kind_live_event then
    match (p.pubkey, live_event_hosts p) with
    | Some pubkey, Some (identifier, hosts) ->
        distribute_live_event t ~clock { Response.kind = p.kind; pubkey; identifier } p;
        let users = with_lock t (fun () -> Hashtbl.fold (fun pk _ acc -> pk :: acc) t.follows []) in
        if users <> [] then begin
          let hexes l = Yojson.Safe.to_string (`List (List.map (fun x -> `String (Hex_util.encode x)) l)) in
          let followers =
            Db.with_cache ~clock (fun c ->
                Queries.followers_of_participants c ~users_json:(hexes users) ~participants_json:(hexes (pubkey :: hosts)))
          in
          List.iter (fun user_pubkey -> distribute_from_follows t ~user_pubkey p) followers
        end
    | _ -> ()

(* Fixed-capacity seen-set (primal-cache recent_items.rs). *)
module Ring = struct
  type t = { cap : int; q : string Queue.t; set : (string, unit) Hashtbl.t }
  let create cap = { cap; q = Queue.create (); set = Hashtbl.create cap }
  (* true when new *)
  let push t id =
    if Hashtbl.mem t.set id then false
    else begin
      Hashtbl.replace t.set id ();
      Queue.add id t.q;
      if Queue.length t.q > t.cap then Hashtbl.remove t.set (Queue.pop t.q);
      true
    end
end

(* The 1 s poll of newly imported events (primal-cache live_importer). *)
let poll_loop (t : t) ~clock ~(stats : Stats.t) : unit =
  let ring = Ring.create 10_000 in
  let since = ref (Utils.current_time ()) in
  while true do
    let until = Utils.current_time () in
    (try
       let rows = Db.with_cache ~clock (fun c -> Queries.events_imported_between c ~since:!since ~until) in
       List.iter
         (fun json ->
           match parse json with
           | Some p when (match p.id with Some id -> Ring.push ring id | None -> true) ->
               Stats.incr stats.live_events;
               (try handle_event t ~clock p with
               | Eio.Cancel.Cancelled _ as e -> raise e
               | exn -> log "distribute: %s" (Printexc.to_string exn))
           | _ -> ())
         rows;
       since := until
     with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> log "poll: %s" (Printexc.to_string exn));
    Eio.Time.sleep clock 1.0
  done

(* LISTEN primal_events: payloads are event JSON (the importer's kind-11000001 pokes). *)
let listen_loop (t : t) ~net ~clock ~(stats : Stats.t) (ci : Postgres.conninfo) : unit =
  Pg_listen.run ~net ~clock ci ~channels:[ "primal_events" ] ~on_notify:(fun ~channel:_ ~payload ->
      match parse payload with
      | Some p ->
          Stats.incr stats.live_events;
          (try handle_event t ~clock p with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn -> log "notify distribute: %s" (Printexc.to_string exn))
      | None -> log "notify: unparsable payload (%d bytes)" (String.length payload))

let run (t : t) ~net ~clock ~stats (ci : Postgres.conninfo) : unit =
  Fiber.both (fun () -> poll_loop t ~clock ~stats) (fun () -> listen_loop t ~net ~clock ~stats ci)
