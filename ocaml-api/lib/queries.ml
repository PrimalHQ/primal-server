(* Cache-DB queries of the native funcalls, all [%pgsql]-checked against primal1 at build time.
   One function per SQL statement; handlers never contain SQL. Results that are events/messages come
   back as JSON TEXT (the `::text` of a jsonb) and are passed to the client untouched. *)

module PGOCaml = Postgres.PGOCaml

let i64 = Int64.of_int
let i64s (l : int list) : int64 option list = List.map (fun i -> Some (i64 i)) l

let thread_view (c : Db.cache Db.conn) ~event_id ~limit ~since ~until ~offset ~user_pubkey
    ~apply_humaness_check : string list =
  let dbh = Db.raw c in
  let limit = i64 limit and since = i64 since and until = i64 until and offset = i64 offset in
  [%pgsql dbh
    "select e::text from thread_view($event_id, $limit, $since, $until, $offset, $?user_pubkey, $apply_humaness_check) r(e)"]
  |> List.filter_map Fun.id

let multi_kind_thread_view (c : Db.cache Db.conn) ~event_id ~kinds ~limit ~since ~until ~offset
    ~user_pubkey ~apply_humaness_check ~include_parent_posts : string list =
  let dbh = Db.raw c in
  let kinds = i64s kinds in
  let limit = i64 limit and since = i64 since and until = i64 until and offset = i64 offset in
  [%pgsql dbh
    "select e::text from multi_kind_thread_view($event_id, $kinds, $limit, $since, $until, $offset, $?user_pubkey, $apply_humaness_check, $include_parent_posts) r(e)"]
  |> List.filter_map Fun.id

let scored (c : Db.cache Db.conn) ~key ~user_pubkey : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select f.e::text from cache c, content_moderation_filtering(c.value, 'content', $?user_pubkey) f(e) where c.key = $key"]
  |> List.filter_map Fun.id

let get_bookmarks (c : Db.cache Db.conn) ~pubkey : string list =
  let dbh = Db.raw c in
  [%pgsql dbh "select e::text from get_bookmarks($pubkey) r(e)"] |> List.filter_map Fun.id

(* pubkeys as a JSON array of hex strings (ws-connector passes them as jsonb). *)
let user_infos (c : Db.cache Db.conn) ~(pubkeys_json : string) : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select e::text from user_infos(array(select jsonb_array_elements_text($pubkeys_json::jsonb))) r(e)"]
  |> List.filter_map Fun.id

let has_followers_row (c : Db.cache Db.conn) ~pubkey : bool =
  let dbh = Db.raw c in
  match [%pgsql dbh "select 1 from pubkey_followers pf where pf.follower_pubkey = $pubkey limit 1"] with
  | [] -> false
  | _ -> true

let feed_user_follows (c : Db.cache Db.conn) ~pubkey ~since ~until ~include_replies ~limit ~offset
    ~user_pubkey ~apply_humaness_check ~kinds : string list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until and include_replies = i64 include_replies
  and limit = i64 limit and offset = i64 offset and kinds = i64s kinds in
  [%pgsql dbh
    "select distinct e::text, coalesce(e->>'created_at', '0')::int8 as t \
     from feed_user_follows($pubkey, $since, $until, $include_replies, $limit, $offset, $?user_pubkey, $apply_humaness_check, $kinds) f(e) \
     where e is not null order by t desc"]
  |> List.filter_map (fun (e, _) -> e)

let feed_user_authored (c : Db.cache Db.conn) ~pubkey ~since ~until ~include_replies ~limit ~offset
    ~user_pubkey ~apply_humaness_check ~kinds : string list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until and include_replies = i64 include_replies
  and limit = i64 limit and offset = i64 offset and kinds = i64s kinds in
  [%pgsql dbh
    "select distinct e::text, coalesce(e->>'created_at', '0')::int8 as t \
     from feed_user_authored($pubkey, $since, $until, $include_replies, $limit, $offset, $?user_pubkey, $apply_humaness_check, $kinds) f(e) \
     where e is not null order by t desc"]
  |> List.filter_map (fun (e, _) -> e)

