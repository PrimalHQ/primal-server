(* Port of app.jl content_moderation_filtering_2: the per-result filter the Julia CacheServer applies
   to every funcall answer before sending (hidden/deleted events, the viewer's content-moderation
   rules per funcall scope, and the synthetic kinds that carry pubkeys in their content).

   Funcalls that Julia answers through SQL functions taking the viewer's pubkey
   (app_funcalls_with_pgfuncs with ENABLE_PGFUNCS) skip this filter in Julia; the Phase 3a
   handlers are those, so the dispatcher applies [filter] only to the Phase 3b funcalls.

   Julia's rules for NOTIFICATION and DIRECTMSG_COUNTS messages are not ported here: the funcalls
   that emit them (get_notifications, get_directmsg_contacts) are still proxied. *)

type scope = Content | Trending | No_scope

(* app.jl funcall_content_moderation_scope *)
let scope_of_funcall = function
  | "feed" | "feed_2" | "thread_view" | "get_directmsg_contacts" | "get_directmsgs" | "zaps_feed" | "user_zaps"
  | "user_zaps_by_satszapped" | "event_zaps_by_satszapped" | "get_bookmarks" | "get_highlights"
  | "long_form_content_feed" | "long_form_content_thread_view" | "mega_feed_directive"
  | "multi_kind_mega_feed_directive" | "search" | "advanced_feed" | "user_profile_scored_content" | "user_search"
  | "feed_directive" | "feed_directive_2" ->
      Content
  | "explore" | "explore_global_trending_24h" | "explore_global_mostzapped_4h" | "scored" | "scored_users"
  | "scored_users_24h" ->
      Trending
  | _ -> No_scope

let scope_name = function Content -> "content" | Trending -> "trending" | No_scope -> "content"

module SS = Set.Make (String)

type parsed = {
  text : string;
  fields : (string * Yojson.Safe.t) list; (* [] when not a JSON object *)
}

