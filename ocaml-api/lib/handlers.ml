(* The natively handled funcalls — port of ws-connector/src/handlers/handlers.rs (the 17 funcalls the
   Rust ws-handlers answered without the Julia backend). Behaviour, defaults and NOTICE texts are kept
   identical; what ws-connector did not handle is [Not_handled] and goes to the upstream.

   Every handler is total over its kwargs: malformed arguments raise [Kw.Invalid], which the
   dispatcher maps to [Not_handled] exactly as ws-handlers' error responses were treated. *)

open Response

type ctx = {
  cfg : Config.t;
  clock : float Eio.Time.clock_ty Eio.Std.r;
  conn_id : int;
  subid : string;
}

let now () = Utils.current_time ()

(* Rust: if let Some(v) = kwargs["user_pubkey"].as_str() { hex::decode(v).ok() } else { primal } *)
let user_pubkey_or_primal (ctx : ctx) (kw : Kw.t) : string option =
  match Kw.str_opt kw "user_pubkey" with
  | Some v -> Hex_util.decode_opt v
  | None -> Some ctx.cfg.primal_pubkey

(* Rust: kwargs["user_pubkey"].as_str().and_then(decode.ok).or(primal) *)
let user_pubkey_or_primal_2 (ctx : ctx) (kw : Kw.t) : string option =
  match Kw.hex_any_opt kw "user_pubkey" with Some p -> Some p | None -> Some ctx.cfg.primal_pubkey

(* serde_json serializes maps with sorted keys; mirror that where ws-connector built JSON itself. *)
let rec sorted_json (j : Yojson.Safe.t) : Yojson.Safe.t =
  match j with
  | `Assoc f -> `Assoc (List.sort (fun (a, _) (b, _) -> compare a b) (List.map (fun (k, v) -> (k, sorted_json v)) f))
  | `List l -> `List (List.map sorted_json l)
  | v -> v

let json_text (j : Yojson.Safe.t) : string = Yojson.Safe.to_string (sorted_json j)

(* ws-connector fixup_live_event_p_tags_str: lowercase the role (4th field) of p tags of kind-30311
   events; other messages pass through untouched. Re-serialized with sorted keys like serde. *)
let fixup_live_event_p_tags (s : string) : string =
  match Yojson.Safe.from_string s with
  | `Assoc fields as e -> (
      match (List.assoc_opt "kind" fields, List.assoc_opt "tags" fields) with
      | Some (`Int 30311), Some (`List tags) ->
          let newtags =
            List.map
              (function
                | `List (`String "p" :: pk :: relay :: `String role :: rest) ->
                    `List (`String "p" :: pk :: relay :: `String (String.lowercase_ascii role) :: rest)
                | t -> t)
              tags
          in
          json_text (`Assoc (List.map (fun (k, v) -> if k = "tags" then (k, `List newtags) else (k, v)) fields))
      | _ -> ignore e; s)
  | _ -> s
  | exception _ -> s

let with_cache (ctx : ctx) f = Db.with_cache ~clock:ctx.clock f
let with_membership (ctx : ctx) f = Db.with_membership ~clock:ctx.clock f

(* {1 Handlers} *)

let thread_view (ctx : ctx) (kw : Kw.t) : outcome =
  let event_id = Kw.hex_any_opt kw "event_id" |> Option.get in
  let limit = Kw.int kw "limit" ~default:20 and since = Kw.int kw "since" ~default:0 in
  let until = Kw.int kw "until" ~default:(now ()) and offset = Kw.int kw "offset" ~default:0 in
  let user_pubkey = user_pubkey_or_primal ctx kw in
  Handled
    (messages
       (with_cache ctx (fun c ->
            Queries.thread_view c ~event_id ~limit ~since ~until ~offset ~user_pubkey ~apply_humaness_check:true)))

let multi_kind_thread_view (ctx : ctx) (kw : Kw.t) : outcome =
  let event_id = Kw.hex_any_opt kw "event_id" |> Option.get in
  let limit = Kw.int kw "limit" ~default:20 and since = Kw.int kw "since" ~default:0 in
  let until = Kw.int kw "until" ~default:(now ()) and offset = Kw.int kw "offset" ~default:0 in
  let user_pubkey = user_pubkey_or_primal ctx kw in
  let kinds = Option.value (Kw.int_list_opt kw "kinds") ~default:[ 1 ] in
  let include_parent_posts = Kw.bool kw "include_parent_posts" ~default:true in
  Handled
    (messages
       (with_cache ctx (fun c ->
            Queries.multi_kind_thread_view c ~event_id ~kinds ~limit ~since ~until ~offset ~user_pubkey
              ~apply_humaness_check:true ~include_parent_posts)))

let scored (ctx : ctx) (kw : Kw.t) : outcome =
  let selector = Kw.str_exn kw "selector" in
  let user_pubkey = user_pubkey_or_primal ctx kw in
  let key = "precalculated_analytics_" ^ selector in
  Handled (messages (with_cache ctx (fun c -> Queries.scored c ~key ~user_pubkey)))

let get_default_app_settings (ctx : ctx) (kw : Kw.t) : outcome =
  let client = Kw.str_exn kw "client" in
  let content = Files.read (Filename.concat ctx.cfg.content_moderation_root "default-settings.json") in
  Handled
    (messages
       [
         json_text
           (`Assoc
             [ ("kind", `Int Kind.primal_settings); ("tags", `List [ `List [ `String "d"; `String client ] ]);
               ("content", `String content) ]);
       ])

let get_app_releases (ctx : ctx) (_kw : Kw.t) : outcome =
  let content = Files.read (Filename.concat ctx.cfg.content_moderation_root "app-releases.json") in
  Handled (messages [ json_text (`Assoc [ ("kind", `Int Kind.app_releases); ("content", `String content) ]) ])

let get_bookmarks (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex_any_opt kw "pubkey" |> Option.get in
  Handled (messages (with_cache ctx (fun c -> Queries.get_bookmarks c ~pubkey)))

let user_infos (ctx : ctx) (kw : Kw.t) : outcome =
  match Kw.member kw "pubkeys" with
  | `List pubkeys ->
      let rec collect acc = function
        | [] -> Ok (List.rev acc)
        | `String pk :: rest ->
            if String.length pk <> 64 || Hex_util.decode_opt pk = None then Error "invalid pubkey"
            else collect (pk :: acc) rest
        | _ :: rest -> collect acc rest
      in
      (match collect [] pubkeys with
      | Error n -> Notice n
      | Ok pks ->
          let pubkeys_json = Yojson.Safe.to_string (`List (List.map (fun p -> `String p) pks)) in
          Handled (messages (with_cache ctx (fun c -> Queries.user_infos c ~pubkeys_json))))
  | _ -> Not_handled

let server_name (ctx : ctx) (_kw : Kw.t) : outcome =
  Handled (messages [ json_text (`Assoc [ ("content", `String ctx.cfg.servername) ]) ])

let get_notifications_seen (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex_any_opt kw "pubkey" |> Option.get in
  match with_membership ctx (fun c -> Queries_mem.notifications_seen_until c ~pubkey) with
  | None -> Notice "unknown user"
  | Some t ->
      Handled
        (messages
           [
             json_text
               (`Assoc [ ("kind", `Int Kind.notifications_seen_until); ("content", `String (Int64.to_string t)) ]);
           ])

let rec feed (ctx : ctx) (kw : Kw.t) : outcome = feed_with ~user_pubkey:(user_pubkey_or_primal ctx kw) ctx kw

(* [user_pubkey] as resolved by the caller: ws-connector's primal default for `feed`, Julia's
   castmaybe (absent -> null) for feed_directive *)
and feed_with ~(user_pubkey : string option) (ctx : ctx) (kw : Kw.t) : outcome =
  let limit = Kw.int kw "limit" ~default:20 and since = Kw.int kw "since" ~default:0 in
  let until = Kw.int kw "until" ~default:(now ()) and offset = Kw.int kw "offset" ~default:0 in
  let pubkey = Kw.hex_any_opt kw "pubkey" |> Option.get in
  let notes = Kw.str kw "notes" ~default:"follows" in
  let include_replies = if Kw.bool kw "include_replies" ~default:false then 1 else 0 in
  let kinds = Option.value (Kw.int_list_opt kw "kinds") ~default:[ 1; 6 ] in
  match notes with
  | "follows" ->
      with_cache ctx (fun c ->
          if Queries.has_followers_row c ~pubkey then
            Handled
              (messages
                 (Queries.feed_user_follows c ~pubkey ~since ~until ~include_replies ~limit ~offset ~user_pubkey
                    ~apply_humaness_check:true ~kinds))
          else Not_handled)
  | "authored" ->
      Handled
        (messages
           (with_cache ctx (fun c ->
                Queries.feed_user_authored c ~pubkey ~since ~until ~include_replies ~limit ~offset ~user_pubkey
                  ~apply_humaness_check:false ~kinds)))
  | "replies" ->
      Handled
        (messages
           (with_cache ctx (fun c ->
                Queries.feed_user_authored c ~pubkey ~since ~until ~include_replies:1 ~limit ~offset ~user_pubkey
                  ~apply_humaness_check:false ~kinds)))
  | _ -> Not_handled

let long_form_content_feed (ctx : ctx) (kw : Kw.t) : outcome =
  let limit = Kw.int kw "limit" ~default:20 and since = Kw.int kw "since" ~default:0 in
  let until = Kw.int kw "until" ~default:(now ()) and offset = Kw.int kw "offset" ~default:0 in
  let pubkey = Kw.hex_any_opt kw "pubkey" in
  let user_pubkey = user_pubkey_or_primal_2 ctx kw in
  let notes = Kw.str_opt kw "notes" and topic = Kw.str_opt kw "topic" and curation = Kw.str_opt kw "curation" in
  let minwords = Kw.int kw "minwords" ~default:0 in
  Handled
    (messages
       (with_cache ctx (fun c ->
            Queries.long_form_content_feed c ~pubkey ~notes ~topic ~curation ~minwords ~limit ~since ~until ~offset
              ~user_pubkey ~apply_humaness_check:true)))

(* The spec JSON of mega_feed_directive, with string accessors defaulting to "". *)
let parse_spec (kw : Kw.t) : [ `Spec of Yojson.Safe.t * Kw.t | `Invalid | `Missing ] =
  match Kw.str_opt kw "spec" with
  | None -> `Missing
  | Some spec -> (
      match Yojson.Safe.from_string spec with
      | `Assoc _ as s -> `Spec (s, Kw.remove kw "spec")
      | _ -> `Invalid
      | exception _ -> `Invalid)

let mega_feed_directive (ctx : ctx) (kw : Kw.t) : outcome =
  match parse_spec kw with
  | `Missing -> Not_handled
  | `Invalid -> Notice "invalid spec format"
  | `Spec (s, kwargs) ->
      let sg k = Kw.str s k ~default:"" in
      let skwa = Kw.fields (Kw.remove (Kw.remove s "id") "kind") in
      let require_user_pubkey () =
        match Kw.member kwargs "user_pubkey" with `Null -> raise (Kw.Invalid "user_pubkey argument required") | v -> v
      in
      if sg "id" = "nostr-reads-feed" then Not_handled
      else if sg "kind" = "reads" || sg "id" = "reads-feed" then begin
        let minwords = `Int (Kw.int s "minwords" ~default:100) in
        if sg "scope" = "follows" then Not_handled
        else if sg "scope" = "zappedbyfollows" then
          let kwa = Kw.set (Kw.set (Kw.set kwargs "minwords" minwords) "pubkey" (require_user_pubkey ())) "notes" (`String "zappedbyfollows") in
          long_form_content_feed ctx kwa
        else if sg "scope" = "myfollowsinteractions" then Not_handled
        else
          match (Kw.member s "topic", Kw.member s "pubkey", Kw.member s "curation") with
          | (`Null, _, _) when false -> Not_handled
          | topic, _, _ when topic <> `Null ->
              long_form_content_feed ctx (Kw.set (Kw.set kwargs "minwords" minwords) "topic" topic)
          | _, pubkey, curation when pubkey <> `Null && curation <> `Null ->
              long_form_content_feed ctx
                (Kw.set (Kw.set (Kw.set kwargs "minwords" minwords) "pubkey" pubkey) "curation" curation)
          | _ -> long_form_content_feed ctx (Kw.merge (Kw.set kwargs "minwords" minwords) skwa)
      end
      else if sg "kind" = "notes" then begin
        if sg "id" = "latest" then
          feed ctx (Kw.merge (Kw.set kwargs "pubkey" (require_user_pubkey ())) skwa)
        else if sg "id" = "feed" then feed ctx (Kw.merge kwargs skwa)
        else Not_handled
      end
      else Not_handled

let multi_kind_mega_feed_directive (ctx : ctx) (kw : Kw.t) : outcome =
  match parse_spec kw with
  | `Missing -> Not_handled
  | `Invalid -> Notice "invalid spec format"
  | `Spec (s, kwargs) ->
      let kinds = match Kw.member kwargs "kinds" with `Null -> Kw.member s "kinds" | k -> k in
      if kinds = `Null then mega_feed_directive ctx kw
      else begin
        let id = Kw.str s "id" ~default:"" in
        let spec_fields = Kw.fields (Kw.remove (Kw.remove s "id") "kind") in
        if id = "latest" then
          let kwa = Kw.merge kwargs spec_fields in
          let user_pubkey =
            match Kw.member kwa "user_pubkey" with `Null -> raise (Kw.Invalid "user_pubkey argument required") | v -> v
          in
          feed ctx (Kw.set (Kw.set kwa "pubkey" user_pubkey) "kinds" kinds)
        else if id = "feed" then feed ctx (Kw.set (Kw.merge kwargs spec_fields) "kinds" kinds)
        else Not_handled
      end

let live_feed (ctx : ctx) (kw : Kw.t) : outcome =
  let kind = Kw.int_exn kw "kind" in
  let pubkey = Kw.hex_any_opt kw "pubkey" |> Option.get in
  let identifier = Kw.str_exn kw "identifier" in
  let user_pubkey = Kw.hex_any_opt kw "user_pubkey" |> Option.get in
  let content_moderation_mode = Kw.str kw "content_moderation_mode" ~default:"all" in
  let msgs =
    with_cache ctx (fun c ->
        Queries.live_feed_initial_response c ~kind ~pubkey ~identifier ~user_pubkey ~content_moderation_mode)
    |> List.map fixup_live_event_p_tags
  in
  Handled
    {
      messages = msgs;
      registrations = [ Live_events { eaddr = { kind; pubkey; identifier }; user_pubkey; content_moderation_mode } ];
    }

let live_events_from_follows (ctx : ctx) (kw : Kw.t) : outcome =
  let user_pubkey = Kw.hex_any_opt kw "user_pubkey" |> Option.get in
  let msgs =
    with_cache ctx (fun c -> Queries.live_events_from_follows c ~user_pubkey) |> List.map fixup_live_event_p_tags
  in
  Handled { messages = msgs; registrations = [ Live_events_from_follows { user_pubkey } ] }

let find_live_events (ctx : ctx) (kw : Kw.t) : outcome =
  let host_pubkey = Kw.hex_any_opt kw "host_pubkey" |> Option.get in
  let identifier = Kw.str_opt kw "identifier" in
  let msgs =
    with_cache ctx (fun c -> Queries.find_live_events c ~host_pubkey ~identifier) |> List.map fixup_live_event_p_tags
  in
  Handled (messages msgs)

let events (ctx : ctx) (kw : Kw.t) : outcome =
  if not (Kw.bool kw "extended_response" ~default:false) then Not_handled
  else
    match Kw.member kw "event_ids" with
    | `List (_ :: _ as ids) ->
        let hex_ids =
          List.filter_map
            (function `String s when String.length s = 64 && Hex_util.decode_opt s <> None -> Some s | _ -> None)
            ids
        in
        if hex_ids = [] then Not_handled
        else
          let user_pubkey = user_pubkey_or_primal ctx kw in
          let event_ids_json = Yojson.Safe.to_string (`List (List.map (fun s -> `String s) hex_ids)) in
          Handled
            (messages
               (with_cache ctx (fun c ->
                    Queries.enrich_events c ~event_ids_json ~user_pubkey ~apply_humaness_check:true ~orderby:"created_at")))
    | _ -> Not_handled

(* {1 Phase 3b: the Julia-era funcalls} — ported from app.jl / app_ext.jl. Argument handling follows
   Julia: a missing required kwarg or an invalid id raises (-> Not_handled, the upstream answers with
   Julia's own NOTICE). Every error Julia raises itself reaches the client as NOTICE "error"
   (CacheServerHandlers: the TaskFailedException is not unwrapped), so that is what [julia_error] is. *)

let () = Random.self_init ()
let julia_error : outcome = Notice "error"

(* Julia castmaybe(user_pubkey, PubKeyId): absent -> none; present but invalid -> error *)
let user_pubkey_opt (kw : Kw.t) : string option =
  match Kw.member kw "user_pubkey" with
  | `Null -> None
  | `String _ -> ( match Kw.hex32_opt kw "user_pubkey" with Some p -> Some p | None -> raise (Kw.Invalid "invalid user_pubkey"))
  | _ -> raise (Kw.Invalid "invalid user_pubkey")

let hex32_list_exn (kw : Kw.t) name : string list =
  match Kw.member kw name with
  | `List l ->
      List.map
        (function
          | `String s when String.length s = 64 -> (
              match Hex_util.decode_opt s with Some b -> b | None -> raise (Kw.Invalid ("invalid " ^ name)))
          | _ -> raise (Kw.Invalid ("invalid " ^ name)))
        l
  | _ -> raise (Kw.Invalid ("invalid " ^ name))

(* Julia NamedTuple (; kind, content) order *)
let content_msg kind (content : string) : string =
  Yojson.Safe.to_string (`Assoc [ ("kind", `Int kind); ("content", `String content) ])

(* Julia JSON.json(try JSON.parse(read(file)) catch _; default end) *)
let file_json_content (path : string) ~(default : string) : string =
  match Files.read_opt path with
  | None -> default
  | Some s -> ( try Yojson.Safe.to_string (Yojson.Safe.from_string s) with _ -> default)

let cm_file (ctx : ctx) name = Filename.concat ctx.cfg.content_moderation_root name

(* Julia parse_event_from_user: a signed event supplied by the client *)
let event_from_user (kw : Kw.t) : (Nostr.t, string) result =
  match Kw.member kw "event_from_user" with
  | `Assoc _ as j -> (
      match Nostr.of_json j with
      | exception _ -> raise (Kw.Invalid "invalid event_from_user")
      | e ->
          if e.Nostr.created_at >= now () + 300 then Error "event from the future"
          else if not (Nostr.verify e) then Error "verification failed"
          else Ok e)
  | _ -> raise (Kw.Invalid "event_from_user required")

let i64json (v : int64) : Yojson.Safe.t = `Int (Int64.to_int v)

(* kind USER_SCORES / USER_FOLLOWER_COUNTS: {hex: followers_count}; [always] = emit even when empty *)
let counts_msg ?(always = false) kind (counts : (string * int64) list) : string list =
  if counts = [] && not always then []
  else [ content_msg kind (Yojson.Safe.to_string (`Assoc (List.map (fun (k, v) -> (k, i64json v)) counts))) ]

(* Julia primal_verified_names(est, pubkeys) = SQL primal_verified_names + user_blossom_servers *)
let verified_names (c : Db.cache Db.conn) (hexes : string list) : string list =
  if hexes = [] then []
  else
    let pubkeys_json = Queries.hexes_json hexes in
    Queries.primal_verified_names c ~pubkeys_json @ Queries.user_blossom_servers c ~pubkeys_json

let follower_counts (c : Db.cache Db.conn) (hexes : string list) : (string * int64) list =
  if hexes = [] then [] else Queries.follower_counts c ~pubkeys_json:(Queries.hexes_json hexes)

(* Julia's in-memory event_media_response omits "mt" when a resource has no variants; the SQL
   event_media_response emits "mt": null. Strip it where Julia answers from memory. *)
let strip_null_mt (m : string) : string =
  match Yojson.Safe.from_string m with
  | `Assoc f when List.assoc_opt "kind" f = Some (`Int Kind.media_metadata) -> (
      match List.assoc_opt "content" f with
      | Some (`String content) -> (
          match Yojson.Safe.from_string content with
          | `Assoc cf -> (
              match List.assoc_opt "resources" cf with
              | Some (`List rs) ->
                  let rs =
                    List.map
                      (function `Assoc r -> `Assoc (List.filter (fun (k, v) -> not (k = "mt" && v = `Null)) r) | r -> r)
                      rs
                  in
                  let cf = List.map (fun (k, v) -> if k = "resources" then (k, `List rs) else (k, v)) cf in
                  Yojson.Safe.to_string
                    (`Assoc (List.map (fun (k, v) -> if k = "content" then (k, `String (Yojson.Safe.to_string (`Assoc cf))) else (k, v)) f))
              | _ -> m)
          | _ -> m
          | exception _ -> m)
      | _ -> m)
  | _ -> m
  | exception _ -> m

