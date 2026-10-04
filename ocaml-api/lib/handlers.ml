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

let feed (ctx : ctx) (kw : Kw.t) : outcome =
  let limit = Kw.int kw "limit" ~default:20 and since = Kw.int kw "since" ~default:0 in
  let until = Kw.int kw "until" ~default:(now ()) and offset = Kw.int kw "offset" ~default:0 in
  let pubkey = Kw.hex_any_opt kw "pubkey" |> Option.get in
  let user_pubkey = user_pubkey_or_primal ctx kw in
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