let parse text =
  match Yojson.Safe.from_string text with `Assoc f -> { text; fields = f } | _ -> { text; fields = [] } | exception _ -> { text; fields = [] }

let str_field p k = match List.assoc_opt k p.fields with Some (`String s) -> Some s | _ -> None
let int_field p k = match List.assoc_opt k p.fields with Some (`Int i) -> Some i | _ -> None
let is_hex64 s = String.length s = 64 && Hex_util.decode_opt s <> None
let hex_field p k = match str_field p k with Some s when is_hex64 s -> Some (String.lowercase_ascii s) | _ -> None

let content_json p =
  match str_field p "content" with Some s -> ( try Some (Yojson.Safe.from_string s) with _ -> None) | None -> None

(* content_moderation_filtering_2: authored_owner *)
let author_exempt (kw : Kw.t) : string option =
  if Kw.str kw "notes" ~default:"" = "authored" then Kw.hex32_opt kw "pubkey" else None

(* Julia is_hidden_ for a set of pubkeys. Julia compiles the viewer's settings (deep-merged over
   the defaults) into rules; the importer materialises those rules into the cmr_* tables that the
   SQL is_pubkey_hidden reads, but not for every user. So: a viewer whose settings switch content
   moderation off hides nothing; a viewer with compiled rules uses the SQL predicate; everyone
   else (no settings, settings without compiled rules, no viewer) gets Julia's default rules. *)
type viewer_rules = Off | Compiled | Default

let viewer_rules ~clock (c : Db.cache Db.conn) (u : string) : viewer_rules =
  let settings = Db.with_membership ~clock (fun m -> Queries_mem.app_settings_value m ~pubkey:u) in
  let switched_off =
    match settings with
    | None -> false
    | Some v -> (
        match Yojson.Safe.from_string v with
        | `Assoc f -> List.assoc_opt "applyContentModeration" f = Some (`Bool false)
        | _ -> false
        | exception _ -> false)
  in
  if switched_off then Off else if Queries.user_has_cmr c ~pubkey:u then Compiled else Default

let hidden_pubkeys ~clock (c : Db.cache Db.conn) ~(user_pubkey : string option) ~(scope : string) ~(hexes : string list)
    ~(author_exempt : string option) : SS.t =
  if hexes = [] then SS.empty
  else
    let pubkeys_json = Queries.hexes_json hexes in
    SS.of_list
      (match user_pubkey with
      | Some u -> (
          match viewer_rules ~clock c u with
          | Off -> []
          | Compiled -> Queries.hidden_pubkeys c ~user_pubkey ~scope ~pubkeys_json ~author_exempt
          | Default -> Queries.hidden_pubkeys_default_for c ~viewer:user_pubkey ~scope ~pubkeys_json ~author_exempt)
      | None -> Queries.hidden_pubkeys_default c ~scope ~pubkeys_json ~author_exempt)

let filter ~clock ~(funcall : string) ~(user_pubkey : string option) ~(author_exempt : string option)
    (msgs : string list) : string list =
  if msgs = [] then msgs
  else begin
    let scope = scope_of_funcall funcall in
    let ps = List.map parse msgs in
    (* what the rules need from the DB, collected in one pass *)
    let ids = ref SS.empty and scope_pks = ref SS.empty and trending_pks = ref SS.empty in
    let zap_pairs = ref [] (* (receiver hex, sender hex) *) in
    let notif_vals = ref SS.empty (* 64-hex values of NOTIFICATION contents: pubkeys or event ids *) in
    List.iter
      (fun p ->
        (match hex_field p "id" with Some id -> ids := SS.add id !ids | None -> ());
        match (hex_field p "pubkey", int_field p "kind") with
        | Some pk, _ -> if scope <> No_scope then scope_pks := SS.add pk !scope_pks
        | None, Some kind when kind = Kind.user_scores -> (
            match content_json p with
            | Some (`Assoc d) -> List.iter (fun (k, _) -> if is_hex64 k then trending_pks := SS.add (String.lowercase_ascii k) !trending_pks) d
            | _ -> ())
        | None, Some kind when kind = Kind.zap_event -> (
            match content_json p with
            | Some (`Assoc d) -> (
                match (List.assoc_opt "sender" d, List.assoc_opt "receiver" d) with
                | Some (`String s), Some (`String r) when is_hex64 s && is_hex64 r ->
                    zap_pairs := (String.lowercase_ascii r, String.lowercase_ascii s) :: !zap_pairs
                | _ -> ())
            | _ -> ())
        | None, Some kind when kind = Kind.directmsg_counts -> (
            match content_json p with
            | Some (`Assoc d) -> List.iter (fun (k, _) -> if is_hex64 k then scope_pks := SS.add (String.lowercase_ascii k) !scope_pks) d
            | _ -> ())
        | None, Some kind when kind = Kind.notification -> (
            match content_json p with
            | Some (`Assoc d) ->
                List.iter (function _, `String v when is_hex64 v -> notif_vals := SS.add (String.lowercase_ascii v) !notif_vals | _ -> ()) d
            | _ -> ())
        | _ -> ())
      ps;
    let zap_senders = List.map snd !zap_pairs |> SS.of_list in
    let need_db =
      not (SS.is_empty !ids && SS.is_empty !scope_pks && SS.is_empty !trending_pks && SS.is_empty zap_senders && SS.is_empty !notif_vals)
    in
    if not need_db then msgs
    else begin
      let hidden_ids, hidden_scope, hidden_trending, hidden_zap_user, hidden_zap_receiver, hidden_notif =
        Db.with_cache ~clock (fun c ->
            let q set scope user = hidden_pubkeys ~clock c ~user_pubkey:user ~scope ~hexes:(SS.elements set) ~author_exempt in
            let hidden_ids =
              if SS.is_empty !ids then SS.empty
              else SS.of_list (Queries.hidden_events c ~event_ids_json:(Queries.hexes_json (SS.elements !ids)))
            in
            let hidden_scope = q !scope_pks (if scope = No_scope then "content" else scope_name scope) user_pubkey in
            let hidden_trending = q !trending_pks "trending" user_pubkey in
            (* ZAP_EVENT: hidden for the viewer, or hidden by the receiver's own rules *)
            let hidden_zap_user = match user_pubkey with Some _ -> q zap_senders "content" user_pubkey | None -> SS.empty in
            let by_receiver = Hashtbl.create 8 in
            List.iter
              (fun (r, s) ->
                let cur = Option.value (Hashtbl.find_opt by_receiver r) ~default:SS.empty in
                Hashtbl.replace by_receiver r (SS.add s cur))
              !zap_pairs;
            let hidden_zap_receiver =
              Hashtbl.fold
                (fun r senders acc ->
                  let h = q senders "content" (Hex_util.decode_opt r) in
                  SS.fold (fun s acc -> (r, s) :: acc) h acc)
                by_receiver []
            in
            (* NOTIFICATION: a value is hidden when it is a hidden pubkey (content scope) or an
               event whose author is hidden (Julia is_hidden_ for an EventId) *)
            let hidden_notif =
              if SS.is_empty !notif_vals then SS.empty
              else begin
                let vals = SS.elements !notif_vals in
                let authors = Queries.event_authors c ~event_ids_json:(Queries.hexes_json vals) in
                let hidden_pks = q (SS.of_list (vals @ List.map snd authors)) "content" user_pubkey in
                SS.filter (fun v -> SS.mem v hidden_pks || (match List.assoc_opt v authors with Some a -> SS.mem a hidden_pks | None -> false)) !notif_vals
              end
            in
            (hidden_ids, hidden_scope, hidden_trending, hidden_zap_user, hidden_zap_receiver, hidden_notif))
      in
      List.filter_map
        (fun p ->
          (* Julia: a hidden/deleted event id drops the message; else the pubkey decides (events
             included); else the synthetic kinds *)
          match (hex_field p "id", hex_field p "pubkey", int_field p "kind") with
          | Some id, _, _ when SS.mem id hidden_ids -> None
          | _, Some pk, _ -> if SS.mem pk hidden_scope then None else Some p.text
          | _, None, Some kind when kind = Kind.user_scores -> (
              match content_json p with
              | Some (`Assoc d) ->
                  let kept = List.filter (fun (k, _) -> not (SS.mem (String.lowercase_ascii k) hidden_trending)) d in
                  if List.length kept = List.length d then Some p.text
                  else
                    Some
                      (Yojson.Safe.to_string
                         (`Assoc [ ("kind", `Int Kind.user_scores); ("content", `String (Yojson.Safe.to_string (`Assoc kept))) ]))
              | _ -> Some p.text)
          | _, None, Some kind when kind = Kind.directmsg_counts -> (
              match content_json p with
              | Some (`Assoc d) ->
                  let kept = List.filter (fun (k, _) -> not (is_hex64 k && SS.mem (String.lowercase_ascii k) hidden_scope)) d in
                  if List.length kept = List.length d then Some p.text
                  else Some (Yojson.Safe.to_string (`Assoc [ ("kind", `Int Kind.directmsg_counts); ("content", `String (Yojson.Safe.to_string (`Assoc kept))) ]))
              | _ -> Some p.text)
          | _, None, Some kind when kind = Kind.notification -> (
              match content_json p with
              | Some (`Assoc d) ->
                  if List.exists (function _, `String v when is_hex64 v -> SS.mem (String.lowercase_ascii v) hidden_notif | _ -> false) d
                  then None
                  else Some p.text
              | _ -> Some p.text)
          | _, None, Some kind when kind = Kind.zap_event -> (
              match content_json p with
              | Some (`Assoc d) -> (
                  match (List.assoc_opt "sender" d, List.assoc_opt "receiver" d) with
                  | Some (`String s), Some (`String r) when is_hex64 s && is_hex64 r ->
                      let s = String.lowercase_ascii s and r = String.lowercase_ascii r in
                      if SS.mem s hidden_zap_user || List.mem (r, s) hidden_zap_receiver then None else Some p.text
                  | _ -> Some p.text)
              | _ -> Some p.text)
          | _ -> Some p.text)
        ps
    end
  end