(* metadata event + ext_event_response(md) (media, preview) per pubkey, in the order given.
   Returns the pubkeys that had a metadata event. *)
let user_cards (c : Db.cache Db.conn) (hexes : string list) : string list * string list =
  if hexes = [] then ([], [])
  else begin
    let pubkeys_json = Queries.hexes_json hexes in
    let mds = Queries.metadata_events c ~pubkeys_json in
    let extras = Queries.metadata_extras c ~pubkeys_json in
    let found = ref [] and msgs = ref [] in
    List.iter
      (fun h ->
        match List.assoc_opt h mds with
        | Some md ->
            found := h :: !found;
            msgs := md :: !msgs;
            List.iter (fun (k, e) -> if k = h then msgs := strip_null_mt e :: !msgs) extras
        | None -> ())
      hexes;
    (List.rev !found, List.rev !msgs)
  end

let kind_and_pubkey (m : string) : (int option * string option) =
  match Yojson.Safe.from_string m with
  | `Assoc f ->
      ( (match List.assoc_opt "kind" f with Some (`Int k) -> Some k | _ -> None),
        match List.assoc_opt "pubkey" f with Some (`String p) -> Some p | _ -> None )
  | _ -> (None, None)
  | exception _ -> (None, None)

(* {2 users} *)

(* Julia sort(collect(Set(tags))): tags as string lists, lexicographic *)
let normalize_relays_msg (s : string) : string =
  match Yojson.Safe.from_string s with
  | `Assoc f -> (
      match (List.assoc_opt "kind" f, List.assoc_opt "pubkey" f, List.assoc_opt "tags" f) with
      | Some kind, Some pk, Some (`List tags) ->
          let tags = List.sort_uniq compare tags in
          Yojson.Safe.to_string (`Assoc [ ("kind", kind); ("pubkey", pk); ("tags", `List tags) ])
      | _ -> s)
  | _ -> s
  | exception _ -> s

let relays_of (c : Db.cache Db.conn) ~pubkey : string list = Queries.get_user_relays c ~pubkey |> List.map normalize_relays_msg

let user_profile (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" in
  let user_pubkey = user_pubkey_opt kw in
  with_cache ctx (fun c ->
      if Queries.is_user_blocked c ~pubkey then Handled empty
      else begin
        let pk_hex = Hex_util.encode pubkey in
        let pk_json = Queries.hexes_json [ pk_hex ] in
        (* content_moderation_filtering_2 appends search_filterlist for a hidden profile: not native yet *)
        let hidden =
          match user_pubkey with
          | Some _ -> not (Moderation.SS.is_empty (Moderation.hidden_pubkeys ~clock:ctx.clock c ~user_pubkey ~scope:"content" ~hexes:[ pk_hex ] ~author_exempt:None))
          | None -> false
        in
        if hidden then Not_handled
        else begin
          let md = Queries.metadata_event c ~pubkey in
          let n = Queries.user_profile_counts c ~pubkey in
          let relay_count =
            match List.rev (relays_of c ~pubkey) with
            | last :: _ -> (
                match Yojson.Safe.from_string last with
                | `Assoc f -> (
                    match List.assoc_opt "tags" f with
                    | Some (`List tags) ->
                        List.filter_map (function `List (_ :: url :: _) -> Some url | _ -> None) tags
                        |> List.sort_uniq compare |> List.length
                    | _ -> 0)
                | _ -> 0
                | exception _ -> 0)
            | [] -> 0
          in
          let stats =
            content_msg Kind.user_profile
              (Yojson.Safe.to_string
                 (`Assoc
                   [
                     ("pubkey", `String pk_hex);
                     ("follows_count", i64json n.follows_count);
                     ("followers_count", i64json n.followers_count);
                     ("note_count", i64json n.note_count);
                     ("long_form_note_count", i64json n.long_form_note_count);
                     ("reply_count", i64json n.reply_count);
                     ("time_joined", match n.time_joined with Some t -> i64json t | None -> `Null);
                     ("relay_count", `Int relay_count);
                     ("total_zap_count", i64json n.total_zap_count);
                     ("total_satszapped", i64json n.total_satszapped);
                     ("media_count", i64json n.media_count);
                     ("content_zap_count", i64json n.content_zap_count);
                   ]))
          in
          let media =
            match md with
            | Some m -> (
                match Yojson.Safe.from_string m with
                | `Assoc f -> (
                    match List.assoc_opt "id" f with
                    | Some (`String id) -> (
                        match Hex_util.decode_opt id with
                        | Some event_id -> List.map strip_null_mt (Queries.event_media_response c ~event_id)
                        | None -> [])
                    | _ -> [])
                | _ -> []
                | exception _ -> [])
            | None -> []
          in
          let live = Queries.user_live_events c ~pubkeys_json:pk_json in
          Handled (messages (Option.to_list md @ [ stats ] @ media @ verified_names c [ pk_hex ] @ live))
        end
      end)