let long_form_content_feed (c : Db.cache Db.conn) ~pubkey ~notes ~topic ~curation ~minwords ~limit
    ~since ~until ~offset ~user_pubkey ~apply_humaness_check : string list =
  let dbh = Db.raw c in
  let minwords = i64 minwords and limit = i64 limit and since = i64 since and until = i64 until
  and offset = i64 offset in
  [%pgsql dbh
    "select distinct e::text, e->>'created_at' as t \
     from long_form_content_feed($?pubkey, $?notes, $?topic, $?curation, $minwords, $limit, $since, $until, $offset, $?user_pubkey, $apply_humaness_check) f(e) \
     where e is not null order by t desc"]
  |> List.filter_map (fun (e, _) -> e)

let live_feed_initial_response (c : Db.cache Db.conn) ~kind ~pubkey ~identifier ~user_pubkey
    ~content_moderation_mode : string list =
  let dbh = Db.raw c in
  let kind = i64 kind in
  [%pgsql dbh
    "select distinct e::text from live_feed_initial_response($kind, $pubkey, $identifier, $user_pubkey, $content_moderation_mode) f(e) where e is not null"]
  |> List.filter_map Fun.id

let live_events_from_follows (c : Db.cache Db.conn) ~user_pubkey : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select get_event_jsonb(lep.event_id)::text \
     from live_event_participants lep, pubkey_followers pf \
     where pf.follower_pubkey = $user_pubkey \
       and pf.pubkey = lep.participant_pubkey \
       and lep.kind = 30311 \
       and lep.created_at >= extract(epoch from now() - interval '1h')::int8 \
       and not exists (select 1 from live_event_pubkey_filterlist lepf where lepf.user_pubkey = pf.follower_pubkey and lepf.blocked_pubkey = lep.participant_pubkey) \
       and not live_feed_is_hidden(lep.event_id, $user_pubkey, live_feed_hosts(lep.kind, lep.pubkey, lep.identifier), 'moderated')"]
  |> List.filter_map Fun.id

let find_live_events (c : Db.cache Db.conn) ~host_pubkey ~identifier : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select get_event_jsonb(lep.event_id)::text \
     from live_event_participants lep \
     where lep.kind = 30311 \
       and lep.participant_pubkey = $host_pubkey \
       and ($?identifier::varchar is null or lep.identifier = $?identifier::varchar) \
       and lep.created_at >= extract(epoch from now() - interval '1h')::int8"]
  |> List.filter_map Fun.id

(* event ids as a JSON array of hex strings *)
let enrich_events (c : Db.cache Db.conn) ~(event_ids_json : string) ~user_pubkey ~apply_humaness_check
    ~orderby : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select distinct e::text from enrich_feed_events( \
       array(select row(e.id, e.created_at)::post from events e \
             where e.id = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($event_ids_json::jsonb) x(a)))), \
       $?user_pubkey, $apply_humaness_check, $orderby) f(e) where e is not null"]
  |> List.filter_map Fun.id

(* {1 Live-event distribution checks} (ws-connector distribute_live_event) *)

let live_feed_is_hidden (c : Db.cache Db.conn) ~event_id ~user_pubkey ~content_moderation_mode ~kind
    ~pubkey ~identifier : bool =
  let dbh = Db.raw c in
  let kind = i64 kind in
  match
    [%pgsql dbh
      "select live_feed_is_hidden($event_id, $user_pubkey, live_feed_hosts($kind, $pubkey, $identifier), $content_moderation_mode) as hidden"]
  with
  | Some true :: _ -> true
  | _ -> false

let live_hosts_blocked_by_user (c : Db.cache Db.conn) ~user_pubkey ~kind ~pubkey ~identifier : bool =
  let dbh = Db.raw c in
  let kind = i64 kind in
  match
    [%pgsql dbh
      "select exists (select 1 from live_event_pubkey_filterlist lepf \
         where lepf.user_pubkey = $user_pubkey and lepf.blocked_pubkey = any (select unnest(live_feed_hosts($kind, $pubkey, $identifier)))) as hidden"]
  with
  | Some true :: _ -> true
  | _ -> false

