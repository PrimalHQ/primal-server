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

let filter ~clock ~(funcall : string) ~(user_pubkey : string option) ~(author_exempt : string option)
    (msgs : string list) : string list =
  if msgs = [] then msgs
  else begin
    let scope = scope_of_funcall funcall in
    let ps = List.map parse msgs in
    (* what the rules need from the DB, collected in one pass *)
    let ids = ref SS.empty and scope_pks = ref SS.empty and trending_pks = ref SS.empty in
    let zap_pairs = ref [] (* (receiver hex, sender hex) *) in
    List.iter
      (fun p ->
        match (hex_field p "id", hex_field p "pubkey", int_field p "kind") with
        | Some id, _, _ -> ids := SS.add id !ids
        | None, Some pk, _ -> if scope <> No_scope then scope_pks := SS.add pk !scope_pks
        | None, None, Some kind when kind = Kind.user_scores -> (
            match content_json p with
            | Some (`Assoc d) -> List.iter (fun (k, _) -> if is_hex64 k then trending_pks := SS.add (String.lowercase_ascii k) !trending_pks) d
            | _ -> ())
        | None, None, Some kind when kind = Kind.zap_event -> (
            match content_json p with
            | Some (`Assoc d) -> (
                match (List.assoc_opt "sender" d, List.assoc_opt "receiver" d) with
                | Some (`String s), Some (`String r) when is_hex64 s && is_hex64 r ->
                    zap_pairs := (String.lowercase_ascii r, String.lowercase_ascii s) :: !zap_pairs
                | _ -> ())
            | _ -> ())
        | _ -> ())
      ps;
    let zap_senders = List.map snd !zap_pairs |> SS.of_list in
    let need_db =
      not (SS.is_empty !ids && SS.is_empty !scope_pks && SS.is_empty !trending_pks && SS.is_empty zap_senders)
    in
    if not need_db then msgs
    else begin
      let hidden_ids, hidden_scope, hidden_trending, hidden_zap_user, hidden_zap_receiver =
        Db.with_cache ~clock (fun c ->
            let q set scope user =
              if SS.is_empty set then SS.empty
              else
                let pubkeys_json = Queries.hexes_json (SS.elements set) in
                SS.of_list
                  (match user with
                  | Some _ -> Queries.hidden_pubkeys c ~user_pubkey:user ~scope ~pubkeys_json ~author_exempt
                  | None -> Queries.hidden_pubkeys_default c ~scope ~pubkeys_json ~author_exempt)
            in
            let hidden_ids =
              if SS.is_empty !ids then SS.empty
              else SS.of_list (Queries.hidden_events c ~event_ids_json:(Queries.hexes_json (SS.elements !ids)))
            in
            let hidden_scope = q !scope_pks (scope_name scope) user_pubkey in
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
            (hidden_ids, hidden_scope, hidden_trending, hidden_zap_user, hidden_zap_receiver))
      in
      List.filter_map
        (fun p ->
          match (hex_field p "id", hex_field p "pubkey", int_field p "kind") with
          | Some id, _, _ -> if SS.mem id hidden_ids then None else Some p.text
          | None, Some pk, _ -> if SS.mem pk hidden_scope then None else Some p.text
          | None, None, Some kind when kind = Kind.user_scores -> (
              match content_json p with
              | Some (`Assoc d) ->
                  let kept = List.filter (fun (k, _) -> not (SS.mem (String.lowercase_ascii k) hidden_trending)) d in
                  if List.length kept = List.length d then Some p.text
                  else
                    Some
                      (Yojson.Safe.to_string
                         (`Assoc [ ("kind", `Int Kind.user_scores); ("content", `String (Yojson.Safe.to_string (`Assoc kept))) ]))
              | _ -> Some p.text)
          | None, None, Some kind when kind = Kind.zap_event -> (
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