let user_profile_followed_by (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" and user_pubkey = Kw.hex32_exn kw "user_pubkey" in
  let limit = min 20 (Kw.int kw "limit" ~default:10) in
  with_cache ctx (fun c ->
      let hexes = Queries.user_profile_followed_by_pubkeys c ~pubkey ~user_pubkey ~limit |> List.map Hex_util.encode in
      let found, cards = user_cards c hexes in
      Handled (messages (cards @ counts_msg Kind.user_scores (follower_counts c found) @ verified_names c found)))

(* app.jl contact_list: the list event + user_infos(follows) from memory. The SQL contact_list
   builds the same answer through the SQL user_infos; the three places where Julia's in-memory
   user_infos_1 differs are patched here: USER_SCORES counts every pubkey with a metadata event
   (zeros included), USER_FOLLOWER_COUNTS counts every followed pubkey, media has no "mt": null. *)
let contact_list (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" in
  let extended_response = Kw.bool kw "extended_response" ~default:true in
  with_cache ctx (fun c ->
      let msgs = Queries.contact_list c ~pubkey ~extended_response in
      if not extended_response then Handled (messages msgs)
      else begin
        let follows =
          match msgs with
          | first :: _ -> (
              match Yojson.Safe.from_string first with
              | `Assoc f -> (
                  match List.assoc_opt "tags" f with
                  | Some (`List tags) ->
                      List.filter_map
                        (function
                          | `List (`String "p" :: `String pk :: _) when String.length pk = 64 && Hex_util.decode_opt pk <> None ->
                              Some (String.lowercase_ascii pk)
                          | _ -> None)
                        tags
                      |> List.filteri (fun i _ -> i < 5000)
                  | _ -> [])
              | _ -> []
              | exception _ -> [])
          | [] -> []
        in
        let found = List.filter_map (fun m -> match kind_and_pubkey m with Some 0, Some pk -> Some (String.lowercase_ascii pk) | _ -> None) msgs in
        (* the SQL user_infos emits media/preview for a meta_data pointer whose event is gone
           (purged); Julia's in-memory path never reaches those: keep only extras of emitted events *)
        let md_ids =
          List.filter_map
            (fun m ->
              match Yojson.Safe.from_string m with
              | `Assoc f -> (
                  match (List.assoc_opt "kind" f, List.assoc_opt "id" f) with
                  | Some (`Int 0), Some (`String id) -> Some (String.lowercase_ascii id)
                  | _ -> None)
              | _ -> None
              | exception _ -> None)
            msgs
        in
        let extra_of_known_event m =
          match kind_and_pubkey m with
          | Some k, _ when k = Kind.media_metadata || k = Kind.link_metadata || k = Kind.media_hls_urls -> (
              match Yojson.Safe.from_string m with
              | `Assoc f -> (
                  match List.assoc_opt "content" f with
                  | Some (`String c) -> (
                      match Yojson.Safe.from_string c with
                      | `Assoc cf -> (
                          match List.assoc_opt "event_id" cf with
                          | Some (`String id) -> List.mem (String.lowercase_ascii id) md_ids
                          | _ -> true)
                      | _ -> true
                      | exception _ -> true)
                  | _ -> true)
              | _ -> true
              | exception _ -> true)
          | _ -> true
        in
        let keep m =
          match kind_and_pubkey m with
          | Some k, _ when k = Kind.user_scores || k = Kind.user_follower_counts -> false
          | _ -> extra_of_known_event m
        in
        let msgs = List.filter keep msgs |> List.map strip_null_mt in
        Handled
          (messages
             (msgs @ counts_msg Kind.user_scores (follower_counts c (List.sort_uniq compare found))
             @ counts_msg ~always:true Kind.user_follower_counts (follower_counts c (List.sort_uniq compare follows))))
      end)