(* ws-importer: subscribed users (follows-based) who follow one of the live event's participants
   and have not blocked them. Arrays as JSON hex lists. *)
let followers_of_participants (c : Db.cache Db.conn) ~(users_json : string) ~(participants_json : string)
    : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select distinct pf.follower_pubkey from pubkey_followers pf \
     where pf.follower_pubkey = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($users_json::jsonb) x(a))) \
       and pf.pubkey = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($participants_json::jsonb) x(a))) \
       and not exists (select 1 from live_event_pubkey_filterlist lepf where lepf.user_pubkey = pf.follower_pubkey and lepf.blocked_pubkey = pf.pubkey)"]
  |> List.filter_map Fun.id

(* The live importer's poll: everything imported in (since, until], oldest first. Rows as the
   event JSON text so distribution forwards exactly what the DB holds. *)
let events_imported_between (c : Db.cache Db.conn) ~since ~until : string list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until in
  [%pgsql dbh
    "select get_event_jsonb(id)::text from event where imported_at >= $since and imported_at <= $until order by created_at"]
  |> List.filter_map Fun.id

(* {1 Management} *)

let wsconnvar (c : Db.cache Db.conn) ~(name : string) : string option =
  let dbh = Db.raw c in
  match [%pgsql dbh "select value::text from wsconnvars where name = $name"] with
  | v :: _ -> v
  | [] -> None

(* {1 Phase 3b: the Julia-era funcalls} — SQL functions written for ocaml-handlers (sql/app.sql,
   new_functions.sql) where they mirror app.jl, plain statements where Julia kept the logic in
   memory. Hex lists are passed as JSON text ($x::jsonb) and expanded with jsonb_array_elements_text. *)

let hexes_json (hexes : string list) : string = Yojson.Safe.to_string (`List (List.map (fun h -> `String h) hexes))
let raws_json (raws : string list) : string = hexes_json (List.map Hex_util.encode raws)

(* Julia is_user_blocked(pubkey, :csam) || is_user_blocked(pubkey, :impersonation) *)
let is_user_blocked (c : Db.cache Db.conn) ~pubkey : bool =
  let dbh = Db.raw c in
  match
    [%pgsql dbh
      "select 1 from filterlist where grp in ('csam', 'impersonation') and target_type = 'pubkey' and target = $pubkey and blocked limit 1"]
  with
  | [] -> false
  | _ -> true

(* est.meta_data[pubkey] -> est.events[...] *)
let metadata_event (c : Db.cache Db.conn) ~pubkey : string option =
  let dbh = Db.raw c in
  match [%pgsql dbh "select get_event_jsonb(value)::text from meta_data where key = $pubkey limit 1"] with
  | Some e :: _ -> Some e
  | _ -> None

(* ordered by the caller: (hex pubkey, metadata event json) for the pubkeys that have one *)
let metadata_events (c : Db.cache Db.conn) ~(pubkeys_json : string) : (string * string) list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select encode(md.key, 'hex'), get_event_jsonb(md.value)::text from meta_data md \
     where md.key = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($pubkeys_json::jsonb) x(a)))"]
  |> List.filter_map (function Some k, Some e -> Some (k, e) | _ -> None)

(* Julia ext_event_response(md) = event_media_response + event_preview_response, keyed by pubkey *)
let metadata_extras (c : Db.cache Db.conn) ~(pubkeys_json : string) : (string * string) list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select encode(md.key, 'hex'), r.e::text from meta_data md, \
       (select m.value as v, m.key as k, x.e from meta_data m, event_media_response(m.value) x(e) \
        where m.key = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($pubkeys_json::jsonb) x(a))) \
        union all \
        select m.value, m.key, x.e from meta_data m, event_preview_response(m.value) x(e) \
        where m.key = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($pubkeys_json::jsonb) x(a)))) r \
     where r.k = md.key and r.v = md.value"]
  |> List.filter_map (function Some k, Some e -> Some (k, e) | _ -> None)

