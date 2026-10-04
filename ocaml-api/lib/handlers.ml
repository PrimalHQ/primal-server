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

let mega_feed_directive_basic (ctx : ctx) (kw : Kw.t) : outcome =
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

let multi_kind_mega_feed_directive_basic (ctx : ctx) (kw : Kw.t) : outcome =
  match parse_spec kw with
  | `Missing -> Not_handled
  | `Invalid -> Notice "invalid spec format"
  | `Spec (s, kwargs) ->
      let kinds = match Kw.member kwargs "kinds" with `Null -> Kw.member s "kinds" | k -> k in
      if kinds = `Null then mega_feed_directive_basic ctx kw
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

(* {1 Phase 4b: explore / trending} (app_ext.jl scored_content and friends) *)

(* set by Funcall at start-up: run a funcall by name (mega_feed_directive routes spec ids to
   exposed functions); Not_handled for everything that is not native *)
let dispatch_by_name : (ctx -> string -> Kw.t -> outcome) ref = ref (fun _ _ _ -> Not_handled)

let f32 (x : float) : float = Int32.float_of_bits (Int32.bits_of_float x)

(* Julia's shortest round-trip text of a Float32 (JSON.json of a Float32 value) *)
let f32_string (x : float) : string =
  let x = f32 x in
  if Float.is_nan x then "NaN"
  else if Float.is_integer x && Float.abs x < 1e7 then Printf.sprintf "%.1f" x
  else begin
    let rec go p =
      let s = Printf.sprintf "%.*g" p x in
      if p >= 9 || f32 (float_of_string s) = x then s else go (p + 1)
    in
    let s = go 1 in
    if String.contains s '.' || String.contains s 'e' || String.contains s 'n' then s else s ^ ".0"
  end

type scored_args = {
  timeframe : string;
  scope_pubkeys : string list; (* hex; [] = global *)
  limit : int;
  limit2 : int option;
  created_after : int;
  since : int option;
  until : int option;
  offset : int;
  group_by_pubkey : bool;
  user_pubkey : string option;
  kinds : int list option;
  gm_mode : string option;
  pg : bool; (* usepgfuncs: enrich_feed_events; else Julia's in-memory path + range *)
  humaness : bool;
}

module SS = Set.Make (String)

(* app_ext.jl scored_content *)
let scored_content (ctx : ctx) (a : scored_args) : string list option =
  let limit = min 50 a.limit in
  let limit = match a.limit2 with Some l -> l | None -> limit in
  let created_after = if a.timeframe <> "popular" then max (now () - (7 * 24 * 3600)) a.created_after else a.created_after in
  let since = Option.map (fun s -> max (max 1 s) created_after) a.since in
  let since = match since with Some 0 -> None | s -> s in
  if limit > 1000 then None
  else begin
    let field =
      match a.timeframe with
      | "latest" -> Queries.Created_at
      | "popular" | "trending" -> Queries.Score
      | "mostzapped" -> Queries.Satszapped
      | t -> raise (Kw.Invalid ("unknown timeframe: " ^ t))
    in
    let kinds_json = Option.map (fun l -> Yojson.Safe.to_string (`List (List.map (fun k -> `Int k) l))) a.kinds in
    let hex = Hex_util.encode in
    with_cache ctx (fun c ->
        let domains_json = Yojson.Safe.to_string (`List (List.map (fun d -> `String d) ctx.cfg.trending_blocked_domains)) in
        let rec loop n =
          let rows =
            if a.scope_pubkeys = [] then
              if a.group_by_pubkey then
                Queries.scored_global_grouped c ~field ~created_after ~user_pubkey:a.user_pubkey ~n ~offset:a.offset ~gm_mode:a.gm_mode ~kinds_json
              else if a.kinds <> None && a.timeframe = "latest" then
                Queries.latest_global_kinds c ~created_after ~kinds_json:(Option.get kinds_json) ~n ~offset:a.offset
              else Queries.scored_global c ~field ~created_after ~since ~until:a.until ~user_pubkey:a.user_pubkey ~n ~offset:a.offset ~kinds_json
            else
              Queries.scored_by_pubkeys c ~field ~created_after ~since ~until:a.until ~pubkeys_json:(Queries.hexes_json a.scope_pubkeys) ~n
                ~offset:a.offset
          in
          (* Julia: one event per author in the global branch (pkseen) *)
          let rows =
            if a.scope_pubkeys = [] then
              List.rev (fst (List.fold_left (fun (acc, seen) (r : Queries.scored_row) -> if SS.mem r.s_pubkey seen then (acc, seen) else (r :: acc, SS.add r.s_pubkey seen)) ([], SS.empty) rows))
            else rows
          in
          let posts_json =
            Yojson.Safe.to_string (`List (List.map (fun (r : Queries.scored_row) -> `List [ `String (hex r.s_event_id); `String (hex r.s_pubkey) ]) rows))
          in
          let pass = if rows = [] then SS.empty else SS.of_list (Queries.scored_pass c ~posts_json ~domains_json) in
          let filtered = List.filter (fun (r : Queries.scored_row) -> SS.mem (hex r.s_event_id) pass) rows in
          if List.length rows < n || List.length filtered >= limit || n * 2 > 1000 then filtered else loop (n * 2)
        in
        let filtered = loop limit in
        let posts = List.stable_sort (fun (x : Queries.scored_row) y -> compare y.s_value x.s_value) filtered |> List.filteri (fun i _ -> i < limit) in
        let posts_json =
          Yojson.Safe.to_string (`List (List.map (fun (r : Queries.scored_row) -> `List [ `String (hex r.s_event_id); `Int (Int64.to_int r.s_value) ]) posts))
        in
        if a.pg then Some (if posts = [] then [] else Queries.enrich_posts c ~posts_json ~user_pubkey:a.user_pubkey ~apply_humaness_check:a.humaness)
        else begin
          let msgs = if posts = [] then [] else Queries.enrich_posts c ~posts_json ~user_pubkey:a.user_pubkey ~apply_humaness_check:false in
          let msgs = List.filter (fun m -> match kind_and_pubkey m with Some k, _ when k = Kind.range -> false | _ -> true) msgs in
          Some (msgs @ [ range_msg ~order_by:(Queries.scored_field_name field) (List.map (fun (r : Queries.scored_row) -> (hex r.s_event_id, r.s_value)) posts) ])
        end)
  end

(* app_ext.jl explore: the scope picks the pubkeys *)
let explore_scope (ctx : ctx) ~(scope : string) ~(user_pubkey : string option) : string list option =
  match (scope, user_pubkey) with
  | "global", _ -> Some []
  | ("network" | "tribe" | "follows"), None -> None
  | "network", Some _ -> Some []
  | "tribe", Some u ->
      Some
        (with_cache ctx (fun c ->
             List.sort_uniq compare (List.map fst (Queries.follows_with_counts c ~pubkey:u) @ Queries.followers_hex c ~pubkey:u)))
  | "follows", Some u -> Some (with_cache ctx (fun c -> List.map fst (Queries.follows_with_counts c ~pubkey:u)))
  | _ -> None

let scored_args_of_kw (kw : Kw.t) ~timeframe ~scope_pubkeys ~pg ~humaness : scored_args =
  {
    timeframe;
    scope_pubkeys;
    limit = Kw.int kw "limit" ~default:20;
    limit2 = Kw.int_opt kw "limit2";
    created_after = Kw.int kw "created_after" ~default:0;
    since = Kw.int_opt kw "since";
    until = Kw.int_opt kw "until";
    offset = Kw.int kw "offset" ~default:0;
    group_by_pubkey = Kw.bool kw "group_by_pubkey" ~default:false;
    user_pubkey = user_pubkey_opt kw;
    kinds = Kw.int_list_opt kw "kinds";
    gm_mode = Kw.str_opt kw "gm_mode";
    pg;
    humaness;
  }

let explore_outcome (ctx : ctx) (kw : Kw.t) (a : scored_args) : outcome =
  match explore_scope ctx ~scope:(Kw.str kw "scope" ~default:"global") ~user_pubkey:a.user_pubkey with
  | None -> Handled empty
  | Some pks -> ( match scored_content ctx { a with scope_pubkeys = pks } with Some msgs -> Handled (messages msgs) | None -> julia_error)

(* explore is in app_funcalls_with_pgfuncs: usepgfuncs + apply_humaness_check *)
let explore (ctx : ctx) (kw : Kw.t) : outcome =
  let timeframe = Kw.str_exn kw "timeframe" in
  ignore (Kw.str_exn kw "scope");
  explore_outcome ctx kw (scored_args_of_kw kw ~timeframe ~scope_pubkeys:[] ~pg:true ~humaness:true)

(* explore_global_trending(hours) / explore_global_mostzapped(hours): limit 100, grouped by author,
   Julia's in-memory path (these two are not in app_funcalls_with_pgfuncs) *)
let explore_global ~timeframe ~hours ?(pg = false) ?(humaness = false) (ctx : ctx) (kw : Kw.t) : outcome =
  let a = scored_args_of_kw kw ~timeframe ~scope_pubkeys:[] ~pg ~humaness in
  let a = { a with limit = 100; created_after = now () - (hours * 3600); group_by_pubkey = true } in
  match scored_content ctx a with Some msgs -> Handled (messages msgs) | None -> julia_error

let explore_global_trending_24h = explore_global ~timeframe:"trending" ~hours:24
let explore_global_mostzapped_4h = explore_global ~timeframe:"mostzapped" ~hours:4

(* app_ext.jl scored_users *)
let scored_users_with (ctx : ctx) ~limit ~since ~user_pubkey : outcome =
  ignore user_pubkey;
  if limit > 1000 || since < now () - (7 * 24 * 3600) then julia_error
  else
    with_cache ctx (fun c ->
        let rows = Queries.scored_users c ~since ~limit in
        let domains_json = Yojson.Safe.to_string (`List (List.map (fun d -> `String d) ctx.cfg.trending_blocked_domains)) in
        let pass = if rows = [] then SS.empty else SS.of_list (Queries.scored_users_pass c ~pubkeys_json:(Queries.hexes_json (List.map fst rows)) ~domains_json) in
        let pubkeys = List.filter (fun (pk, _) -> SS.mem pk pass) rows |> List.stable_sort (fun (_, a) (_, b) -> compare b a) |> List.filteri (fun i _ -> i < limit) in
        let _, cards = user_cards c (List.map fst pubkeys) in
        let scores = content_msg Kind.user_scores (Yojson.Safe.to_string (`Assoc (List.map (fun (pk, v) -> (pk, i64json v)) pubkeys))) in
        Handled (messages (cards @ [ scores ])))

let scored_users (ctx : ctx) (kw : Kw.t) : outcome =
  scored_users_with ctx ~limit:(Kw.int kw "limit" ~default:20) ~since:(Kw.int kw "since" ~default:0) ~user_pubkey:(user_pubkey_opt kw)

let scored_users_24h (ctx : ctx) (kw : Kw.t) : outcome =
  scored_users_with ctx ~limit:(6 * 4) ~since:(now () - (24 * 3600)) ~user_pubkey:(user_pubkey_opt kw)

(* {2 trending hashtags} (app_ext.jl trending_hashtags, @cached) *)

(* hashtag-whitelist.txt: "https://primal.net/search/%23<tag> <n>" lines until a "-----" line *)
let hashtag_whitelist (ctx : ctx) : string list =
  match Files.read_opt (cm_file ctx "hashtag-whitelist.txt") with
  | None -> []
  | Some s ->
      let rec go acc = function
        | [] -> List.rev acc
        | l :: rest ->
            if String.length l >= 5 && String.sub l 0 5 = "-----" then List.rev acc
            else
              match String.split_on_char ' ' (String.trim l) |> List.filter (fun w -> w <> "") with
              | w :: _ when String.length w > 29 -> go (String.sub w 29 (String.length w - 29) :: acc) rest
              | _ -> go acc rest
      in
      go [] (String.split_on_char '\n' s)

let trending_hashtags_compute (ctx : ctx) ~(created_after : int) : string =
  let whitelist = hashtag_whitelist ctx in
  let rows = if whitelist = [] then [] else with_cache ctx (fun c -> Queries.hashtag_rows c ~since:created_after ~whitelist_json:(Queries.hexes_json whitelist)) in
  (* Accumulator{String, Float32}: Float32(acc + followers / nposts), in created_at order *)
  let acc : (string, float) Hashtbl.t = Hashtbl.create 1024 in
  let order = ref [] in
  List.iter
    (fun (ht, followers, nposts) ->
      let user_score = Int64.to_float followers /. Int64.to_float nposts in
      match Hashtbl.find_opt acc ht with
      | Some v -> Hashtbl.replace acc ht (f32 (v +. user_score))
      | None -> order := ht :: !order; Hashtbl.replace acc ht (f32 user_score))
    rows;
  let res = List.rev_map (fun ht -> (ht, Hashtbl.find acc ht)) !order |> List.stable_sort (fun (_, a) (_, b) -> compare b a) in
  let items = List.map (fun (ht, v) -> Printf.sprintf "[%s,%s]" (Yojson.Safe.to_string (`String ht)) (f32_string v)) res in
  content_msg Kind.hashtags ("[" ^ String.concat "," items ^ "]")

(* @cached <period> f: computed on first use, kept for the period *)
let cached : (string, float * string) Hashtbl.t = Hashtbl.create 8
let cached_lock = Mutex.create ()

let with_ttl (key : string) ~(ttl : float) (compute : unit -> string) : string =
  let now_f = Unix.gettimeofday () in
  Mutex.lock cached_lock;
  let hit = match Hashtbl.find_opt cached key with Some (exp, v) when exp > now_f -> Some v | _ -> None in
  Mutex.unlock cached_lock;
  match hit with
  | Some v -> v
  | None ->
      let v = compute () in
      Mutex.lock cached_lock;
      Hashtbl.replace cached key (now_f +. ttl, v);
      Mutex.unlock cached_lock;
      v

let trending_hashtags (ctx : ctx) (kw : Kw.t) : outcome =
  let created_after = Kw.int kw "created_after" ~default:(now () - (7 * 24 * 3600)) in
  Handled (messages [ trending_hashtags_compute ctx ~created_after ])

let trending_hashtags_4h (ctx : ctx) (_ : Kw.t) : outcome =
  Handled (messages [ with_ttl "trending_hashtags_4h" ~ttl:600. (fun () -> trending_hashtags_compute ctx ~created_after:(now () - (4 * 3600))) ])

(* Julia: "!! 7d->2d" *)
let trending_hashtags_7d (ctx : ctx) (_ : Kw.t) : outcome =
  Handled (messages [ with_ttl "trending_hashtags_7d" ~ttl:14400. (fun () -> trending_hashtags_compute ctx ~created_after:(now () - (2 * 24 * 3600))) ])

(* {2 explore_zaps / explore_people / explore_topics / explore_legend_counts} *)

(* app.jl response_messages_for_zaps(zaps; order_by=:amount_sats): shared with event_zaps_by_satszapped *)
let zap_messages (c : Db.cache Db.conn) (zaps : Queries.zap_row list) : string list =
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
  let all = per_zap @ mds @ counts_msg Kind.user_scores (follower_counts c found) @ verified_names c found @ rest in
  let dedup = List.fold_left (fun acc m -> if List.mem m acc then acc else m :: acc) [] all |> List.rev in
  dedup @ [ range_msg ~order_by:"amount_sats" (List.map (fun (z : Queries.zap_row) -> (hex z.zap_receipt_id, z.amount_sats)) zaps) ]


(* {2 response_messages_for_posts} (app.jl, the in-memory enrichment Julia uses outside the
   feed SQL functions): each post, its stats, media/previews, relay, the top five zaps, the
   events it references (e/a tags and nostr: mentions, three levels deep, wrapped as
   REFERENCED_EVENT), then metadata of every pubkey met, EVENT_RELAYS, the viewer's actions and
   the verified names. *)

module Rmfp = struct
  type acc = {
    mutable res : string list; (* reversed *)
    seen : (string, unit) Hashtbl.t;
    pks : (string, unit) Hashtbl.t;
    reids : (string, unit) Hashtbl.t;
    relays : (string, string) Hashtbl.t;
  }

  let push a m = if not (Hashtbl.mem a.seen m) then begin Hashtbl.replace a.seen m (); a.res <- m :: a.res end

  let re_hashref = Str.regexp {|#\[\([0-9]*\)\]|}
  let re_mention = Str.regexp {|\(\(note\|npub\|naddr\|nevent\|nprofile\)1[A-Za-z0-9_]+\)|}

  let all_matches re s group =
    let rec go pos acc = match Str.search_forward re s pos with
      | _ -> let m = Str.matched_group group s in go (Str.match_end ()) (m :: acc)
      | exception Not_found -> List.rev acc
    in
    go 0 []

  (* Julia length(split(content)): tokens separated by Unicode White_Space *)
  let words (content : string) =
    let is_space cp =
      cp = 0x20 || (cp >= 0x09 && cp <= 0x0d) || cp = 0x85 || cp = 0xa0 || cp = 0x1680 || (cp >= 0x2000 && cp <= 0x200a)
      || cp = 0x2028 || cp = 0x2029 || cp = 0x202f || cp = 0x205f || cp = 0x3000
    in
    let n = String.length content in
    let count = ref 0 and in_word = ref false and i = ref 0 in
    while !i < n do
      let d = String.get_utf_8_uchar content !i in
      let cp = Uchar.to_int (Uchar.utf_decode_uchar d) in
      i := !i + Uchar.utf_decode_length d;
      if is_space cp then in_word := false
      else if not !in_word then begin in_word := true; incr count end
    done;
    !count

  type ev = { id : string; pubkey : string; kind : int; content : string; tags : Yojson.Safe.t list; text : string }

  let parse_ev (text : string) : ev option =
    match Yojson.Safe.from_string text with
    | `Assoc f -> (
        match (List.assoc_opt "id" f, List.assoc_opt "pubkey" f, List.assoc_opt "kind" f, List.assoc_opt "content" f, List.assoc_opt "tags" f) with
        | Some (`String id), Some (`String pubkey), Some (`Int kind), Some (`String content), Some (`List tags) ->
            Some { id = String.lowercase_ascii id; pubkey = String.lowercase_ascii pubkey; kind; content; tags; text }
        | _ -> None)
    | _ -> None
    | exception _ -> None

  let tag_fields (t : Yojson.Safe.t) : string list = match t with `List l -> List.filter_map (function `String s -> Some s | _ -> None) l | _ -> []

  (* DB.for_mentiones: the extra (e, p, a) tags a post's content mentions *)
  let mention_tags (c : Db.cache Db.conn) (e : ev) : string list list =
    let out = ref [] in
    let add t = if not (List.mem t !out) then out := t :: !out in
    let resolve_a kind pk identifier =
      match Hex_util.decode_opt pk with
      | Some pubkey when String.length pubkey = 32 -> ( match Queries.parametrized_event_id_one c ~pubkey ~kind ~identifier with Some eid -> add [ "e"; eid ] | None -> ())
      | _ -> ()
    in
    (match e.kind with
    | 1 | 30023 | 6 ->
        List.iter
          (fun n -> match int_of_string_opt n with Some i -> ( match List.nth_opt e.tags i with Some t when List.length (tag_fields t) >= 2 -> add (tag_fields t) | _ -> ()) | None -> ())
          (all_matches re_hashref e.content 1);
        List.iter
          (fun t ->
            match tag_fields t with
            | "a" :: v :: _ :: "mention" :: _ -> ( match String.split_on_char ':' v with [ k; pk; id ] -> ( match int_of_string_opt k with Some kind -> resolve_a kind pk id | None -> ()) | _ -> ())
            | "e" :: _ :: _ :: "mention" :: _ as f -> add f
            | _ -> ())
          e.tags;
        List.iter
          (fun m ->
            match Bech32.nip19_decode m with
            | Some (Bech32.Npub pk) | Some (Bech32.Nprofile pk) -> add [ "p"; Hex_util.encode pk ]
            | Some (Bech32.Note eid) | Some (Bech32.Nevent eid) -> add [ "e"; Hex_util.encode eid ]
            | Some (Bech32.Naddr { kind; author; identifier }) -> resolve_a kind (Hex_util.encode author) identifier
            | None -> ())
          (all_matches re_mention e.content 1)
    | _ -> ());
    List.rev !out

  let event_stats_msg (r : Queries.stats_row) =
    content_msg Kind.event_stats
      (Yojson.Safe.to_string
         (`Assoc
           [ ("event_id", `String r.st_eid); ("likes", i64json r.likes); ("replies", i64json r.replies); ("mentions", i64json r.mentions);
             ("reposts", i64json r.reposts); ("zaps", i64json r.zaps); ("satszapped", i64json r.satszapped); ("score", i64json r.score);
             ("score24h", i64json r.score24h); ("bookmarks", `Int 0) ]))

  let reads_stats_msg eid (likes, zaps, satszapped, replies, reposts) =
    content_msg Kind.event_stats
      (Yojson.Safe.to_string
         (`Assoc
           [ ("event_id", `String eid); ("likes", i64json likes); ("zaps", i64json zaps); ("satszapped", i64json satszapped); ("replies", i64json replies);
             ("mentions", `Int 0); ("reposts", i64json reposts); ("score", `Int 0); ("score24h", `Int 0) ]))

  let wrap_referenced (e : ev) =
    Yojson.Safe.to_string (`Assoc [ ("kind", `Int Kind.referenced_event); ("pubkey", `String e.pubkey); ("content", `String e.text) ])

  let not_zap_target m = match kind_and_pubkey m with Some k, _ -> not (k = Kind.range || k = 1 || k = 30023) | None, _ -> true

  let rec handle (c : Db.cache Db.conn) (a : acc) ~user_pubkey ~include_top_zaps ~(depth : int) ~(wrap : bool) (eids : string list) : unit =
    let eids = List.filter (fun e -> String.length e = 64) eids in
    if eids <> [] then begin
      let ids_json = Queries.hexes_json eids in
      let hidden = SS.of_list (Queries.hidden_events c ~event_ids_json:ids_json) in
      let evs = Queries.events_by_ids c ~event_ids_json:ids_json in
      let live = List.filter_map (fun eid -> if SS.mem eid hidden then None else Option.bind (List.assoc_opt eid evs) parse_ev) eids in
      if live <> [] then begin
        let live_ids = List.map (fun e -> e.id) live in
        let live_json = Queries.hexes_json live_ids in
        let stats = Queries.event_stats_rows c ~event_ids_json:live_json in
        let rstats = Queries.reads_stats_rows c ~event_ids_json:live_json in
        let extras = Queries.event_extras_rows c ~event_ids_json:live_json in
        let relays = Queries.event_relays_rows c ~event_ids_json:live_json in
        let next = ref [] in
        List.iter
          (fun (e : ev) ->
            push a (if wrap then wrap_referenced e else e.text);
            if e.kind = 30023 then push a (content_msg Kind.long_form_metadata (Yojson.Safe.to_string (`Assoc [ ("event_id", `String e.id); ("words", `Int (words e.content)) ])));
            (if e.kind = 30023 then (match List.assoc_opt e.id rstats with Some r -> push a (reads_stats_msg e.id r) | None -> ())
             else match List.find_opt (fun (r : Queries.stats_row) -> r.st_eid = e.id) stats with Some r -> push a (event_stats_msg r) | None -> ());
            if user_pubkey <> None then Hashtbl.replace a.reids e.id ();
            Hashtbl.replace a.pks e.pubkey ();
            List.iter (fun (k, m) -> if k = e.id then push a m) extras;
            (match List.assoc_opt e.id relays with Some r -> Hashtbl.replace a.relays e.id r | None -> ());
            if include_top_zaps then begin
              let zaps = Queries.og_zap_receipts_by_event c ~event_id:(Hex_util.decode_exn e.id) ~since:0 ~until:100_000_000_000 ~limit:5 ~offset:0 in
              List.iter (push a) (List.filter not_zap_target (zap_messages c zaps));
              if e.kind = 30023 then
                match List.find_map (fun t -> match tag_fields t with "d" :: d :: _ -> Some d | _ -> None) e.tags with
                | Some identifier ->
                    let zs = Queries.article_zaps_top c ~pubkey:(Hex_util.decode_exn e.pubkey) ~identifier ~limit:5 in
                    List.iter (push a) (List.filter not_zap_target (zap_messages c zs))
                | None -> ()
            end;
            let tags = List.map tag_fields e.tags @ mention_tags c e in
            List.iter
              (function
                | "e" :: sub :: _ when String.length sub = 64 && Hex_util.decode_opt sub <> None -> next := String.lowercase_ascii sub :: !next
                | "p" :: pk :: _ when String.length pk = 64 && Hex_util.decode_opt pk <> None -> Hashtbl.replace a.pks (String.lowercase_ascii pk) ()
                | "a" :: v :: _ -> (
                    match String.split_on_char ':' v with
                    | [ k; pk; id ] -> (
                        match (int_of_string_opt k, Hex_util.decode_opt pk) with
                        | Some kind, Some pubkey when String.length pubkey = 32 -> (
                            match Queries.parametrized_event_id_one c ~pubkey ~kind ~identifier:id with Some eid -> next := eid :: !next | None -> ())
                        | _ -> ())
                    | _ -> ())
                | _ -> ())
              tags)
          live;
        if depth > 0 && !next <> [] then handle c a ~user_pubkey ~include_top_zaps ~depth:(depth - 1) ~wrap:true (List.rev !next |> List.sort_uniq compare)
      end
    end

  let run (c : Db.cache Db.conn) ?(include_top_zaps = true) ~user_pubkey (eids : string list) : string list =
    let a = { res = []; seen = Hashtbl.create 256; pks = Hashtbl.create 64; reids = Hashtbl.create 64; relays = Hashtbl.create 64 } in
    handle c a ~user_pubkey ~include_top_zaps ~depth:2 ~wrap:false (List.map String.lowercase_ascii eids);
    let pks = Hashtbl.fold (fun k () acc -> k :: acc) a.pks [] |> List.sort_uniq compare in
    if Hashtbl.length a.relays > 0 then
      push a (content_msg Kind.event_relays (Yojson.Safe.to_string (`Assoc (Hashtbl.fold (fun k v acc -> (k, `String v) :: acc) a.relays [] |> List.sort compare))));
    (match user_pubkey with
    | Some u when Hashtbl.length a.reids > 0 ->
        let reids = Hashtbl.fold (fun k () acc -> k :: acc) a.reids [] |> List.sort_uniq compare in
        let ids_json = Queries.hexes_json reids in
        let acts = Queries.event_actions_rows c ~event_ids_json:ids_json ~user_pubkey:u in
        let votes = Queries.poll_votes_rows c ~event_ids_json:ids_json ~user_pubkey:u in
        List.iter
          (fun reid ->
            match (List.assoc_opt reid acts, List.assoc_opt reid votes) with
            | None, None -> ()
            | act, vote ->
                let replied, liked, reposted, zapped = Option.value act ~default:(false, false, false, false) in
                push a
                  (content_msg Kind.event_actions_count
                     (Yojson.Safe.to_string
                        (`Assoc
                          [ ("event_id", `String reid); ("replied", `Bool replied); ("liked", `Bool liked); ("reposted", `Bool reposted); ("zapped", `Bool zapped);
                            ("voted_for_option", match vote with Some v -> `String v | None -> `Null) ]))))
          reids
    | _ -> ());
    let _, cards = user_cards c pks in
    List.iter (push a) cards;
    List.iter (push a) (verified_names c pks);
    List.rev a.res
end

let rmfp = Rmfp.run

let explore_zaps (ctx : ctx) (kw : Kw.t) : outcome =
  let limit = Kw.int kw "limit" ~default:20 in
  if limit > 1000 then julia_error
  else
    let limit = min 50 limit in
    let since = Kw.int kw "since" ~default:0 and until = Kw.int kw "until" ~default:100_000_000_000 in
    let offset = Kw.int kw "offset" ~default:0 in
    let created_after = Kw.int kw "created_after" ~default:(now () - (24 * 3600)) in
    let user_pubkey = user_pubkey_opt kw in
    with_cache ctx (fun c ->
        let zaps = Queries.explore_zaps c ~since ~until ~created_after ~limit ~offset in
        let zmsgs = zap_messages c zaps in
        let eids = List.filter_map (fun (z : Queries.zap_row) -> Option.map Hex_util.encode z.zr_event_id) zaps |> List.sort_uniq compare in
        let posts = if eids = [] then [] else rmfp c ~user_pubkey eids in
        let all = List.fold_left (fun acc m -> if List.mem m acc then acc else m :: acc) [] (zmsgs @ posts) |> List.rev in
        Handled (messages all))

let primal_pubkey_hex = "532d830dffe09c13e75e8b145c825718fc12b0003f61d61e9077721c7fff93cb"

let explore_people (ctx : ctx) (kw : Kw.t) : outcome =
  let limit = min 50 (Kw.int kw "limit" ~default:20) in
  let since = Kw.int kw "since" ~default:0 and until = Kw.int kw "until" ~default:1_000_000_000 in
  let offset = Kw.int kw "offset" ~default:0 in
  let user_pubkey = match user_pubkey_opt kw with Some u -> u | None -> Hex_util.decode_exn primal_pubkey_hex in
  with_cache ctx (fun c ->
      let rows = Queries.explore_people c ~user_pubkey ~since ~until ~limit ~offset in
      let hexes = List.map (fun (r : Queries.people_row) -> Hex_util.encode r.p_pubkey) rows in
      let increases =
        content_msg Kind.user_follower_count_increases
          ("{"
          ^ String.concat ","
              (List.map2
                 (fun (r : Queries.people_row) h ->
                   Printf.sprintf "%s:{\"increase\":%Ld,\"ratio\":%s,\"count\":%Ld}" (Yojson.Safe.to_string (`String h)) r.p_increase (f32_string r.p_ratio) r.p_cnt)
                 rows hexes)
          ^ "}")
      in
      (* Julia user_infos from memory: mds, user_scores (found), follower counts (all), names, media *)
      let found, cards = user_cards c hexes in
      let mds = List.filter (fun m -> match kind_and_pubkey m with Some 0, _ -> true | _ -> false) cards in
      let rest = List.filter (fun m -> match kind_and_pubkey m with Some 0, _ -> false | _ -> true) cards in
      let infos =
        mds @ counts_msg Kind.user_scores (follower_counts c found)
        @ counts_msg ~always:true Kind.user_follower_counts (follower_counts c hexes)
        @ verified_names c hexes @ rest
      in
      let range = if rows = [] then [] else [ range_msg ~order_by:"increase" (List.map2 (fun (r : Queries.people_row) h -> (h, r.p_increase)) rows hexes) ] in
      Handled (messages ((increases :: infos) @ range)))

let explore_topics (ctx : ctx) (_ : Kw.t) : outcome =
  Handled (messages (with_cache ctx (fun c -> Queries.cache_messages c ~key:"precalculated_analytics_explore_topics")))

(* est.commons.stats[:users] of app_ext.jl explore_legend_counts is the network_stats "users" *)
let network_stats_users (ctx : ctx) ~net : int option =
  match ctx.cfg.network_stats_url with
  | None -> None
  | Some url -> (
      match Http.parse_url url with
      | None -> None
      | Some u -> (
          match
            Http.plain_request ~net ~clock:ctx.clock ~timeout:5.0 ~meth:"GET" ~body:{|["network_stats",{}]|} ~host:u.Http.host ~port:u.Http.port
              ~path:u.Http.path ()
          with
          | 200, body -> (
              match Yojson.Safe.from_string body with
              | `List [ _; `String content ] -> (
                  match Yojson.Safe.from_string content with
                  | `Assoc f -> ( match List.assoc_opt "users" f with Some (`Int n) -> Some n | _ -> None)
                  | _ -> None)
              | _ -> None)
          | _ -> None
          | exception _ -> None))

let net_ref : Eio_unix.Net.t option ref = ref None

let explore_legend_counts (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" in
  let follows, inner, outer = with_cache ctx (fun c -> Queries.legend_counts c ~pubkey) in
  (* est.commons.stats[:users]: the importer's network_stats "users" (the API node's own counter
     only counts what that node imported) *)
  let all_users = match !net_ref with Some net -> network_stats_users ctx ~net | None -> None in
  Handled
    (messages
       [
         Yojson.Safe.to_string
           (`Assoc
             [
               ("kind", `Int Kind.explore_legend_counts);
               ("pubkey", `String (Hex_util.encode pubkey));
               ( "content",
                 `String
                   (Yojson.Safe.to_string
                      (`Assoc
                        [
                          ("your_follows", i64json follows);
                          ("your_inner_network", i64json inner);
                          ("your_outer_network", i64json outer);
                          ("all_users", match all_users with Some n -> `Int n | None -> `Null);
                        ])) );
             ]);
       ])

(* {2 mega_feed_directive, the rest of app.jl's spec ids} *)

(* App.exposed_functions of the Julia node (2026-10-04): a spec id naming one of these is a call *)
let julia_exposed =
  [ "advanced_feed"; "advanced_search"; "allowlist"; "articles_stats"; "broadcast_events"; "broadcast_reply"; "check_filterlist";
    "client_config"; "contact_list"; "creator_paid_tiers"; "drafts"; "dvm_feed_info"; "enrich_feed_events"; "event_actions";
    "event_zaps_by_satszapped"; "events"; "events_nip46"; "explore"; "explore_global_mostzapped_4h"; "explore_global_trending_24h";
    "explore_legend_counts"; "explore_media"; "explore_people"; "explore_topics"; "explore_zaps"; "feed"; "feed_2"; "feed_directive";
    "feed_directive_2"; "find_reposts"; "follow_list"; "follow_lists"; "get_advanced_feeds"; "get_app_releases"; "get_app_settings";
    "get_app_settings_2"; "get_app_subsettings"; "get_bookmarks"; "get_default_app_settings"; "get_default_app_subsettings";
    "get_default_relays"; "get_directmsg_contacts"; "get_directmsgs"; "get_dvm_feeds"; "get_featured_authors"; "get_featured_dvm_feeds";
    "get_filterlist"; "get_highlights"; "get_home_feeds"; "get_media_metadata"; "get_notifications"; "get_notifications_seen";
    "get_queued_events_for_nip46"; "get_reads_feeds"; "get_reads_topics"; "get_recommended_blossom_servers"; "get_recommended_reads";
    "get_recommended_users"; "get_suggested_users"; "get_suggested_users_2"; "get_user_relays"; "get_user_relays_2"; "import_events";
    "import_poll_vote_event"; "invoices_to_zap_receipts"; "is_hidden_by_content_moderation"; "is_user_following"; "long_form_content_feed";
    "long_form_content_thread_view"; "mega_feed_directive"; "membership_content_backup"; "membership_content_rebroadcast_cancel";
    "membership_content_rebroadcast_start"; "membership_content_rebroadcast_status"; "membership_content_stats";
    "membership_legends_leaderboard"; "membership_media_management_delete"; "membership_media_management_stats";
    "membership_media_management_uploads"; "membership_premium_leaderboard"; "membership_recover_contact_list";
    "membership_recovery_contact_lists"; "multi_kind_mega_feed_directive"; "multi_kind_thread_view"; "mutelist"; "mutelists";
    "mutual_follows"; "network_stats"; "nip19_decode"; "nostr_stats"; "note_mentions"; "note_mentions_count";
    "parameterized_replaceable_list"; "parametrized_replaceable_event"; "parametrized_replaceable_events"; "parse_advanced_search_query";
    "poll_votes"; "relays"; "replaceable_event"; "report_note"; "report_user"; "reset_directmsg_count"; "reset_directmsg_counts";
    "scored"; "scored_users"; "scored_users_24h"; "search"; "search_filterlist"; "server_name"; "set_app_settings"; "set_app_subsettings";
    "set_last_time_user_was_online"; "set_notifications_seen"; "thread_view"; "top_article"; "trending_hashtags"; "trending_hashtags_4h";
    "trending_hashtags_7d"; "trending_images"; "trending_images_4h"; "trusted_users"; "update_push_notification_token";
    "update_push_notification_token_for_nip46"; "upload"; "upload_cancel"; "upload_chunk"; "upload_complete"; "user_followers";
    "user_infos"; "user_of_ln_address"; "user_profile"; "user_profile_followed_by"; "user_profile_scored_content";
    "user_profile_scored_media_thumbnails"; "user_search"; "user_zaps"; "user_zaps_by_satszapped"; "user_zaps_sent"; "zaps_feed" ]

(* the explore specs reach scored_content with usepgfuncs + apply_humaness_check (mega_feed_directive
   is in app_funcalls_with_pgfuncs) *)
let mega_explore (ctx : ctx) (kwargs : Kw.t) ~timeframe ~created_after ?(grouped = false) ?(limit = None) ?kinds () : outcome =
  let a = scored_args_of_kw kwargs ~timeframe ~scope_pubkeys:[] ~pg:true ~humaness:true in
  let a = { a with created_after; kinds = (match kinds with Some k -> Some k | None -> a.kinds) } in
  let a = if grouped then { a with group_by_pubkey = true; limit = Option.value limit ~default:100 } else a in
  match scored_content ctx a with Some msgs -> Handled (messages msgs) | None -> julia_error

let rec mega_feed_directive ?(depth = 0) (ctx : ctx) (kw : Kw.t) : outcome =
  match parse_spec kw with
  | `Missing -> Not_handled
  | `Invalid -> Notice "invalid spec format"
  | `Spec (s, kwargs) -> (
      let sg k = Kw.str s k ~default:"" in
      let id = sg "id" and kind = sg "kind" in
      let skwa = Kw.fields (Kw.remove (Kw.remove s "id") "kind") in
      let merged = Kw.merge kwargs skwa in
      let hours () = Kw.int s "hours" ~default:24 in
      let first_kind = match Kw.member s "kinds" with `List (`Int k :: _) -> Some [ k ] | _ -> None in
      if Kw.has s "dvm_pubkey" && Kw.has s "dvm_id" then Not_handled
      else if id = "nostr-reads-feed" || id = "advsearch" then Not_handled
      else if id = "reads-feed" || kind = "reads" then mega_feed_directive_basic ctx kw
      else if kind = "notes" then begin
        match id with
        | "latest" | "feed" -> mega_feed_directive_basic ctx kw
        | "global-trending" -> mega_explore ctx kwargs ~timeframe:"trending" ~created_after:(now () - (hours () * 3600)) ()
        | "all-notes" -> mega_explore ctx kwargs ~timeframe:"latest" ~created_after:0 ()
        | "most-zapped" -> mega_explore ctx kwargs ~timeframe:"mostzapped" ~created_after:(now () - (hours () * 3600)) ~grouped:true ()
        | "video-reels" | "wide-net-notes" | "strange-but-popular" | "engaging-discussions" | "only-tweets" | "bookmarked-by-follows"
        | "important-notes-i-might-have-missed" | "search" | "muted-threads" ->
            Not_handled
        | _ -> Handled empty
      end
      else
        match id with
        | "explore-media" | "wide-net-notes" -> Not_handled
        | "explore-zaps" -> explore_zaps ctx merged
        | "hall-of-fame-notes" -> mega_explore ctx kwargs ~timeframe:"trending" ~created_after:0 ()
        | "only-tweets" | "bookmarked-notes" | "important-notes-i-might-have-missed" -> Handled empty
        | _ when List.mem id julia_exposed -> !dispatch_by_name ctx id merged
        | _ when first_kind <> None -> (
            let one_kind = Kw.member s "kinds" |> function `List (k :: _) -> `List [ k ] | v -> v in
            match id with
            | "latest" ->
                let user = match Kw.member kwargs "user_pubkey" with `Null -> raise (Kw.Invalid "user_pubkey argument required") | v -> v in
                feed ctx (Kw.set (Kw.set kwargs "pubkey" user) "kinds" one_kind)
            | "global-trending" -> mega_explore ctx kwargs ~timeframe:"trending" ~created_after:(now () - (hours () * 3600)) ?kinds:first_kind ()
            | "all-notes" -> mega_explore ctx kwargs ~timeframe:"latest" ~created_after:0 ?kinds:first_kind ()
            | "most-zapped" -> mega_explore ctx kwargs ~timeframe:"mostzapped" ~created_after:(now () - (hours () * 3600)) ~grouped:true ?kinds:first_kind ()
            | "feed" -> feed ctx (Kw.set (Kw.merge kwargs skwa) "kinds" one_kind)
            | _ -> Handled empty)
        | _ -> (
            (* advanced-feeds.json: {"id", "specification"} entries *)
            match Files.read_opt (cm_file ctx "advanced-feeds.json") with
            | Some txt when depth < 2 -> (
                match Yojson.Safe.from_string txt with
                | `List feeds -> (
                    let spec =
                      List.find_map
                        (function
                          | `Assoc f when List.assoc_opt "id" f = Some (`String id) -> (
                              match List.assoc_opt "specification" f with Some (`String sp) -> Some sp | _ -> None)
                          | _ -> None)
                        feeds
                    in
                    match spec with
                    | Some sp -> mega_feed_directive ~depth:(depth + 1) ctx (Kw.set kwargs "spec" (`String sp))
                    | None -> Handled empty)
                | _ -> Handled empty
                | exception _ -> Handled empty)
            | _ -> Handled empty))

let multi_kind_mega_feed_directive (ctx : ctx) (kw : Kw.t) : outcome =
  match parse_spec kw with
  | `Missing -> Not_handled
  | `Invalid -> Notice "invalid spec format"
  | `Spec (s, kwargs) -> (
      let kinds = match Kw.member kwargs "kinds" with `Null -> Kw.member s "kinds" | k -> k in
      let id = Kw.str s "id" ~default:"" and kind = Kw.str s "kind" ~default:"" in
      match kinds with
      | `List (_ :: _) -> (
          let kinds_l = match kinds with `List l -> List.filter_map (function `Int k -> Some k | _ -> None) l | _ -> [] in
          match id with
          | "latest" when List.mem kind [ "photos"; "short_videos"; "media" ] -> Not_handled (* advanced_search *)
          | "global-trending" -> mega_explore ctx kwargs ~timeframe:"trending" ~created_after:(now () - (Kw.int s "hours" ~default:24 * 3600)) ~kinds:kinds_l ()
          | "all-notes" -> mega_explore ctx kwargs ~timeframe:"latest" ~created_after:0 ~kinds:kinds_l ()
          | "most-zapped" -> mega_explore ctx kwargs ~timeframe:"mostzapped" ~created_after:(now () - (Kw.int s "hours" ~default:24 * 3600)) ~grouped:true ~kinds:kinds_l ()
          | _ -> multi_kind_mega_feed_directive_basic ctx kw)
      | _ -> mega_feed_directive ctx kw)

(* {1 Phase 4c: the long tail} *)

(* Julia user_infos_1 from memory: metadata events, USER_SCORES of the ones found,
   USER_FOLLOWER_COUNTS of every pubkey asked, verified names, media and previews *)
let user_infos_mem (c : Db.cache Db.conn) (hexes : string list) : string list =
  if hexes = [] then counts_msg ~always:true Kind.user_follower_counts []
  else
    let found, cards = user_cards c hexes in
    let mds = List.filter (fun m -> match kind_and_pubkey m with Some 0, _ -> true | _ -> false) cards in
    let rest = List.filter (fun m -> match kind_and_pubkey m with Some 0, _ -> false | _ -> true) cards in
    mds @ counts_msg Kind.user_scores (follower_counts c found)
    @ counts_msg ~always:true Kind.user_follower_counts (follower_counts c hexes)
    @ verified_names c hexes @ rest

let hex_list_json (hexes : string list) = Queries.hexes_json hexes

(* response_messages_for_zaps with its order and the optional kinds filter *)
let zap_feed_messages ?kinds ~(order_by : string) (c : Db.cache Db.conn) (zaps : Queries.zap_row list) : string list =
  let msgs =
    match order_by with
    | "amount_sats" -> zap_messages c zaps
    | _ ->
        let without_range = List.filter (fun m -> match kind_and_pubkey m with Some k, _ when k = Kind.range -> false | _ -> true) (zap_messages c zaps) in
        without_range @ [ range_msg ~order_by:"created_at" (List.map (fun (z : Queries.zap_row) -> (Hex_util.encode z.zap_receipt_id, z.zr_created_at)) zaps) ]
  in
  match kinds with
  | None -> msgs
  | Some ks -> List.filter (fun m -> match kind_and_pubkey m with Some k, _ -> List.mem k ks | None, _ -> false) msgs

let sort_zaps_desc ~(by : Queries.zap_row -> int64) ~limit (zaps : Queries.zap_row list) =
  List.stable_sort (fun a b -> compare (by b) (by a)) zaps |> List.filteri (fun i _ -> i < limit)

(* {2 direct messages} *)

let get_directmsgs (ctx : ctx) (kw : Kw.t) : outcome =
  match Kw.member kw "sender" with
  | `Null -> Handled empty
  | _ ->
      let receiver = Kw.hex32_exn kw "receiver" and sender = Kw.hex32_exn kw "sender" in
      let since = Kw.int kw "since" ~default:0 and until = Kw.int kw "until" ~default:(now ()) in
      let limit = Kw.int kw "limit" ~default:20 and offset = Kw.int kw "offset" ~default:0 in
      with_cache ctx (fun c ->
          let rows = Queries.directmsgs c ~receiver ~sender ~since ~until ~limit ~offset in
          let evs = if rows = [] then [] else Queries.events_by_ids c ~event_ids_json:(hex_list_json (List.map fst rows)) in
          let events = List.filter_map (fun (eid, _) -> List.assoc_opt eid evs) rows in
          let pks = List.sort_uniq compare [ Hex_util.encode receiver; Hex_util.encode sender ] in
          let _, cards = user_cards c pks in
          Handled
            (messages
               (events @ cards @ verified_names c pks @ [ range_msg ~order_by:"created_at" (List.filter (fun (eid, _) -> List.mem_assoc eid evs) rows) ])))

(* app.jl get_directmsg_contacts_2 *)
let get_directmsg_contacts (ctx : ctx) (kw : Kw.t) : outcome =
  let user = Kw.hex32_exn kw "user_pubkey" in
  let relation = Kw.str kw "relation" ~default:"any" in
  if not (List.mem relation [ "any"; "follows"; "other" ]) then julia_error
  else
    let limit = min 300 (Kw.int kw "limit" ~default:10000) and offset = Kw.int kw "offset" ~default:0 in
    let since = Kw.int kw "since" ~default:0 and until = Kw.int kw "until" ~default:(now ()) in
    with_cache ctx (fun c ->
        let rows = Queries.directmsg_contacts_in c ~user ~since ~until @ Queries.directmsg_contacts_out c ~user ~since ~until in
        let follows = List.map fst (Queries.follows_with_counts c ~pubkey:user) |> SS.of_list in
        let peers = List.map (fun (r : Queries.dm_contact) -> r.peer) rows |> List.sort_uniq compare in
        let blocked =
          if peers = [] then SS.empty
          else
            SS.of_list
              (Queries.hidden_pubkeys_default c ~scope:"content" ~pubkeys_json:(hex_list_json peers) ~author_exempt:None
              |> List.filter (fun _ -> false))
        in
        ignore blocked;
        let csam = Hashtbl.create 16 in
        List.iter (fun pk -> if Queries.is_user_blocked c ~pubkey:(Hex_util.decode_exn pk) then Hashtbl.replace csam pk ()) peers;
        let d : (string, int64 * int64 * string option) Hashtbl.t = Hashtbl.create 64 in
        let order = ref [] in
        List.iter
          (fun (r : Queries.dm_contact) ->
            if Hashtbl.mem csam r.peer then ()
            else if relation = "follows" && not (SS.mem r.peer follows) then ()
            else if relation = "other" && SS.mem r.peer follows then ()
            else
              match Hashtbl.find_opt d r.peer with
              | None ->
                  order := r.peer :: !order;
                  Hashtbl.replace d r.peer (r.dm_cnt, r.latest_at, r.latest_event_id)
              | Some (cnt, at, eid) ->
                  let at, eid = if at < r.latest_at then (r.latest_at, r.latest_event_id) else (at, eid) in
                  Hashtbl.replace d r.peer (max cnt r.dm_cnt, at, eid))
          rows;
        let items =
          List.rev_map (fun pk -> let cnt, at, eid = Hashtbl.find d pk in (pk, cnt, at, eid)) !order
          |> List.stable_sort (fun (_, _, a, _) (_, _, b, _) -> compare b a)
          |> List.filteri (fun i _ -> i >= offset && i < offset + limit)
        in
        let eids = List.filter_map (fun (_, _, _, eid) -> eid) items in
        let evs = if eids = [] then [] else Queries.events_by_ids c ~event_ids_json:(hex_list_json eids) in
        let events = List.filter_map (fun (_, _, _, eid) -> Option.bind eid (fun e -> List.assoc_opt e evs)) items in
        let peer_hexes = List.map (fun (pk, _, _, _) -> pk) items in
        let _, cards = user_cards c peer_hexes in
        let counts =
          content_msg Kind.directmsg_counts
            (Yojson.Safe.to_string
               (`Assoc
                 (List.map
                    (fun (pk, cnt, at, eid) ->
                      ( pk,
                        `Assoc [ ("cnt", i64json cnt); ("latest_at", i64json at); ("latest_event_id", match eid with Some e -> `String e | None -> `Null) ] ))
                    items)))
        in
        Handled
          (messages
             ((counts :: events) @ verified_names c peer_hexes @ cards
             @ [ range_msg ~order_by:"latest_at" (List.map (fun (pk, _, at, _) -> (pk, at)) items) ])))

let reset_directmsg_count (ctx : ctx) (kw : Kw.t) : outcome =
  match event_from_user kw with
  | Error _ -> julia_error
  | Ok e ->
      let sender = match Kw.member kw "sender" with `Null -> None | _ -> Some (Kw.hex32_exn kw "sender") in
      with_cache ctx (fun c ->
          match Queries.directmsg_cnt c ~receiver:e.Nostr.pubkey ~sender with
          | Some by ->
              Queries.reset_directmsg_count c ~receiver:e.Nostr.pubkey ~sender ~by;
              Queries.reset_directmsg_count c ~receiver:e.Nostr.pubkey ~sender:None ~by
          | None -> ());
      Handled empty

let reset_directmsg_counts (ctx : ctx) (kw : Kw.t) : outcome =
  match event_from_user kw with
  | Error _ -> julia_error
  | Ok e ->
      with_cache ctx (fun c -> Queries.reset_directmsg_counts c ~receiver:e.Nostr.pubkey);
      Handled empty

(* {2 zaps} *)

let zaps_feed (ctx : ctx) (kw : Kw.t) : outcome =
  let limit = Kw.int kw "limit" ~default:20 in
  if limit > 1000 then julia_error
  else
    let limit = min 50 limit in
    let pubkeys = hex32_list_exn kw "pubkeys" in
    let since = Kw.int kw "since" ~default:0 and until = Kw.int kw "until" ~default:(now ()) in
    let offset = Kw.int kw "offset" ~default:0 in
    let kinds = Kw.int_list_opt kw "kinds" in
    with_cache ctx (fun c ->
        let zaps = if pubkeys = [] then [] else Queries.zaps_of_pubkeys c ~pubkeys_json:(Queries.raws_json pubkeys) ~since ~until ~limit ~offset in
        let zaps = sort_zaps_desc ~by:(fun z -> z.Queries.zr_created_at) ~limit zaps in
        Handled (messages (zap_feed_messages ?kinds ~order_by:"created_at" c zaps)))

let user_zaps (ctx : ctx) (kw : Kw.t) : outcome =
  let limit = Kw.int kw "limit" ~default:20 in
  if limit > 1000 then julia_error
  else
    let limit = min 50 limit in
    let since = Kw.int kw "since" ~default:0 and until = Kw.int kw "until" ~default:(now ()) in
    let offset = Kw.int kw "offset" ~default:0 in
    let kinds = Kw.int_list_opt kw "kinds" in
    match (Kw.member kw "sender", Kw.member kw "receiver") with
    | `Null, `Null -> julia_error
    | `String _, _ ->
        let sender = Kw.hex32_exn kw "sender" in
        with_cache ctx (fun c ->
            let zaps = sort_zaps_desc ~by:(fun z -> z.Queries.zr_created_at) ~limit (Queries.zaps_by_sender c ~sender ~since ~until ~limit ~offset) in
            Handled (messages (zap_feed_messages ?kinds ~order_by:"created_at" c zaps)))
    | _ ->
        let receiver = Kw.hex32_exn kw "receiver" in
        with_cache ctx (fun c ->
            let zaps = sort_zaps_desc ~by:(fun z -> z.Queries.zr_created_at) ~limit (Queries.zaps_by_receiver c ~receiver ~since ~until ~limit ~offset) in
            Handled (messages (zap_feed_messages ?kinds ~order_by:"created_at" c zaps)))

let user_zaps_by_satszapped (ctx : ctx) (kw : Kw.t) : outcome =
  let limit = Kw.int kw "limit" ~default:20 in
  if limit > 1000 then julia_error
  else
    let receiver = Kw.hex32_exn kw "receiver" in
    let since = Kw.int kw "since" ~default:0 and until = Kw.int kw "until" ~default:100_000_000_000 in
    let offset = Kw.int kw "offset" ~default:0 in
    with_cache ctx (fun c ->
        let zaps = sort_zaps_desc ~by:(fun z -> z.Queries.amount_sats) ~limit (Queries.zaps_by_receiver_amount c ~receiver ~since ~until ~limit ~offset) in
        Handled (messages (zap_feed_messages ~order_by:"amount_sats" c zaps)))

let user_zaps_sent (ctx : ctx) (kw : Kw.t) : outcome =
  let limit = Kw.int kw "limit" ~default:20 in
  if limit > 1000 then julia_error
  else
    let sender = Kw.hex32_exn kw "sender" in
    let since = Kw.int kw "since" ~default:0 and until = Kw.int kw "until" ~default:(now ()) in
    let offset = Kw.int kw "offset" ~default:0 in
    with_cache ctx (fun c ->
        let zaps = sort_zaps_desc ~by:(fun z -> z.Queries.zr_created_at) ~limit (Queries.zaps_by_sender c ~sender ~since ~until ~limit ~offset) in
        Handled (messages (zap_feed_messages ~order_by:"created_at" c zaps)))

(* {2 users and events} *)

let event_actions (ctx : ctx) (kw : Kw.t) : outcome =
  let kind = Kw.int_exn kw "kind" in
  let limit = Kw.int kw "limit" ~default:100 and offset = Kw.int kw "offset" ~default:0 in
  if limit > 1000 then julia_error
  else
    with_cache ctx (fun c ->
        let refs =
          match (Kw.member kw "event_id", Kw.member kw "pubkey", Kw.member kw "identifier") with
          | `String _, _, _ -> Queries.event_action_refs c ~event_id:(Kw.hex32_exn kw "event_id") ~kind ~limit ~offset
          | `Null, `String _, `String identifier -> Queries.event_action_refs_article c ~pubkey:(Kw.hex32_exn kw "pubkey") ~identifier ~kind ~limit ~offset
          | _ -> []
        in
        let eids = List.map fst refs and pks = List.map snd refs |> List.sort_uniq compare in
        let evs = if eids = [] then [] else Queries.events_by_ids c ~event_ids_json:(hex_list_json eids) in
        let events = List.filter_map (fun eid -> List.assoc_opt eid evs) eids in
        Handled (messages (events @ user_infos_mem c pks)))

let user_followers (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" in
  let limit = Kw.int kw "limit" ~default:200 in
  if limit > 1000 then julia_error
  else
    with_cache ctx (fun c ->
        let add acc pk = if List.length acc >= limit || List.mem pk acc then acc else acc @ [ pk ] in
        let pks = List.fold_left add [] (Queries.user_followers_mutual c ~pubkey) in
        let pks = if List.length pks < limit then List.fold_left add pks (Queries.user_followers_top c ~pubkey ~limit:(limit - List.length pks)) else pks in
        Handled (messages (if pks = [] then [] else Queries.user_infos c ~pubkeys_json:(hex_list_json pks))))

let mutual_follows (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" and user_pubkey = Kw.hex32_exn kw "user_pubkey" in
  with_cache ctx (fun c -> Handled (messages (user_infos_mem c (List.sort_uniq compare (Queries.mutual_follows c ~pubkey ~user_pubkey)))))

let find_reposts (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" and event_id = Kw.hex32_exn kw "event_id" in
  Handled (messages (with_cache ctx (fun c -> Queries.reposts_of c ~pubkey ~event_id)))

let p_tag_pubkeys ?(exactly_two = false) (event_json : string) : string list =
  match Yojson.Safe.from_string event_json with
  | `Assoc f -> (
      match List.assoc_opt "tags" f with
      | Some (`List tags) ->
          List.filter_map
            (function
              | `List (`String "p" :: `String pk :: rest) when (not exactly_two || rest = []) && String.length pk = 64 && Hex_util.decode_opt pk <> None ->
                  Some (String.lowercase_ascii pk)
              | _ -> None)
            tags
      | _ -> [])
  | _ -> []
  | exception _ -> []

let follow_list (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" and identifier = Kw.str_exn kw "identifier" in
  with_cache ctx (fun c ->
      match Queries.parametrized_event_ids c ~pubkey ~kind:39089 ~identifier with
      | [] -> julia_error
      | eid :: _ -> (
          match Queries.events_by_ids c ~event_ids_json:(hex_list_json [ eid ]) with
          | (_, e) :: _ ->
              let pks = List.sort_uniq compare (p_tag_pubkeys e) in
              Handled (messages (e :: (if pks = [] then [] else Queries.user_infos c ~pubkeys_json:(hex_list_json pks))))
          | [] -> julia_error))

(* app.jl follow_lists: the whitelisted packs (explore-follow-packs.json) or recent kind-39089 lists *)
let follow_lists (ctx : ctx) (kw : Kw.t) : outcome =
  let since = Kw.int kw "since" ~default:0 and until = Kw.int kw "until" ~default:(now ()) in
  let limit = min 20 (Kw.int kw "limit" ~default:5) and offset = Kw.int kw "offset" ~default:0 in
  with_cache ctx (fun c ->
      let whitelist =
        match Files.read_opt (cm_file ctx "explore-follow-packs.json") with
        | None -> None
        | Some s -> (
            match Yojson.Safe.from_string s with
            | `List entries ->
                Some
                  (List.filter_map
                     (function
                       | `Assoc f -> (
                           match List.assoc_opt "follow_pack" f with
                           | Some (`String np) -> (
                               match Bech32.nip19_decode np with Some (Bech32.Nevent eid) | Some (Bech32.Note eid) -> Some (Hex_util.encode eid) | _ -> None)
                           | _ -> None)
                       | _ -> None)
                     entries)
            | _ -> None
            | exception _ -> None)
      in
      let events =
        match whitelist with
        | Some eids ->
            let evs = if eids = [] then [] else Queries.events_by_ids c ~event_ids_json:(hex_list_json eids) in
            let all = List.filter_map (fun eid -> List.assoc_opt eid evs) eids in
            let in_range e =
              match Yojson.Safe.from_string e with
              | `Assoc f -> ( match List.assoc_opt "created_at" f with Some (`Int t) -> t >= since && t <= until | _ -> false)
              | _ -> false
              | exception _ -> false
            in
            List.filter in_range all |> List.filteri (fun i _ -> i >= offset && i < offset + limit)
        | None ->
            Queries.follow_packs c ~since ~until ~limit ~offset
            |> List.filter (fun e ->
                   match Yojson.Safe.from_string e with
                   | `Assoc f -> ( match List.assoc_opt "tags" f with Some (`List tags) -> List.exists (function `List (`String "image" :: _ :: _) -> true | _ -> false) tags | _ -> false)
                   | _ -> false
                   | exception _ -> false)
      in
      if events = [] then Handled empty
      else begin
        let res = ref [] and pks = ref [] and es = ref [] in
        List.iter
          (fun e ->
            res := e :: !res;
            (match Yojson.Safe.from_string e with
            | `Assoc f -> (
                (match (List.assoc_opt "id" f, List.assoc_opt "created_at" f) with
                | Some (`String id), Some (`Int t) ->
                    res := List.rev_append (Queries.event_media_response c ~event_id:(Hex_util.decode_exn id)) !res;
                    es := (id, Int64.of_int t) :: !es
                | _ -> ());
                match List.assoc_opt "pubkey" f with Some (`String pk) -> pks := pk :: !pks | _ -> ())
            | _ -> ()
            | exception _ -> ());
            let followed = p_tag_pubkeys e in
            if followed <> [] then pks := Queries.most_followed_of c ~pubkeys_json:(hex_list_json followed) ~limit:5 @ !pks)
          events;
        let pks = List.sort_uniq compare !pks in
        Handled (messages (List.rev !res @ Queries.user_infos c ~pubkeys_json:(hex_list_json pks) @ [ range_msg ~order_by:"created_at" (List.rev !es) ]))
      end)

(* app.jl parametrized_replaceable_events_extended_response *)
let p_tag_extended (c : Db.cache Db.conn) (events : string list) : string list =
  let pks = List.concat_map (p_tag_pubkeys ~exactly_two:true) events |> List.sort_uniq compare in
  if pks = [] then []
  else
    let found, cards = user_cards c pks in
    let mds = List.filter (fun m -> match kind_and_pubkey m with Some 0, _ -> true | _ -> false) cards in
    let rest = List.filter (fun m -> match kind_and_pubkey m with Some 0, _ -> false | _ -> true) cards in
    mds @ counts_msg Kind.user_scores (follower_counts c found) @ rest @ verified_names c found

let parameterized_replaceable_list (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" and identifier = Kw.str_exn kw "identifier" in
  let extended = Kw.bool kw "extended_response" ~default:true in
  with_cache ctx (fun c ->
      let eids = Queries.param_list_event_ids c ~pubkey ~identifier in
      let evs = if eids = [] then [] else Queries.events_by_ids c ~event_ids_json:(hex_list_json eids) in
      let events = List.filter_map (fun eid -> List.assoc_opt eid evs) eids in
      Handled (messages (events @ if extended then p_tag_extended c events else [])))

let parametrized_replaceable_event_one (c : Db.cache Db.conn) ~pubkey ~kind ~identifier ~extended ~user_pubkey : string list =
  let eids = Queries.parametrized_event_ids c ~pubkey ~kind ~identifier in
  let evs = if eids = [] then [] else Queries.events_by_ids c ~event_ids_json:(hex_list_json eids) in
  let events = List.filter_map (fun eid -> List.assoc_opt eid evs) eids in
  let extra =
    if extended && events <> [] then
      p_tag_extended c events @ rmfp c ~user_pubkey (List.map fst evs)
    else []
  in
  List.fold_left (fun acc m -> if List.mem m acc then acc else m :: acc) [] (events @ extra) |> List.rev

let parametrized_replaceable_event (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" and kind = Kw.int_exn kw "kind" and identifier = Kw.str_exn kw "identifier" in
  let extended = Kw.bool kw "extended_response" ~default:true in
  let user_pubkey = user_pubkey_opt kw in
  with_cache ctx (fun c -> Handled (messages (parametrized_replaceable_event_one c ~pubkey ~kind ~identifier ~extended ~user_pubkey)))

let parametrized_replaceable_events (ctx : ctx) (kw : Kw.t) : outcome =
  let extended = Kw.bool kw "extended_response" ~default:true in
  match Kw.member kw "events" with
  | `List items ->
      with_cache ctx (fun c ->
          Handled
            (messages
               (List.concat_map
                  (fun item ->
                    let pubkey = Kw.hex32_exn item "pubkey" and kind = Kw.int_exn item "kind" and identifier = Kw.str_exn item "identifier" in
                    parametrized_replaceable_event_one c ~pubkey ~kind ~identifier ~extended ~user_pubkey:None)
                  items)))
  | _ -> raise (Kw.Invalid "events required")

(* {2 filterlist} *)

let check_filterlist (ctx : ctx) (kw : Kw.t) : outcome =
  let pks = hex32_list_exn kw "pubkeys" |> List.map Hex_util.encode |> List.sort_uniq compare in
  let hidden = if pks = [] then [] else with_cache ctx (fun c -> Queries.filterlist_hidden_pubkeys c ~pubkeys_json:(hex_list_json pks)) in
  Handled (messages [ content_msg Kind.filterlisted (Yojson.Safe.to_string (`Assoc [ ("pubkeys", `List (List.map (fun p -> `String p) hidden)) ])) ])

(* app.jl is_hidden(est, user, scope, pk): only the trending scope hides (the blocked nip05 domains) *)
let is_hidden_by_content_moderation (ctx : ctx) (kw : Kw.t) : outcome =
  let scope = Kw.str kw "scope" ~default:"content" in
  let pks = match Kw.member kw "pubkeys" with `Null -> [] | _ -> hex32_list_exn kw "pubkeys" |> List.map Hex_util.encode in
  let eids = match Kw.member kw "event_ids" with `Null -> [] | _ -> hex32_list_exn kw "event_ids" |> List.map Hex_util.encode in
  let domains_json = Yojson.Safe.to_string (`List (List.map (fun d -> `String d) ctx.cfg.trending_blocked_domains)) in
  with_cache ctx (fun c ->
      let authors = if eids = [] then [] else Queries.event_authors c ~event_ids_json:(hex_list_json eids) in
      let candidates = List.sort_uniq compare (pks @ List.map snd authors) in
      let hidden =
        if scope <> "trending" || candidates = [] then SS.empty
        else SS.of_list (Queries.domain_hidden_pubkeys c ~pubkeys_json:(hex_list_json candidates) ~domains_json)
      in
      let content =
        `Assoc
          [
            ("pubkeys", `Assoc (List.map (fun pk -> (pk, `Bool (SS.mem pk hidden))) pks));
            ("event_ids", `Assoc (List.map (fun eid -> (eid, `Bool (match List.assoc_opt eid authors with Some a -> SS.mem a hidden | None -> false))) eids));
          ]
      in
      Handled (messages [ content_msg Kind.is_hidden_by_content_moderation (Yojson.Safe.to_string content) ]))

(* {2 settings, misc} *)

(* app_ext.jl app_settings(): a kind-30078 event from the user; accessed_at and the log row *)
let with_app_settings (ctx : ctx) (kw : Kw.t) (f : Nostr.t -> outcome) : outcome =
  match event_from_user kw with
  | Error _ -> julia_error
  | Ok e when e.Nostr.kind <> Kind.app_settings -> julia_error
  | Ok e ->
      let r = f e in
      let event_json = match Kw.member kw "event_from_user" with `Null -> "{}" | v -> Yojson.Safe.to_string v in
      with_membership ctx (fun m -> Queries_mem.touch_app_settings m ~pubkey:e.Nostr.pubkey ~event_json ~now:(now ()));
      r

let get_app_settings_2 (ctx : ctx) (kw : Kw.t) : outcome =
  with_app_settings ctx kw (fun e ->
      match with_membership ctx (fun m -> Queries_mem.app_settings_event m ~pubkey:e.Nostr.pubkey) with
      | Some v -> Handled (messages [ v ])
      | None -> Handled empty)

let get_app_settings (ctx : ctx) (kw : Kw.t) : outcome =
  with_app_settings ctx kw (fun e ->
      match with_membership ctx (fun m -> Queries_mem.app_settings_event m ~pubkey:e.Nostr.pubkey) with
      | Some v -> Handled (messages [ v ])
      | None ->
          (* the default settings as a zero-signed event, stored as the user's settings *)
          let client = match List.nth_opt e.Nostr.tags 0 with Some (_ :: `String c :: _) -> c | _ -> raise (Kw.Invalid "client tag") in
          let content = Files.read (cm_file ctx "default-settings.json") in
          let zeros n = String.make n '0' in
          let ev =
            `Assoc
              [
                ("id", `String (zeros 64));
                ("pubkey", `String (zeros 64));
                ("created_at", `Int (now ()));
                ("kind", `Int Kind.primal_settings);
                ("tags", `List [ `List [ `String "d"; `String client ] ]);
                ("content", `String content);
                ("sig", `String (zeros 128));
              ]
          in
          let v = Yojson.Safe.to_string ev in
          with_membership ctx (fun m -> Queries_mem.insert_app_settings m ~pubkey:e.Nostr.pubkey ~value:v ~event_id:(String.make 32 '\000') ~now:(now ()));
          Handled (messages [ v ]))

let user_of_ln_address (ctx : ctx) (kw : Kw.t) : outcome =
  let ln_address = Kw.str_exn kw "ln_address" in
  with_cache ctx (fun c ->
      match Queries.ln_address_pubkey c ~ln_address with
      | None -> Handled empty
      | Some pk ->
          let hex = Hex_util.encode pk in
          Handled (messages (content_msg Kind.user_pubkey (Yojson.Safe.to_string (`Assoc [ ("pubkey", `String hex) ])) :: user_infos_mem c [ hex ])))

let set_last_time_user_was_online (ctx : ctx) (kw : Kw.t) : outcome =
  match event_from_user kw with
  | Error _ -> julia_error
  | Ok e -> (
      match int_of_string_opt (String.trim e.Nostr.content) with
      | None -> julia_error
      | Some t ->
          with_membership ctx (fun m -> Queries_mem.set_last_online m ~pubkey:e.Nostr.pubkey ~online_at:t);
          Handled empty)

let report_id (ctx : ctx) (kw : Kw.t) ~typ ~id : outcome =
  match event_from_user kw with
  | Error _ -> julia_error
  | Ok e ->
      with_membership ctx (fun m -> Queries_mem.report m ~pubkey:e.Nostr.pubkey ~typ ~id ~now:(now ()));
      Handled empty

let report_user (ctx : ctx) (kw : Kw.t) : outcome = report_id ctx kw ~typ:1 ~id:(Kw.hex32_exn kw "pubkey")
let report_note (ctx : ctx) (kw : Kw.t) : outcome = report_id ctx kw ~typ:2 ~id:(Kw.hex32_exn kw "event_id")

let relays (ctx : ctx) (kw : Kw.t) : outcome =
  let limit = Kw.int kw "limit" ~default:20 in
  let rows = with_cache ctx (fun c -> Queries.relays_top c ~limit) in
  Handled (messages [ content_msg Kind.relays (Yojson.Safe.to_string (`Assoc (List.map (fun (u, n) -> (u, i64json n)) rows))) ])

let trusted_users (ctx : ctx) (kw : Kw.t) : outcome =
  let limit = min 10000 (Kw.int kw "limit" ~default:500) in
  with_cache ctx (fun c ->
      let rows = Queries.trustrank_top c ~limit in
      let head = content_msg Kind.trusted_users (Yojson.Safe.to_string (`List (List.map (fun (pk, tr) -> `Assoc [ ("pk", `String pk); ("tr", `Float tr) ]) rows))) in
      let mds = if rows = [] then [] else List.map snd (Queries.metadata_events c ~pubkeys_json:(hex_list_json (List.map fst rows))) in
      Handled (messages (head :: mds)))

let client_config (ctx : ctx) (_ : Kw.t) : outcome =
  Handled (messages [ content_msg Kind.show_primal_support (file_json_content (cm_file ctx "client-config.json") ~default:"null") ])

let network_stats (ctx : ctx) (_ : Kw.t) : outcome =
  match ctx.cfg.network_stats_url with
  | None -> Not_handled
  | Some url -> (
      match (Http.parse_url url, !net_ref) with
      | Some u, Some net -> (
          match
            Http.plain_request ~net ~clock:ctx.clock ~timeout:5.0 ~meth:"GET" ~body:{|["network_stats",{}]|} ~host:u.Http.host ~port:u.Http.port
              ~path:u.Http.path ()
          with
          | 200, body -> (
              match Yojson.Safe.from_string body with
              | `List [ _; content ] -> Handled (messages [ Yojson.Safe.to_string (`Assoc [ ("kind", `Int Kind.net_stats); ("content", content) ]) ])
              | _ -> julia_error)
          | _ -> julia_error)
      | _ -> Not_handled)

(* {2 articles} *)

let articles_stats (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" and kind = Kw.int kw "kind" ~default:30023 in
  let articles, drafts, satszapped = with_cache ctx (fun c -> Queries.articles_stats c ~pubkey ~kind) in
  Handled
    (messages
       [ content_msg Kind.articles_stats (Yojson.Safe.to_string (`Assoc [ ("articles", i64json articles); ("drafts", i64json drafts); ("satszapped", i64json satszapped) ])) ])

let drafts (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" and kind = Kw.int_exn kw "kind" in
  let since = Kw.int kw "since" ~default:0 and until = Kw.int kw "until" ~default:(now ()) in
  let limit = min 100 (Kw.int kw "limit" ~default:20) and offset = Kw.int kw "offset" ~default:0 in
  Handled (messages (with_cache ctx (fun c -> Queries.drafts c ~pubkey ~kind ~since ~until ~limit ~offset)))

let top_article (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" and by = Kw.str_exn kw "by" in
  with_cache ctx (fun c ->
      match Queries.top_article_eid c ~pubkey ~by with
      | None -> Handled empty
      | Some eid -> (
          match Queries.events_by_ids c ~event_ids_json:(hex_list_json [ eid ]) with
          | [] -> Handled empty
          | (_, e) :: _ ->
              let stats =
                match Queries.reads_stats c ~eid:(Hex_util.decode_exn eid) with
                | Some (likes, replies, reposts, zaps, satszapped) ->
                    [
                      content_msg Kind.event_stats
                        (Yojson.Safe.to_string
                           (`Assoc
                             [
                               ("event_id", `String eid); ("likes", i64json likes); ("replies", i64json replies); ("mentions", `Int 0);
                               ("reposts", i64json reposts); ("zaps", i64json zaps); ("satszapped", i64json satszapped); ("score", `Int 0);
                               ("score24h", `Int 0); ("bookmarks", `Int 0);
                             ]));
                    ]
                | None -> []
              in
              Handled (messages (e :: stats))))

(* app.jl long_form_content_thread_view (usepgfuncs; apply_humaness_check forced false) *)
let long_form_content_thread_view (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" and kind = Kw.int_exn kw "kind" and identifier = Kw.str_exn kw "identifier" in
  let limit = Kw.int kw "limit" ~default:20 and since = Kw.int kw "since" ~default:0 in
  let until = Kw.int kw "until" ~default:(now ()) and offset = Kw.int kw "offset" ~default:0 in
  let user_pubkey = user_pubkey_opt kw in
  if limit > 1000 then julia_error
  else
    with_cache ctx (fun c ->
        match Queries.parametrized_event_ids c ~pubkey ~kind ~identifier with
        | [] -> Handled empty
        | eid :: _ -> (
            match Queries.events_by_ids c ~event_ids_json:(hex_list_json [ eid ]) with
            | [] -> Handled empty
            | (_, e) :: _ ->
                if Queries.hidden_events c ~event_ids_json:(hex_list_json [ eid ]) <> [] then Handled empty
                else begin
                  let created_at =
                    match Yojson.Safe.from_string e with `Assoc f -> ( match List.assoc_opt "created_at" f with Some (`Int t) -> t | _ -> 0) | _ -> 0 | exception _ -> 0
                  in
                  let parents = Queries.thread_parents c ~event_id:(Hex_util.decode_exn eid) in
                  let parent_msgs = if parents = [] then [] else rmfp c ~user_pubkey (List.map fst parents) in
                  let replies = Queries.lfc_replies c ~pubkey ~identifier ~since ~until ~limit ~offset in
                  (* Julia keeps only replies whose e/a tags are all "root" markers *)
                  let tags = if replies = [] then [] else Queries.event_tags_of c ~event_ids_json:(hex_list_json (List.map fst replies)) in
                  let is_direct reid =
                    match List.assoc_opt reid tags with
                    | None -> false
                    | Some t -> (
                        match Yojson.Safe.from_string t with
                        | `List tags ->
                            not
                              (List.exists
                                 (function
                                   | `List (`String ("e" | "a") :: rest) -> ( match List.nth_opt rest 2 with Some (`String "root") -> false | _ -> true)
                                   | _ -> false)
                                 tags)
                        | _ -> false
                        | exception _ -> false)
                  in
                  let replies = List.filter (fun (reid, _) -> is_direct reid) replies in
                  let posts_json =
                    Yojson.Safe.to_string
                      (`List (`List [ `String eid; `Int created_at ] :: List.map (fun (r, t) -> `List [ `String r; `Int (Int64.to_int t) ]) replies))
                  in
                  let enriched = Queries.enrich_posts c ~posts_json ~user_pubkey ~apply_humaness_check:false in
                  (* Julia's OrderedSet does not merge the in-memory objects with the SQL rows, so the
                     article and its parents appear once from each side *)
                  let mem = List.fold_left (fun acc m -> if List.mem m acc then acc else m :: acc) [] (e :: parent_msgs) |> List.rev in
                  Handled (messages (mem @ enriched))
                end))

let user_profile_scored_media_thumbnails (ctx : ctx) (kw : Kw.t) : outcome =
  let pubkey = Kw.hex32_exn kw "pubkey" in
  let limit = min 100 (Kw.int kw "limit" ~default:5) in
  let user_pubkey = user_pubkey_opt kw in
  with_cache ctx (fun c ->
      let eids = Queries.scored_media_eids c ~pubkey ~limit in
      Handled (messages (if eids = [] then [] else rmfp c ~user_pubkey eids)))

(* app.jl get_highlights (article form; event_id form raises in Julia) *)
let get_highlights (ctx : ctx) (kw : Kw.t) : outcome =
  match Kw.member kw "event_id" with
  | `Null -> (
      match (Kw.member kw "pubkey", Kw.member kw "identifier", Kw.member kw "kind") with
      | `String _, `String identifier, `Int kind ->
          let pubkey = Kw.hex32_exn kw "pubkey" in
          let user_pubkey = user_pubkey_opt kw in
          with_cache ctx (fun c ->
              let evts = Queries.article_highlights c ~pubkey ~identifier ~kind in
              let parsed = List.filter_map (fun e -> match Yojson.Safe.from_string e with `Assoc f -> Some (e, f) | _ -> None | exception _ -> None) evts in
              let fld f k = List.assoc_opt k f in
              let hs = List.filter_map (fun (e, f) -> match (fld f "kind", fld f "id") with Some (`Int 9802), Some (`String id) -> Some (id, (e, f)) | _ -> None) parsed in
              let groups : (string, string list) Hashtbl.t = Hashtbl.create 16 in
              let gorder = ref [] in
              List.iter
                (fun (_, f) ->
                  match (fld f "kind", fld f "id", fld f "tags") with
                  | Some (`Int 1), Some (`String id), Some (`List tags) ->
                      List.iter
                        (function
                          | `List (`String "q" :: `String qid :: _) -> (
                              match List.assoc_opt (String.lowercase_ascii qid) hs with
                              | Some (_, hf) ->
                                  let key = match fld hf "content" with Some (`String s) -> s | _ -> "" in
                                  if not (Hashtbl.mem groups key) then gorder := key :: !gorder;
                                  Hashtbl.replace groups key (Option.value (Hashtbl.find_opt groups key) ~default:[] @ [ id ])
                              | None -> ())
                          | _ -> ())
                        tags
                  | _ -> ())
                parsed;
              let hpks = List.filter_map (fun (_, (_, f)) -> match fld f "pubkey" with Some (`String p) -> Some p | _ -> None) hs |> List.sort_uniq compare in
              let mds = if hpks = [] then [] else List.map snd (Queries.metadata_events c ~pubkeys_json:(hex_list_json hpks)) in
              let groups_msg =
                content_msg Kind.highlight_groups
                  (Yojson.Safe.to_string (`Assoc (List.rev_map (fun k -> (k, `List (List.map (fun id -> `String id) (Hashtbl.find groups k)))) !gorder)))
              in
              let replies =
                List.concat_map
                  (fun (id, _) ->
                    let rs = Queries.event_replies c ~event_id:(Hex_util.decode_exn id) ~since:0 ~until:(now ()) ~limit:100 ~offset:0 in
                    if rs = [] then [] else rmfp c ~user_pubkey (List.map fst rs))
                  hs
              in
              Handled (messages (List.map (fun (_, (e, _)) -> e) hs @ mds @ [ groups_msg ] @ replies)))
      | _ -> Handled (messages [ content_msg Kind.highlight_groups "{}" ]))
  | _ -> julia_error

(* app_ext.jl get_suggested_users_2: suggested-accounts-v2.json *)
let get_suggested_users_2 (ctx : ctx) (_ : Kw.t) : outcome =
  match Files.read_opt (cm_file ctx "suggested-accounts-v2.json") with
  | None -> Handled empty
  | Some s -> (
      match Yojson.Safe.from_string s with
      | `List groups ->
          let pks = ref [] in
          let groups' =
            List.map
              (function
                | `Assoc g ->
                    let people =
                      match List.assoc_opt "people" g with
                      | Some (`List ps) ->
                          `List
                            (List.map
                               (function
                                 | `Assoc u ->
                                     let pk = match List.assoc_opt "pubkey" u with Some (`String p) -> p | _ -> "" in
                                     let pk =
                                       if String.length pk >= 4 && String.sub pk 0 4 = "npub" then
                                         match Bech32.nip19_decode pk with Some (Bech32.Npub raw) -> Hex_util.encode raw | _ -> pk
                                       else pk
                                     in
                                     pks := pk :: !pks;
                                     `Assoc (List.map (fun (k, v) -> if k = "pubkey" then (k, `String pk) else (k, v)) u)
                                 | v -> v)
                               ps)
                      | _ -> `List []
                    in
                    `Assoc (List.map (fun (k, v) -> if k = "people" then (k, people) else (k, v)) g)
                | v -> v)
              groups
          in
          with_cache ctx (fun c ->
              let hexes = List.sort_uniq compare (List.filter (fun p -> String.length p = 64) !pks) in
              let found, mds = if hexes = [] then ([], []) else List.split (Queries.metadata_events c ~pubkeys_json:(hex_list_json hexes)) in
              Handled
                (messages
                   ((content_msg Kind.suggested_users (Yojson.Safe.to_string (`List groups')) :: List.sort_uniq compare mds)
                   @ counts_msg Kind.user_scores (follower_counts c (List.sort_uniq compare found)))))
      | _ -> julia_error
      | exception _ -> julia_error)

(* {2 feed_2 / feed_directive_2} (app.jl feed_2: usepgfuncs) *)

let feed_2 (ctx : ctx) (kw : Kw.t) : outcome =
  let limit = Kw.int kw "limit" ~default:20 in
  if limit > 1000 then julia_error
  else
    let since = Kw.int kw "since" ~default:0 and until = Kw.int kw "until" ~default:(now ()) in
    let offset = Kw.int kw "offset" ~default:0 in
    let notes = Kw.str kw "notes" ~default:"follows" in
    let user_pubkey = user_pubkey_opt kw in
    let kinds = Option.value (Kw.int_list_opt kw "kinds") ~default:[ 1; 6 ] in
    match Kw.member kw "pubkey" with
    | `Null -> Handled empty
    | _ -> (
        let pubkey = Kw.hex32_exn kw "pubkey" in
        let include_replies = if Kw.bool kw "include_replies" ~default:false then 1 else 0 in
        let order = match Kw.str_opt kw "order" with Some o -> o | None -> if Kw.has kw "until" then "desc" else if Kw.has kw "since" then "asc" else "desc" in
        if not (List.mem order [ "asc"; "desc" ]) then julia_error
        else
          with_cache ctx (fun c ->
              let enrich posts =
                let posts = List.stable_sort (fun (_, a) (_, b) -> if order = "asc" then compare a b else compare b a) posts |> List.filteri (fun i _ -> i < limit) in
                let posts_json = Yojson.Safe.to_string (`List (List.map (fun (e, t) -> `List [ `String e; `Int (Int64.to_int t) ]) posts)) in
                let msgs = if posts = [] then [] else Queries.enrich_posts c ~posts_json ~user_pubkey ~apply_humaness_check:false in
                Handled (messages (msgs @ [ range_msg ~order_by:"created_at" posts ]))
              in
              match notes with
              | "replies" ->
                  Handled (messages (Queries.feed_user_authored c ~pubkey ~since ~until ~include_replies:1 ~limit ~offset ~user_pubkey ~apply_humaness_check:false ~kinds))
              | "authored" ->
                  if Queries.is_user_blocked c ~pubkey then Handled empty
                  else Handled (messages (Queries.feed_user_authored c ~pubkey ~since ~until ~include_replies ~limit ~offset ~user_pubkey ~apply_humaness_check:false ~kinds))
              | "follows" ->
                  if Queries.has_followers_row c ~pubkey then
                    Handled (messages (Queries.feed_user_follows c ~pubkey ~since ~until ~include_replies ~limit ~offset ~user_pubkey ~apply_humaness_check:false ~kinds))
                  else enrich []
              | "user_media_thumbnails" ->
                  if Queries.is_user_blocked c ~pubkey then Handled empty else enrich (Queries.media_note_ids c ~pubkey ~since ~until ~limit ~offset)
              | "bookmarks" -> Not_handled (* the bookmarks walk stays with Julia for now *)
              | _ -> julia_error))

(* app_ext.jl feed_directive_2 = feed_directive_ with feed_2 *)
let feed_directive_2 (ctx : ctx) (kw : Kw.t) : outcome =
  let directive = Kw.str_exn kw "directive" in
  let kwa = Kw.remove kw "directive" in
  let with_pk pk extra = feed_2 ctx (Kw.merge (Kw.set kwa "pubkey" (`String pk)) extra) in
  let is_pk pk = String.length pk = 64 && Hex_util.decode_opt pk <> None in
  if is_pk directive then with_pk directive []
  else
    match String.split_on_char ';' directive with
    | [ "authored"; pk ] when is_pk pk -> with_pk pk [ ("notes", `String "authored") ]
    | [ "authoredreplies"; pk ] when is_pk pk -> with_pk pk [ ("notes", `String "replies") ]
    | [ "withreplies"; pk ] when is_pk pk -> with_pk pk [ ("include_replies", `Bool true) ]
    | _ -> Not_handled

(* app.jl enrich_feed_events / app_ext.jl note_mentions through response_messages_for_posts *)
let enrich_feed_events (ctx : ctx) (kw : Kw.t) : outcome =
  let event_ids = hex32_list_exn kw "event_ids" in
  let user_pubkey = user_pubkey_opt kw in
  if event_ids = [] then Handled empty else with_cache ctx (fun c -> Handled (messages (rmfp c ~user_pubkey (List.map Hex_util.encode event_ids))))

let note_mentions (ctx : ctx) (kw : Kw.t) : outcome =
  let limit = Kw.int kw "limit" ~default:100 and offset = Kw.int kw "offset" ~default:0 in
  if limit > 1000 then julia_error
  else
    let user_pubkey = user_pubkey_opt kw in
    let answer c hexes = Handled (messages (if hexes = [] then [] else rmfp c ~user_pubkey (List.sort_uniq compare hexes))) in
    match (Kw.member kw "event_id", Kw.member kw "pubkey", Kw.member kw "identifier") with
    | `String _, _, _ -> let event_id = Kw.hex32_exn kw "event_id" in with_cache ctx (fun c -> answer c (Queries.note_mentions_event_ids c ~event_id ~limit ~offset))
    | `Null, `String _, `String identifier ->
        let pubkey = Kw.hex32_exn kw "pubkey" in
        with_cache ctx (fun c -> answer c (Queries.note_mentions_of_article_event_ids c ~pubkey ~identifier ~limit ~offset))
    | `Null, _, _ -> Handled empty
    | _ -> raise (Kw.Invalid "invalid event_id")