let is_user_following (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" and user_pubkey = Kw.hex32_exn kw "user_pubkey" in
  Handled (messages (with_cache ctx (fun c -> Queries.is_user_following c ~pubkey ~user_pubkey)))

(* app.jl response_messages_for_list *)
let list_funcall (tables : Queries.list_table list) (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" in
  let extended_response = Kw.bool kw "extended_response" ~default:true in
  with_cache ctx (fun c ->
      let events = List.filter_map (fun table -> Queries.list_event c ~table ~pubkey) tables in
      if not extended_response then Handled (messages events)
      else begin
        (* p tags with exactly two fields, first occurrence order *)
        let pks =
          List.concat_map
            (fun e ->
              match Yojson.Safe.from_string e with
              | `Assoc f -> (
                  match List.assoc_opt "tags" f with
                  | Some (`List tags) ->
                      List.filter_map
                        (function
                          | `List [ `String "p"; `String pk ] when String.length pk = 64 && Hex_util.decode_opt pk <> None ->
                              Some (String.lowercase_ascii pk)
                          | _ -> None)
                        tags
                  | _ -> [])
              | _ -> []
              | exception _ -> [])
            events
          |> List.fold_left (fun acc pk -> if List.mem pk acc then acc else pk :: acc) []
          |> List.rev
        in
        let found, cards = user_cards c pks in
        (* Julia: mds, user_scores, then ext_user_infos (media/preview), then names *)
        let mds = List.filter (fun m -> match kind_and_pubkey m with Some 0, _ -> true | _ -> false) cards in
        let rest = List.filter (fun m -> match kind_and_pubkey m with Some 0, _ -> false | _ -> true) cards in
        Handled (messages (events @ mds @ counts_msg Kind.user_scores (follower_counts c found) @ rest @ verified_names c found))
      end)

let mutelist = list_funcall [ Queries.Mute_list; Queries.Mute_list_2 ]
let mutelists = list_funcall [ Queries.Mute_lists ]
let allowlist = list_funcall [ Queries.Allow_list ]

let replaceable_event (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" and kind = Kw.int_exn kw "kind" in
  Handled (messages (with_cache ctx (fun c -> Queries.replaceable_event c ~pubkey ~kind)))

let get_user_relays (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" in
  Handled (messages (with_cache ctx (fun c -> relays_of c ~pubkey)))

let get_user_relays_2 (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkeys = hex32_list_exn kw "pubkeys" in
  Handled (messages (with_cache ctx (fun c -> List.concat_map (fun pubkey -> relays_of c ~pubkey) pubkeys)))

let creator_paid_tiers (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" in
  Handled (messages (with_cache ctx (fun c -> Queries.creator_paid_tiers c ~pubkey)))

(* {2 events} *)

let poll_votes (ctx : ctx) (kw : Kw.t) : outcome =
  let event_id = Kw.hex32_exn kw "event_id" in
  let since = Kw.int kw "since" ~default:0 and until = Kw.int kw "until" ~default:(now ()) in
  let limit = Kw.int kw "limit" ~default:20 and offset = Kw.int kw "offset" ~default:0 in
  let user_pubkey = user_pubkey_opt kw in
  let apply_humaness_check = Kw.bool kw "apply_humaness_check" ~default:true in
  let option = Kw.str_opt kw "option" in
  Handled
    (messages
       (with_cache ctx (fun c ->
            Queries.poll_votes c ~event_id ~since ~until ~limit ~offset ~user_pubkey ~apply_humaness_check ~option)))

(* app.jl range(): the RANGE message closing a paged answer *)
let range_msg ~(order_by : string) (items : (string * int64) list) : string =
  let content =
    match items with
    | [] -> `Assoc [ ("order_by", `String order_by); ("elements", `List []) ]
    | (_, first) :: _ ->
        let _, last = List.nth items (List.length items - 1) in
        let since = min first last and until = max first last in
        let elements = List.stable_sort (fun (_, a) (_, b) -> compare b a) items |> List.map (fun (id, _) -> `String id) in
        `Assoc [ ("since", i64json since); ("until", i64json until); ("order_by", `String order_by); ("elements", `List elements) ]
  in
  content_msg Kind.range (Yojson.Safe.to_string content)

(* app.jl event_zaps_by_satszapped + response_messages_for_zaps (event_id form) *)
let event_zaps_by_satszapped (ctx : ctx) (kw : Kw.t) : outcome =
  let limit = Kw.int kw "limit" ~default:20 in
  if limit > 1000 then julia_error
  else
    match Kw.hex32_opt kw "event_id" with
    | None -> Not_handled (* the (pubkey, identifier) article forms stay with Julia *)
    | Some event_id ->
        let since = Kw.int kw "since" ~default:0 and until = Kw.int kw "until" ~default:100_000_000_000 in
        let offset = Kw.int kw "offset" ~default:0 in
        let _user_pubkey = user_pubkey_opt kw in
        with_cache ctx (fun c ->
            let zaps = Queries.og_zap_receipts_by_event c ~event_id ~since ~until ~limit ~offset in
            let hex = Hex_util.encode in
            let ids = List.concat_map (fun (z : Queries.zap_row) -> hex z.zap_receipt_id :: Option.to_list (Option.map hex z.zr_event_id)) zaps in
            let evs = if ids = [] then [] else Queries.events_by_ids c ~event_ids_json:(Queries.hexes_json ids) in
            let md_pks =
              List.concat_map (fun (z : Queries.zap_row) -> List.filter_map (Option.map hex) [ z.sender; z.receiver ]) zaps
              |> List.fold_left (fun acc pk -> if List.mem pk acc then acc else pk :: acc) []
              |> List.rev
            in
            let per_zap =
              List.concat_map
                (fun (z : Queries.zap_row) ->
                  let opt_hex = function Some b -> `String (hex b) | None -> `Null in
                  Option.to_list (List.assoc_opt (hex z.zap_receipt_id) evs)
                  @ (match z.zr_event_id with Some e -> Option.to_list (List.assoc_opt (hex e) evs) | None -> [])
                  @ [
                      content_msg Kind.zap_event
                        (Yojson.Safe.to_string
                           (`Assoc
                             [
                               ("event_id", opt_hex z.zr_event_id);
                               ("created_at", i64json z.zr_created_at);
                               ("sender", opt_hex z.sender);
                               ("receiver", opt_hex z.receiver);
                               ("amount_sats", i64json z.amount_sats);
                               ("zap_receipt_id", `String (hex z.zap_receipt_id));
                             ]));
                    ])
                zaps
            in
            let found, cards = user_cards c md_pks in
            let mds = List.filter (fun m -> match kind_and_pubkey m with Some 0, _ -> true | _ -> false) cards in
            let rest = List.filter (fun m -> match kind_and_pubkey m with Some 0, _ -> false | _ -> true) cards in
            (* Julia: OrderedSet over everything, then range *)
            let all = per_zap @ mds @ counts_msg Kind.user_scores (follower_counts c found) @ verified_names c found @ rest in
            let dedup = List.fold_left (fun acc m -> if List.mem m acc then acc else m :: acc) [] all |> List.rev in
            Handled
              (messages (dedup @ [ range_msg ~order_by:"amount_sats" (List.map (fun (z : Queries.zap_row) -> (hex z.zap_receipt_id, z.amount_sats)) zaps) ])))

(* app.jl long_form_content_feed as a direct funcall (Julia: usepgfuncs + apply_humaness_check) *)
let long_form_content_feed_funcall (ctx : ctx) (kw : Kw.t) : outcome =
  let limit = Kw.int kw "limit" ~default:20 in
  if limit > 1000 then julia_error
  else
    let since = Kw.int kw "since" ~default:0 and until = Kw.int kw "until" ~default:(now ()) in
    let offset = Kw.int kw "offset" ~default:0 in
    let pubkey = match Kw.member kw "pubkey" with `Null -> None | _ -> Some (Kw.hex32_exn kw "pubkey") in
    let user_pubkey = user_pubkey_opt kw in
    let notes = Some (Kw.str kw "notes" ~default:"follows") in
    let topic = Kw.str_opt kw "topic" and curation = Kw.str_opt kw "curation" in
    let minwords = Kw.int kw "minwords" ~default:0 in
    Handled
      (messages
         (with_cache ctx (fun c ->
              Queries.long_form_content_feed c ~pubkey ~notes ~topic ~curation ~minwords ~limit ~since ~until ~offset
                ~user_pubkey ~apply_humaness_check:true)))

(* events without extended_response (app.jl events): ids, or the stored events oldest first *)
let events_plain (ctx : ctx) (kw : Kw.t) : outcome =
  let ids = match Kw.member kw "event_ids" with `Null -> [] | _ -> hex32_list_exn kw "event_ids" in
  let limit = Kw.int kw "limit" ~default:20 and since = Kw.int kw "since" ~default:0 in
  let until = Kw.int kw "until" ~default:(now ()) and offset = Kw.int kw "offset" ~default:0 in
  let idsonly = Kw.bool kw "idsonly" ~default:false in
  with_cache ctx (fun c ->
      let hexes =
        if ids = [] then Queries.event_ids_between c ~since ~until ~limit ~offset else List.map Hex_util.encode ids
      in
      if idsonly then
        Handled
          (messages
             [ Yojson.Safe.to_string (`Assoc [ ("kind", `Int Kind.event_ids); ("ids", `List (List.map (fun h -> `String h) hexes)) ]) ])
      else if hexes = [] then Handled empty
      else Handled (messages (Queries.events_plain c ~event_ids_json:(Queries.hexes_json hexes))))