let event_media_response (c : Db.cache Db.conn) ~event_id : string list =
  let dbh = Db.raw c in
  [%pgsql dbh "select e::text from event_media_response($event_id) r(e)"] |> List.filter_map Fun.id

(* Julia user_scores / user_follower_counts: get(est.pubkey_followers_cnt, pk, 0) for every pubkey *)
let follower_counts (c : Db.cache Db.conn) ~(pubkeys_json : string) : (string * int64) list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select a::text, coalesce(pfc.value, 0) from jsonb_array_elements_text($pubkeys_json::jsonb) x(a) \
     left join pubkey_followers_cnt pfc on pfc.key = decode(a::text, 'hex')"]
  |> List.filter_map (function Some k, Some v -> Some (k, v) | Some k, None -> Some (k, 0L) | _ -> None)

let primal_verified_names (c : Db.cache Db.conn) ~(pubkeys_json : string) : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select e::text from primal_verified_names(array(select decode(a::text, 'hex') from jsonb_array_elements_text($pubkeys_json::jsonb) x(a))) r(e)"]
  |> List.filter_map Fun.id

let user_blossom_servers (c : Db.cache Db.conn) ~(pubkeys_json : string) : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select e::text from user_blossom_servers(array(select decode(a::text, 'hex') from jsonb_array_elements_text($pubkeys_json::jsonb) x(a))) r(e)"]
  |> List.filter_map Fun.id

let user_live_events (c : Db.cache Db.conn) ~(pubkeys_json : string) : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select distinct e::text from jsonb_array_elements_text($pubkeys_json::jsonb) x(a), user_live_events(30311, decode(a::text, 'hex')) r(e) where e is not null"]
  |> List.filter_map Fun.id

(* {2 user_profile} (app.jl user_profile + ext_user_profile) *)

type profile_counts = {
  note_count : int64;
  reply_count : int64;
  long_form_note_count : int64;
  time_joined : int64 option;
  follows_count : int64; (* p tags of the contact list, capped at 5000 like Julia follows() *)
  followers_count : int64;
  total_zap_count : int64;
  total_satszapped : int64;
  media_count : int64;
  content_zap_count : int64;
}

let user_profile_counts (c : Db.cache Db.conn) ~pubkey : profile_counts =
  let dbh = Db.raw c in
  let z = Option.value ~default:0L in
  match
    [%pgsql dbh
      "select \
         (select count(1) from pubkey_events where pubkey = $pubkey and is_reply = 0), \
         (select count(1) from pubkey_events where pubkey = $pubkey and is_reply = 1), \
         (select count(1) from parametrized_replaceable_events where pubkey = $pubkey and kind = 30023), \
         (select min(created_at) from pubkey_events where pubkey = $pubkey), \
         (select least(5000, count(*)) from contact_lists cl, events e, jsonb_array_elements(e.tags) t \
            where cl.key = $pubkey and e.id = cl.value and t->>0 = 'p' and length(t->>1) = 64 and (t->>1) ~ '^[0-9a-fA-F]+$'), \
         (select coalesce(max(value), 0) from pubkey_followers_cnt where key = $pubkey), \
         (select coalesce(max(zaps), 0) from pubkey_zapped where pubkey = $pubkey), \
         (select coalesce(max(satszapped), 0) from pubkey_zapped where pubkey = $pubkey), \
         (select coalesce(max(cnt), 0) from pubkey_media_cnt where pubkey = $pubkey), \
         (select coalesce(max(cnt), 0) from pubkey_content_zap_cnt where pubkey = $pubkey)"]
  with
  | (nc, rc, lf, tj, fo, fc, zc, sz, mc, cz) :: _ ->
      { note_count = z nc; reply_count = z rc; long_form_note_count = z lf; time_joined = tj; follows_count = z fo;
        followers_count = z fc; total_zap_count = z zc; total_satszapped = z sz; media_count = z mc;
        content_zap_count = z cz }
  | [] -> assert false

(* app.jl get_user_relays as sql/new_functions.sql get_user_relays: one USER_RELAYS message *)
let get_user_relays (c : Db.cache Db.conn) ~pubkey : string list =
  let dbh = Db.raw c in
  [%pgsql dbh "select e::text from get_user_relays($pubkey) r(e)"] |> List.filter_map Fun.id

(* {2 users} *)

let user_profile_followed_by_pubkeys (c : Db.cache Db.conn) ~pubkey ~user_pubkey ~limit : string list =
  let dbh = Db.raw c in
  let limit = i64 limit in
  [%pgsql dbh
    "select pf1.pubkey from pubkey_followers pf1, pubkey_followers pf2, pubkey_followers_cnt pfc \
     where $user_pubkey = pf1.follower_pubkey and pf1.pubkey = pf2.follower_pubkey and pf2.pubkey = $pubkey and pf1.pubkey = pfc.key \
     group by pf1.pubkey order by max(pfc.value) desc limit $limit"]
  |> List.filter_map Fun.id

let contact_list (c : Db.cache Db.conn) ~pubkey ~extended_response : string list =
  let dbh = Db.raw c in
  [%pgsql dbh "select e::text from contact_list($pubkey, $extended_response) r(e)"] |> List.filter_map Fun.id

let is_user_following (c : Db.cache Db.conn) ~pubkey ~user_pubkey : string list =
  let dbh = Db.raw c in
  [%pgsql dbh "select e::text from is_user_following($pubkey, $user_pubkey) r(e)"] |> List.filter_map Fun.id

let replaceable_event (c : Db.cache Db.conn) ~pubkey ~kind : string list =
  let dbh = Db.raw c in
  let kind = i64 kind in
  [%pgsql dbh "select e::text from replaceable_event($pubkey, $kind) r(e)"] |> List.filter_map Fun.id

let creator_paid_tiers (c : Db.cache Db.conn) ~pubkey : string list =
  let dbh = Db.raw c in
  [%pgsql dbh "select e::text from creator_paid_tiers($pubkey) r(e)"] |> List.filter_map Fun.id

(* pubkeys that have a metadata event (Julia `pk in est.meta_data`), in the order given *)
let pubkeys_with_metadata (c : Db.cache Db.conn) ~(pubkeys_json : string) : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select a::text from jsonb_array_elements_text($pubkeys_json::jsonb) with ordinality x(a, i) \
     where exists (select 1 from meta_data md where md.key = decode(a::text, 'hex')) order by i"]
  |> List.filter_map Fun.id

(* {2 user_search} (app_ext.jl user_search) *)

let user_search_query (c : Db.cache Db.conn) ~(q : string) ~limit : (string * int64) list =
  let dbh = Db.raw c in
  let limit = i64 limit in
  [%pgsql dbh
    "select encode(us.pubkey, 'hex'), pfc.value from user_search us, pubkey_followers_cnt pfc \
     where (us.name @@ to_tsquery('simple', $q) or us.username @@ to_tsquery('simple', $q) or \
            us.display_name @@ to_tsquery('simple', $q) or us.displayname @@ to_tsquery('simple', $q) or \
            us.nip05 @@ to_tsquery('simple', $q) or us.lud16 @@ to_tsquery('simple', $q)) \
       and us.pubkey = pfc.key \
       and not exists (select 1 from filterlist where grp in ('csam', 'impersonation') and target_type = 'pubkey' and target = us.pubkey and blocked limit 1) \
     order by pfc.value desc limit $limit"]
  |> List.filter_map (function Some k, Some v -> Some (k, v) | Some k, None -> Some (k, 0L) | _ -> None)

let user_search_follows (c : Db.cache Db.conn) ~follower ~(q : string) : (string * int64) list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select encode(us.pubkey, 'hex'), coalesce(pfc.value, 0) from user_search us \
     join pubkey_followers pf on pf.follower_pubkey = $follower and pf.pubkey = us.pubkey \
     left join pubkey_followers_cnt pfc on pfc.key = us.pubkey \
     where us.name @@ plainto_tsquery('simple', $q) or us.display_name @@ plainto_tsquery('simple', $q) or us.nip05 @@ plainto_tsquery('simple', $q)"]
  |> List.filter_map (function Some k, Some v -> Some (k, v) | Some k, None -> Some (k, 0L) | _ -> None)