let events (ctx : ctx) (kw : Kw.t) : outcome =
  if Kw.bool kw "extended_response" ~default:false then events ctx kw else events_plain ctx kw

let user_profile_scored_content (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" in
  let limit = min 100 (Kw.int kw "limit" ~default:5) in
  let _user_pubkey = user_pubkey_opt kw in
  with_cache ctx (fun c ->
      let posts = Queries.user_scored_posts c ~pubkey ~limit |> List.sort_uniq compare in
      Handled (messages (posts @ Option.to_list (Queries.metadata_event c ~pubkey))))

(* app_ext.jl note_mentions: response_messages_for_posts over the mentioning events *)
let note_mentions (ctx : ctx) (kw : Kw.t) : outcome =
  let limit = Kw.int kw "limit" ~default:100 and offset = Kw.int kw "offset" ~default:0 in
  if limit > 1000 then julia_error
  else
    let user_pubkey = user_pubkey_opt kw in
    let enrich c hexes =
      let hexes = List.sort_uniq compare hexes in
      if hexes = [] then []
      else Queries.enrich_events c ~event_ids_json:(Queries.hexes_json hexes) ~user_pubkey ~apply_humaness_check:false ~orderby:"created_at"
    in
    match (Kw.member kw "event_id", Kw.member kw "pubkey", Kw.member kw "identifier") with
    | `String _, _, _ ->
        let event_id = Kw.hex32_exn kw "event_id" in
        Handled (messages (with_cache ctx (fun c -> enrich c (Queries.note_mentions_event_ids c ~event_id ~limit ~offset))))
    | `Null, `String _, `String identifier ->
        let pubkey = Kw.hex32_exn kw "pubkey" in
        Handled
          (messages
             (with_cache ctx (fun c -> enrich c (Queries.note_mentions_of_article_event_ids c ~pubkey ~identifier ~limit ~offset))))
    | `Null, _, _ -> Handled empty
    | _ -> raise (Kw.Invalid "invalid event_id")

let note_mentions_count (ctx : ctx) (kw : Kw.t) : outcome =
  let event_id = Kw.hex32_exn kw "event_id" in
  let count = with_cache ctx (fun c -> Queries.note_mentions_count c ~event_id) in
  Handled
    (messages
       [
         content_msg Kind.note_mentions_count
           (Yojson.Safe.to_string (`Assoc [ ("event_id", `String (Hex_util.encode event_id)); ("count", i64json count) ]));
       ])

(* {2 search} (app_ext.jl user_search) *)

let user_search (ctx : ctx) (kw : Kw.t) : outcome =
  let query = Kw.str_exn kw "query" in
  let limit = min 100 (Kw.int kw "limit" ~default:10) in
  let pubkey = match Kw.member kw "pubkey" with `Null -> None | _ -> Some (Kw.hex32_exn kw "pubkey") in
  let contains_lolicon =
    let n = String.length query and m = String.length "lolicon" in
    let rec go i = i + m <= n && (String.sub query i m = "lolicon" || go (i + 1)) in
    go 0
  in
  if contains_lolicon || String.length query < 1 then Handled empty
  else
    with_cache ctx (fun c ->
        let q = query ^ ":*" in
        let users : (string * int64) list option =
          match Bech32.nip19_decode query with
          | Some (Bech32.Npub pk) -> (
              match Queries.follower_count c ~pubkey:pk with
              | Some cnt -> Some [ (Hex_util.encode pk, cnt) ]
              | None -> None (* Julia: KeyError *))
          | _ -> (
              match pubkey with
              | None -> Some (Queries.user_search_query c ~q ~limit)
              | Some follower -> Some (Queries.user_search_follows c ~follower ~q))
        in
        match users with
        | None -> julia_error
        | Some users ->
            (* Julia: Dict keeps one entry per pubkey; sort by followers desc; first limit *)
            let dedup = List.fold_left (fun acc (k, v) -> if List.mem_assoc k acc then acc else (k, v) :: acc) [] users |> List.rev in
            let sorted = List.stable_sort (fun (_, a) (_, b) -> compare b a) dedup in
            let top = List.filteri (fun i _ -> i < limit) sorted in
            let found, cards = user_cards c (List.map fst top) in
            let mds = List.filter (fun m -> match kind_and_pubkey m with Some 0, _ -> true | _ -> false) cards in
            let rest = List.filter (fun m -> match kind_and_pubkey m with Some 0, _ -> false | _ -> true) cards in
            let counts = follower_counts c found in
            let names = verified_names c found in
            let live = if dedup = [] then [] else Queries.user_live_events c ~pubkeys_json:(Queries.hexes_json (List.map fst dedup)) in
            (* Julia: mds, ext_user_infos (media/preview), user_scores, names, follower counts, names, live *)
            Handled
              (messages
                 (mds @ rest @ counts_msg Kind.user_scores counts @ names
                 @ counts_msg ~always:true Kind.user_follower_counts counts
                 @ names @ live)))

(* app_ext.jl feed_directive_: the pubkey forms route to feed; search/explore forms stay with Julia *)
let feed_directive (ctx : ctx) (kw : Kw.t) : outcome =
  let directive = Kw.str_exn kw "directive" in
  let kwa = Kw.remove kw "directive" in
  let user_pubkey = user_pubkey_opt kw in
  let with_pk pk extra = feed_with ~user_pubkey ctx (Kw.merge (Kw.set kwa "pubkey" (`String pk)) extra) in
  let is_pk pk = String.length pk = 64 && Hex_util.decode_opt pk <> None in
  if is_pk directive then with_pk directive []
  else
    match String.split_on_char ';' directive with
    | [ "authored"; pk ] when is_pk pk -> with_pk pk [ ("notes", `String "authored") ]
    | [ "authoredreplies"; pk ] when is_pk pk -> with_pk pk [ ("notes", `String "replies") ]
    | [ "withreplies"; pk ] when is_pk pk -> with_pk pk [ ("include_replies", `Bool true) ]
    | _ -> Not_handled

(* {2 content-moderation repo files} *)

let get_reads_topics (ctx : ctx) (_ : Kw.t) : outcome =
  Handled (messages [ content_msg Kind.reads_topics (file_json_content (cm_file ctx "reads-topics.json") ~default:"{}") ])

let get_reads_feeds (ctx : ctx) (_ : Kw.t) : outcome =
  Handled (messages [ content_msg Kind.reads_feeds (file_json_content (cm_file ctx "reads-feeds.json") ~default:"{}") ])

let get_featured_authors (ctx : ctx) (_ : Kw.t) : outcome =
  Handled (messages [ content_msg Kind.featured_authors (file_json_content (cm_file ctx "featured-authors.json") ~default:"{}") ])

let get_home_feeds (ctx : ctx) (_ : Kw.t) : outcome =
  Handled (messages [ content_msg Kind.home_feeds (file_json_content (cm_file ctx "home-feeds.json") ~default:"{}") ])

let get_recommended_blossom_servers (ctx : ctx) (_ : Kw.t) : outcome =
  Handled
    (messages
       [ content_msg Kind.recommended_blossom_servers (file_json_content (cm_file ctx "recommended-blossom-servers.json") ~default:"null") ])

let default_app_subsettings (ctx : ctx) (subkey : string) : outcome =
  match subkey with
  | "user-home-feeds" -> Handled (messages [ content_msg Kind.app_subsettings (file_json_content (cm_file ctx "home-feeds.json") ~default:"{}") ])
  | "user-reads-feeds" -> Handled (messages [ content_msg Kind.app_subsettings (file_json_content (cm_file ctx "reads-feeds.json") ~default:"{}") ])
  | _ -> julia_error (* Julia: error("invalid subkey") *)

let get_default_app_subsettings (ctx : ctx) (kw : Kw.t) : outcome = default_app_subsettings ctx (Kw.str_exn kw "subkey")

(* app_ext.jl get_recommended_users: recommended-users.json [[pubkey, name], ...] *)
let get_recommended_users (ctx : ctx) (_ : Kw.t) : outcome =
  match Files.read_opt (cm_file ctx "recommended-users.json") with
  | None -> Handled empty
  | Some s ->
      let hexes =
        match Yojson.Safe.from_string s with
        | `List items -> List.filter_map (function `List (`String pk :: _) when String.length pk = 64 -> Some pk | _ -> None) items
        | _ -> []
        | exception _ -> raise (Kw.Invalid "recommended-users.json")
      in
      with_cache ctx (fun c ->
          let hexes = Queries.pubkeys_with_metadata c ~pubkeys_json:(Queries.hexes_json hexes) |> List.sort_uniq compare in
          if hexes = [] then Handled empty
          else
            let pubkeys_json = Queries.hexes_json hexes in
            Handled (messages (Queries.user_infos c ~pubkeys_json @ counts_msg Kind.user_scores (follower_counts c hexes))))

(* app_ext.jl get_suggested_users: suggested-accounts.json [[group, [[pubkey|npub, name], ...]], ...] *)
let get_suggested_users (ctx : ctx) (_ : Kw.t) : outcome =
  match Files.read_opt (cm_file ctx "suggested-accounts.json") with
  | None -> Handled empty
  | Some s ->
      let groups =
        match Yojson.Safe.from_string s with
        | `List gs ->
            List.map
              (function
                | `List [ `String group; `List users ] ->
                    let members =
                      List.map
                        (function
                          | `List [ `String pk; `String name ] ->
                              let pk =
                                if String.length pk >= 4 && String.sub pk 0 4 = "npub" then
                                  match Bech32.nip19_decode pk with
                                  | Some (Bech32.Npub raw) -> Hex_util.encode raw
                                  | _ -> raise (Kw.Invalid "suggested-accounts.json")
                                else pk
                              in
                              (pk, name)
                          | _ -> raise (Kw.Invalid "suggested-accounts.json"))
                        users
                    in
                    (group, members)
                | _ -> raise (Kw.Invalid "suggested-accounts.json"))
              gs
        | _ -> raise (Kw.Invalid "suggested-accounts.json")
        | exception Yojson.Json_error _ -> raise (Kw.Invalid "suggested-accounts.json")
      in
      let content =
        `List
          (List.map
             (fun (group, members) ->
               `Assoc
                 [
                   ("group", `String group);
                   ("members", `List (List.map (fun (pk, name) -> `Assoc [ ("pubkey", `String pk); ("name", `String name) ]) members));
                 ])
             groups)
      in
      let hexes = List.concat_map (fun (_, members) -> List.map fst members) groups in
      with_cache ctx (fun c ->
          let found, mds = if hexes = [] then ([], []) else List.split (Queries.metadata_events c ~pubkeys_json:(Queries.hexes_json hexes)) in
          let found = List.sort_uniq compare found in
          Handled
            (messages
               ((content_msg Kind.suggested_users (Yojson.Safe.to_string content) :: List.sort_uniq compare mds)
               @ counts_msg Kind.user_scores (follower_counts c found))))

(* {2 misc} *)

(* app_ext.jl get_default_relays: primal + one well-known + four random recently-seen relays *)
let get_default_relays (ctx : ctx) (_ : Kw.t) : outcome =
  let mined = with_cache ctx (fun c -> Queries.mined_relays c) |> List.sort_uniq compare in
  if List.length mined < 4 then julia_error (* Julia: @assert *)
  else begin
    let arr = Array.of_list mined in
    let picked = ref [] in
    while List.length !picked < 4 do
      let r = arr.(Random.int (Array.length arr)) in
      if not (List.mem r !picked) then picked := !picked @ [ r ]
    done;
    let known = [| "wss://relay.damus.io"; "wss://nos.lol"; "wss://relay.nostr.band"; "wss://relayable.org" |] in
    let relays = "wss://relay.primal.net" :: known.(Random.int 4) :: !picked in
    Handled (messages [ content_msg Kind.default_relays (Yojson.Safe.to_string (`List (List.map (fun r -> `String r) relays))) ])
  end

(* app_ext.jl get_media_metadata *)
let get_media_metadata (ctx : ctx) (kw : Kw.t) : outcome =
  let urls = match Kw.str_list_opt kw "urls" with Some l -> l | None -> raise (Kw.Invalid "urls required") in
  let eid = Kw.member kw "eid" in
  with_cache ctx (fun c ->
      let thumbnails = ref [] in
      let root_mt = ref None (* Julia declares it outside the url loop: it carries over *) in
      let resources =
        List.map
          (fun url ->
            let variants = Queries.media_url_variants c ~url in
            let vs =
              List.map
                (fun (v : Queries.media_variant) ->
                  root_mt := Some v.mimetype;
                  let s = match v.size with Some s when String.length s > 0 -> `String (String.make 1 s.[0]) | Some _ -> `String "" | None -> `Null in
                  `Assoc
                    [
                      ("s", s);
                      ("a", match v.animated with Some a -> i64json a | None -> `Null);
                      ("w", match v.width with Some w -> i64json w | None -> `Null);
                      ("h", match v.height with Some h -> i64json h | None -> `Null);
                      ("mt", match v.mimetype with Some m -> `String m | None -> `Null);
                      ("dur", match v.duration with Some d -> `Float d | None -> `Null);
                      ("media_url", match v.media_url with Some m -> `String m | None -> `Null);
                    ])
                variants
            in
            (* Julia: thumbnails[url] = thumbnail_url for every row, so the last row wins *)
            (match List.rev (Queries.video_thumbnails c ~url) with t :: _ -> thumbnails := (url, `String t) :: !thumbnails | [] -> ());
            `Assoc
              ([ ("url", `String url); ("variants", `List vs) ]
              @ match !root_mt with Some (Some mt) -> [ ("mt", `String mt) ] | Some None -> [ ("mt", `Null) ] | None -> []))
          urls
      in
      let res =
        (if resources = [] then [] else [ ("resources", `List resources) ])
        @ if !thumbnails = [] then [] else [ ("thumbnails", `Assoc (List.rev !thumbnails)) ]
      in
      let res = if res <> [] && eid <> `Null then res @ [ ("event_id", eid) ] else res in
      if res = [] then Handled empty else Handled (messages [ content_msg Kind.media_metadata (Yojson.Safe.to_string (`Assoc res)) ]))

(* app.jl nip19_decode: Julia's ser() shape, {id: [...]} per id; None = Julia would throw *)
let nip19_ser (id : string) : Yojson.Safe.t option =
  let hexs b = `String (Hex_util.encode b) in
  let starts p = String.length id >= String.length p && String.sub id 0 (String.length p) = p in
  let decode prefix =
    match Bech32.bech32_decode id with
    | Some (hrp, d5) when hrp = prefix -> Bech32.to_bytes d5
    | _ -> None
  in
  let simple prefix tyname =
    match decode prefix with Some b when String.length b = 32 -> Some (`List [ `List [ `String tyname; hexs b ] ]) | _ -> None
  in
  if starts "npub" then simple "npub" "PubKeyId"
  else if starts "note" then simple "note" "EventId"
  else if starts "nsec" then ( match decode "nsec" with Some b when String.length b = 32 -> Some (`List [ hexs b ]) | _ -> None)
  else
    match List.find_opt starts [ "nprofile"; "nevent"; "nrelay"; "naddr" ] with
    | None -> Some (`List [ `Null ])
    | Some prefix -> (
        match decode prefix with
        | None -> None
        | Some raw -> (
            let n = String.length raw in
            let exception Bad in
            let u32 v =
              if String.length v < 4 then raise Bad
              else (Char.code v.[0] lsl 24) lor (Char.code v.[1] lsl 16) lor (Char.code v.[2] lsl 8) lor Char.code v.[3]
            in
            let id32 tyname v = if String.length v = 32 then `List [ `String tyname; hexs v ] else raise Bad in
            let rec loop i acc =
              if i >= n then List.rev acc
              else if i + 1 >= n then raise Bad
              else begin
                let t = Char.code raw.[i] and l = Char.code raw.[i + 1] in
                if i + 2 + l > n then raise Bad;
                let v = String.sub raw (i + 2) l in
                let item =
                  match t with
                  | 0 -> (
                      `String "Special"
                      :: match prefix with "nprofile" -> [ id32 "PubKeyId" v ] | "nevent" -> [ id32 "EventId" v ] | _ -> [ `String v ])
                  | 1 -> [ `String "Relay"; `String v ]
                  | 2 -> [ `String "Author"; (if prefix = "naddr" || prefix = "nevent" then id32 "PubKeyId" v else `Null) ]
                  | 3 -> [ `String "Kind"; (if prefix = "naddr" || prefix = "nevent" then `Int (u32 v) else `Null) ]
                  | _ -> raise Bad
                in
                loop (i + 2 + l) (List.rev_append item acc)
              end
            in
            try Some (`List (loop 0 [])) with Bad -> None))

let nip19_decode (_ : ctx) (kw : Kw.t) : outcome =
  let ids = match Kw.str_list_opt kw "ids" with Some l -> l | None -> raise (Kw.Invalid "ids required") in
  match List.map (fun id -> match nip19_ser id with Some v -> (id, v) | None -> raise Exit) ids with
  | pairs -> Handled (messages [ content_msg Kind.nip19_decode_result (Yojson.Safe.to_string (`Assoc pairs)) ])
  | exception Exit -> julia_error

(* {2 membership} *)

let settings_subkey (e : Nostr.t) : (string * Yojson.Safe.t) option =
  if e.Nostr.kind <> Kind.app_settings then None (* Julia: error("invalid event kind") *)
  else
    match Yojson.Safe.from_string e.Nostr.content with
    | `Assoc d as j -> ( match List.assoc_opt "subkey" d with Some (`String k) -> Some (k, j) | _ -> None)
    | _ -> None
    | exception _ -> None

let get_app_subsettings (ctx : ctx) (kw : Kw.t) : outcome =
  match event_from_user kw with
  | Error _ -> julia_error
  | Ok e -> (
      match settings_subkey e with
      | None -> julia_error
      | Some (subkey, _) -> (
          match with_membership ctx (fun c -> Queries_mem.app_subsettings c ~pubkey:e.Nostr.pubkey ~subkey) with
          | Some settings -> Handled (messages [ content_msg Kind.app_subsettings settings ])
          | None -> default_app_subsettings ctx subkey))

let set_app_subsettings (ctx : ctx) (kw : Kw.t) : outcome =
  match event_from_user kw with
  | Error _ -> julia_error
  | Ok e -> (
      match settings_subkey e with
      | Some (subkey, `Assoc d) -> (
          match List.assoc_opt "settings" d with
          | None -> julia_error
          | Some settings ->
              with_membership ctx (fun c ->
                  Queries_mem.set_app_subsettings c ~pubkey:e.Nostr.pubkey ~subkey ~updated_at:(now ())
                    ~settings_json:(Yojson.Safe.to_string settings));
              Handled empty)
      | _ -> julia_error)

let membership_media_management_stats (ctx : ctx) (kw : Kw.t) : outcome =
  match event_from_user kw with
  | Error _ -> julia_error
  | Ok e ->
      with_membership ctx (fun c ->
          let stats = Queries_mem.media_management_stats c ~pubkey:e.Nostr.pubkey in
          let sum t = List.fold_left (fun acc (ty, _, size) -> if ty = t then Int64.add acc size else acc) 0L stats in
          let video = sum "video" and image = sum "image" and other = sum "other" in
          match Queries_mem.max_storage c ~pubkey:e.Nostr.pubkey with
          | None -> julia_error
          | Some max_storage ->
              let free = Int64.(sub max_storage (add image (add video other))) in
              Handled
                (messages
                   [
                     content_msg Kind.membership_media_management_stats
                       (Yojson.Safe.to_string
                          (`Assoc [ ("video", i64json video); ("image", i64json image); ("other", i64json other); ("free", i64json free) ]));
                   ]))