(* Julia follows(est, pubkey) with follower counts: the contact list's p tags (first 5000) *)
let follows_with_counts (c : Db.cache Db.conn) ~pubkey : (string * int64) list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select t->>1, coalesce(pfc.value, 0) from contact_lists cl, events e, jsonb_array_elements(e.tags) with ordinality t(t, i) \
     left join pubkey_followers_cnt pfc on pfc.key = decode(t->>1, 'hex') \
     where cl.key = $pubkey and e.id = cl.value and t->>0 = 'p' and length(t->>1) = 64 and (t->>1) ~ '^[0-9a-fA-F]+$' \
     order by i limit 5000"]
  |> List.filter_map (function Some k, Some v -> Some (k, v) | Some k, None -> Some (k, 0L) | _ -> None)

let follower_count (c : Db.cache Db.conn) ~pubkey : int64 option =
  let dbh = Db.raw c in
  match [%pgsql dbh "select value from pubkey_followers_cnt where key = $pubkey limit 1"] with
  | Some v :: _ -> Some v
  | _ -> None

(* {2 events} *)

let poll_votes (c : Db.cache Db.conn) ~event_id ~since ~until ~limit ~offset ~user_pubkey ~apply_humaness_check ~option
    : string list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until and limit = i64 limit and offset = i64 offset in
  [%pgsql dbh
    "select distinct e::text from poll_votes($event_id, $since, $until, $limit, $offset, $?user_pubkey, $apply_humaness_check, $?option) f(e) where e is not null"]
  |> List.filter_map Fun.id

let event_zaps_by_satszapped (c : Db.cache Db.conn) ~event_id ~limit ~since ~until ~offset ~user_pubkey : string list =
  let dbh = Db.raw c in
  let limit = i64 limit and since = i64 since and until = i64 until and offset = i64 offset in
  [%pgsql dbh
    "select e::text from event_zaps_by_satszapped($event_id, $limit, $since, $until, $offset, $?user_pubkey) r(e)"]
  |> List.filter_map Fun.id

(* Julia events(extended_response=false): the stored events, oldest first *)
let events_plain (c : Db.cache Db.conn) ~(event_ids_json : string) : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select get_event_jsonb(e.id)::text from events e \
     where e.id = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($event_ids_json::jsonb) x(a))) \
     order by e.created_at"]
  |> List.filter_map Fun.id

let event_ids_between (c : Db.cache Db.conn) ~since ~until ~limit ~offset : string list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until and limit = i64 limit and offset = i64 offset in
  [%pgsql dbh
    "select encode(event_id, 'hex') from event_created_at where created_at >= $since and created_at <= $until \
     order by created_at asc limit $limit offset $offset"]
  |> List.filter_map Fun.id

(* {2 media} (app_ext.jl get_media_metadata) *)

type media_variant = {
  size : string option;
  animated : int64 option;
  width : int64 option;
  height : int64 option;
  mimetype : string option;
  duration : float option;
  media_url : string option;
}

let media_url_variants (c : Db.cache Db.conn) ~(url : string) : media_variant list =
  let dbh = Db.raw c in
  [%pgsql dbh "select size, animated, width, height, mimetype, duration, media_url from get_media_url($url)"]
  |> List.map (fun (size, animated, width, height, mimetype, duration, media_url) ->
         { size; animated; width; height; mimetype; duration; media_url })

let video_thumbnails (c : Db.cache Db.conn) ~(url : string) : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select mu.media_url from video_thumbnails vt, get_media_url(vt.thumbnail_url) mu where vt.video_url = $url"]
  |> List.filter_map Fun.id

(* app_ext.jl get_default_relays: relays seen importing in the last two hours *)
let mined_relays (c : Db.cache Db.conn) : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select (case when rum.dest is not null then rum.dest else kr.relay_url end) \
     from known_relays kr left join relay_url_map rum on kr.relay_url = rum.src \
     where kr.last_import_at >= now() - interval '2 hours'"]
  |> List.filter_map Fun.id