(* {1 Phase 4a: notifications and the push subscriptions} *)

(* src/notifications.jl notification_args: what each argument of a notification type is *)
type notif_arg = Pk | Eid | Int | Str

let notification_args : (int * (string * notif_arg) list) list =
  [
    (1, [ ("follower", Pk) ]);
    (2, [ ("follower", Pk) ]);
    (3, [ ("your_post", Eid); ("who_zapped_it", Pk); ("satszapped", Int); ("message", Str) ]);
    (4, [ ("your_post", Eid); ("who_liked_it", Pk); ("reaction", Str) ]);
    (5, [ ("your_post", Eid); ("who_reposted_it", Pk) ]);
    (6, [ ("your_post", Eid); ("who_replied_to_it", Pk); ("reply", Eid) ]);
    (7, [ ("you_were_mentioned_in", Eid); ("you_were_mentioned_by", Pk) ]);
    (8, [ ("your_post", Eid); ("your_post_were_mentioned_in", Eid); ("your_post_was_mentioned_by", Pk) ]);
    (101, [ ("post_you_were_mentioned_in", Eid); ("who_zapped_it", Pk); ("satszapped", Int) ]);
    (102, [ ("post_you_were_mentioned_in", Eid); ("who_liked_it", Pk) ]);
    (103, [ ("post_you_were_mentioned_in", Eid); ("who_reposted_it", Pk) ]);
    (104, [ ("post_you_were_mentioned_in", Eid); ("who_replied_to_it", Pk); ("reply", Eid) ]);
    (201, [ ("post_your_post_was_mentioned_in", Eid); ("your_post", Eid); ("who_zapped_it", Pk); ("satszapped", Int) ]);
    (202, [ ("post_your_post_was_mentioned_in", Eid); ("your_post", Eid); ("who_liked_it", Pk) ]);
    (203, [ ("post_your_post_was_mentioned_in", Eid); ("your_post", Eid); ("who_reposed_it", Pk) ]);
    (204, [ ("post_your_post_was_mentioned_in", Eid); ("your_post", Eid); ("who_replied_to_it", Pk); ("reply", Eid) ]);
    (301, [ ("your_post", Eid); ("who_highlighted_it", Pk); ("highlight", Eid) ]);
    (302, [ ("your_post", Eid); ("who_bookmarked_it", Pk) ]);
    (401, [ ("event_id", Eid); ("sender", Pk) ]);
    (501, [ ("live_event_id", Eid); ("host", Pk); ("coordinate", Str) ]);
    (601, [ ("your_post", Eid); ("who_replied_to_it", Pk); ("reply", Eid) ]);
  ]