(* {1 Content moderation post-filter} (app.jl content_moderation_filtering_2) *)

(* hex pubkeys of [pubkeys_json] hidden for [user_pubkey] in [scope] ("content"/"trending") *)
let hidden_pubkeys (c : Db.cache Db.conn) ~user_pubkey ~(scope : string) ~(pubkeys_json : string) ~author_exempt : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select a::text from jsonb_array_elements_text($pubkeys_json::jsonb) x(a) \
     where is_pubkey_hidden($?user_pubkey, (case when $scope = 'content' then 'content' else 'trending' end)::cmr_scope, decode(a::text, 'hex'), $?author_exempt)"]
  |> List.filter_map Fun.id

(* Julia Filterlist.is_hidden(eid) || eid in est.deleted_events *)
let hidden_events (c : Db.cache Db.conn) ~(event_ids_json : string) : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select a::text from jsonb_array_elements_text($event_ids_json::jsonb) x(a) \
     where exists (select 1 from filterlist fl where fl.target = decode(a::text, 'hex') and fl.target_type = 'event' and fl.blocked) \
        or exists (select 1 from deleted_events de where de.event_id = decode(a::text, 'hex'))"]
  |> List.filter_map Fun.id

(* Julia Filterlist.is_hidden(pubkey): blocked (spam/csam/impersonation) and not explicitly unblocked *)
let filterlist_hidden_pubkeys (c : Db.cache Db.conn) ~(pubkeys_json : string) : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select a::text from jsonb_array_elements_text($pubkeys_json::jsonb) x(a) \
     where exists (select 1 from filterlist fl where fl.target = decode(a::text, 'hex') and fl.target_type = 'pubkey' and fl.blocked and fl.grp in ('spam', 'csam', 'impersonation')) \
       and not exists (select 1 from filterlist fl where fl.target = decode(a::text, 'hex') and fl.target_type = 'pubkey' and not fl.blocked)"]
  |> List.filter_map Fun.id