type notif = { fields : (string * Yojson.Safe.t) list; pks : string list; eids : string list; coordinate : string option }

(* DB.notif2namedtuple: typed fields from (arg1, arg2: bytea) (arg3, arg4: jsonb), missing ones
   skipped; the keys sorted; id = sha256 of the compact JSON; then {"id", sorted...} *)
let notif_of_row ~(pubkey_hex : string) (r : Queries.notif_row) : notif option =
  let typ = Int64.to_int r.n_type in
  match List.assoc_opt typ notification_args with
  | None -> None
  | Some spec ->
      let raw = [ `Bytea r.arg1; `Bytea r.arg2; `Json r.arg3; `Json r.arg4 ] in
      let pks = ref [] and eids = ref [] and coordinate = ref None in
      let value (name, kind) raw : (string * Yojson.Safe.t) option =
        let hex_of = function
          | `Bytea (Some b) -> Some (Hex_util.encode b)
          | `Json (Some j) -> ( match Yojson.Safe.from_string j with `String s -> Some (String.lowercase_ascii s) | _ -> None | exception _ -> None)
          | _ -> None
        in
        match kind with
        | Pk -> ( match hex_of raw with Some h -> pks := h :: !pks; Some (name, `String h) | None -> None)
        | Eid -> ( match hex_of raw with Some h -> eids := h :: !eids; Some (name, `String h) | None -> None)
        | Int -> (
            match raw with
            | `Json (Some j) -> ( match Yojson.Safe.from_string j with (`Int _ | `Intlit _) as v -> Some (name, v) | `Float f -> Some (name, `Int (int_of_float f)) | _ -> None | exception _ -> None)
            | _ -> None)
        | Str -> (
            match raw with
            | `Json (Some j) -> (
                match Yojson.Safe.from_string j with
                | `String s ->
                    if name = "coordinate" then coordinate := Some s;
                    Some (name, `String s)
                | _ -> None
                | exception _ -> None)
            | _ -> None)
      in
      let rec zip spec raw acc =
        match (spec, raw) with
        | s :: ss, r :: rs -> zip ss rs (match value s r with Some f -> f :: acc | None -> acc)
        | _ -> List.rev acc
      in
      let fields = zip spec raw [] in
      let all =
        [ ("pubkey", `String pubkey_hex); ("created_at", `Int (Int64.to_int r.n_created_at)); ("type", `Int typ) ] @ fields
        |> List.sort (fun (a, _) (b, _) -> compare a b)
      in
      let json = Yojson.Safe.to_string (`Assoc all) in
      let id = Hex_util.encode (Digestif.SHA256.(to_raw_string (digest_string json))) in
      Some { fields = ("id", `String id) :: all; pks = List.rev !pks; eids = List.rev !eids; coordinate = !coordinate }