(* {1 Phase 3b, second pass} — statements written from app.jl where the ocaml-handlers SQL functions
   were wrong (notification type 5 is YOUR_POST_WAS_REPOSTED; mentions are type 8;
   response_messages_for_post returns nothing at depth 0; response_messages_for_list's array bug). *)

type list_table = Mute_list | Mute_list_2 | Mute_lists | Allow_list

(* the list event of [pubkey] in one of Julia's est.mute_list / mute_list_2 / mute_lists / allow_list *)
let list_event (c : Db.cache Db.conn) ~(table : list_table) ~pubkey : string option =
  let dbh = Db.raw c in
  let r =
    match table with
    | Mute_list -> [%pgsql dbh "select get_event_jsonb(value)::text from mute_list where key = $pubkey limit 1"]
    | Mute_list_2 -> [%pgsql dbh "select get_event_jsonb(value)::text from mute_list_2 where key = $pubkey limit 1"]
    | Mute_lists -> [%pgsql dbh "select get_event_jsonb(value)::text from mute_lists where key = $pubkey limit 1"]
    | Allow_list -> [%pgsql dbh "select get_event_jsonb(value)::text from allow_list where key = $pubkey limit 1"]
  in
  match r with Some e :: _ -> Some e | _ -> None

(* (hex id, event json) for the stored events among [event_ids_json] *)
let events_by_ids (c : Db.cache Db.conn) ~(event_ids_json : string) : (string * string) list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select encode(e.id, 'hex'), get_event_jsonb(e.id)::text from events e \
     where e.id = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($event_ids_json::jsonb) x(a)))"]
  |> List.filter_map (function Some k, Some e -> Some (k, e) | _ -> None)

type zap_row = {
  zap_receipt_id : string; (* raw *)
  zr_created_at : int64;
  zr_event_id : string option;
  sender : string option;
  receiver : string option;
  amount_sats : int64;
}

(* app.jl event_zaps_by_satszapped, event_id form: est.zap_receipts = og_zap_receipts *)
let og_zap_receipts_by_event (c : Db.cache Db.conn) ~event_id ~since ~until ~limit ~offset : zap_row list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until and limit = i64 limit and offset = i64 offset in
  [%pgsql dbh
    "select zap_receipt_id, created_at, event_id, sender, receiver, amount_sats from og_zap_receipts \
     where event_id = $event_id and amount_sats >= $since and amount_sats <= $until \
     order by amount_sats desc limit $limit offset $offset"]
  |> List.filter_map (fun (zid, ca, eid, s, r, a) ->
         match (zid, ca, a) with
         | Some zap_receipt_id, Some zr_created_at, Some amount_sats ->
             Some { zap_receipt_id; zr_created_at; zr_event_id = eid; sender = s; receiver = r; amount_sats }
         | _ -> None)

(* app_ext.jl note_mentions: the events that mentioned [event_id] (YOUR_POST_WAS_MENTIONED_IN_POST = 8) *)
let note_mentions_event_ids (c : Db.cache Db.conn) ~event_id ~limit ~offset : string list =
  let dbh = Db.raw c in
  let limit = i64 limit and offset = i64 offset in
  [%pgsql dbh
    "select encode(arg2, 'hex') from pubkey_notifications where arg1 = $event_id and type = 8 \
     order by created_at desc limit $limit offset $offset"]
  |> List.filter_map Fun.id

let note_mentions_of_article_event_ids (c : Db.cache Db.conn) ~pubkey ~identifier ~limit ~offset : string list =
  let dbh = Db.raw c in
  let limit = i64 limit and offset = i64 offset in
  [%pgsql dbh
    "select encode(pn.arg2, 'hex') from reads_versions rv, pubkey_notifications pn \
     where rv.pubkey = $pubkey and rv.identifier = $identifier and rv.eid = pn.arg1 and pn.type = 8 \
     order by pn.created_at desc limit $limit offset $offset"]
  |> List.filter_map Fun.id

let note_mentions_count (c : Db.cache Db.conn) ~event_id : int64 =
  let dbh = Db.raw c in
  match [%pgsql dbh "select count(1) from pubkey_notifications where arg1 = $event_id and type = 8"] with
  | Some n :: _ -> n
  | _ -> 0L

(* app_ext.jl user_profile_scored_content: of the author's top-scored events, the kind-1 posts
   (the Julia filter `e.kind != 1 || e.pubkey == pubkey && push!` keeps exactly those) *)
let user_scored_posts (c : Db.cache Db.conn) ~pubkey ~limit : string list =
  let dbh = Db.raw c in
  let limit = i64 limit in
  [%pgsql dbh
    "select get_event_jsonb(t.event_id)::text from \
       (select es.event_id from event_stats es where es.author_pubkey = $pubkey and es.score > 0 order by es.score desc limit $limit) t, \
       events e where e.id = t.event_id and e.kind = 1 and e.pubkey = $pubkey"]
  |> List.filter_map Fun.id

(* Julia is_hidden_ with user_pubkey = nothing: compile_content_moderation_rules(est, nothing) is
   the default settings — group primal_spam in {content, trending}, primal_nsfw in {trending} —
   evaluated on the filterlist (ext_is_hidden_by_group). The SQL is_pubkey_hidden knows no
   defaults for a NULL user, so this is the NULL-user predicate. *)
let hidden_pubkeys_default (c : Db.cache Db.conn) ~(scope : string) ~(pubkeys_json : string) ~author_exempt : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select a::text from jsonb_array_elements_text($pubkeys_json::jsonb) x(a) \
     where (decode(a::text, 'hex') is distinct from $?author_exempt \
            and exists (select 1 from filterlist fl where fl.grp = 'spam' and fl.target_type = 'pubkey' and fl.target = decode(a::text, 'hex') and fl.blocked)) \
        or ($scope = 'trending' \
            and exists (select 1 from filterlist fl where fl.grp = 'nsfw' and fl.target_type = 'pubkey' and fl.target = decode(a::text, 'hex') and fl.blocked))"]
  |> List.filter_map Fun.id