(* app_ext.jl get_notifications type_group *)
let notification_types_of_group = function
  | "zaps" -> Some [ 3 ]
  | "replies" -> Some [ 6; 601 ]
  | "mentions" -> Some [ 7; 8 ]
  | "reposts" -> Some [ 5 ]
  | _ -> None

let get_notifications (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" in
  let pubkey_hex = Hex_util.encode pubkey in
  let limit = min (Kw.int kw "limit" ~default:1000) 50 in
  let since = Kw.int kw "since" ~default:0 and until = Kw.int kw "until" ~default:(now ()) in
  let offset = Kw.int kw "offset" ~default:0 in
  let user_pubkey = user_pubkey_opt kw in
  let types = match Kw.str_opt kw "type_group" with Some g -> notification_types_of_group g | None -> None in
  let types_json = Option.map (fun l -> Yojson.Safe.to_string (`List (List.map (fun t -> `Int t) l))) types in
  with_cache ctx (fun c ->
      let rows = Queries.notifications c ~pubkey ~since ~until ~limit ~offset ~user_pubkey ~types_json in
      let notifs = List.filter_map (notif_of_row ~pubkey_hex) rows in
      let msgs =
        List.map (fun n -> content_msg Kind.notification (Yojson.Safe.to_string (`Assoc n.fields))) notifs |> List.sort_uniq compare
      in
      let pks = List.concat_map (fun n -> n.pks) notifs |> List.sort_uniq compare in
      let posts =
        List.concat_map
          (fun n ->
            match n.coordinate with
            | Some coord when Int64.to_int (List.assoc "type" n.fields |> function `Int t -> Int64.of_int t | _ -> 0L) = 501 -> (
                match String.split_on_char ':' coord with
                | [ kind; pk; identifier ] -> (
                    match (int_of_string_opt kind, Hex_util.decode_opt pk) with
                    | Some kind, Some pubkey when String.length pubkey = 32 -> Queries.parametrized_event_ids c ~pubkey ~kind ~identifier
                    | _ -> [])
                | _ -> [])
            | _ -> n.eids)
          notifs
        |> List.sort_uniq compare
      in
      let counts = follower_counts c pks in
      let profiles =
        List.map
          (fun pk ->
            content_msg Kind.user_profile
              (Yojson.Safe.to_string
                 (`Assoc [ ("pubkey", `String pk); ("followers_count", i64json (Option.value (List.assoc_opt pk counts) ~default:0L)) ])))
          pks
      in
      let enriched =
        if posts = [] then []
        else Queries.enrich_events_at c ~event_ids_json:(Queries.hexes_json posts) ~t:(now ()) ~user_pubkey ~apply_humaness_check:false
      in
      let found, cards = user_cards c pks in
      Handled (messages (msgs @ profiles @ enriched @ cards @ verified_names c found)))

let set_notifications_seen (ctx : ctx) (kw : Kw.t) : outcome =
  match event_from_user kw with
  | Error _ -> julia_error
  | Ok e ->
      with_membership ctx (fun m -> Queries_mem.set_notifications_seen m ~pubkey:e.Nostr.pubkey ~seen_until:e.Nostr.created_at);
      with_cache ctx (fun c -> Queries.reset_notification_counts c ~pubkey:e.Nostr.pubkey);
      Handled empty

(* {2 push subscriptions} (answered with EOSE; the Broadcasts loops push the values) *)

let subscription (r : Response.registration) : outcome = Handled { messages = []; registrations = [ r ] }
let notification_counts (_ : ctx) (kw : Kw.t) : outcome = subscription (Notification_counts { pubkey = Kw.hex32_exn kw "pubkey"; v2 = false })
let notification_counts_2 (_ : ctx) (kw : Kw.t) : outcome = subscription (Notification_counts { pubkey = Kw.hex32_exn kw "pubkey"; v2 = true })
let directmsg_count (_ : ctx) (kw : Kw.t) : outcome = subscription (Directmsg_count { pubkey = Kw.hex32_exn kw "pubkey"; v2 = false })
let directmsg_count_2 (_ : ctx) (kw : Kw.t) : outcome = subscription (Directmsg_count { pubkey = Kw.hex32_exn kw "pubkey"; v2 = true })
let net_stats (_ : ctx) (_ : Kw.t) : outcome = subscription Net_stats

let rebroadcasting_status (_ : ctx) (kw : Kw.t) : outcome =
  (* Julia verifies event_from_user on every tick and pushes nothing when it fails *)
  match event_from_user kw with Ok e -> subscription (Rebroadcasting_status { pubkey = e.Nostr.pubkey }) | Error _ -> Handled empty

(* broadcast_notification has no caller any more (the importer moved out of the API node): EOSE only *)
let notifications (_ : ctx) (_ : Kw.t) : outcome = Handled empty
