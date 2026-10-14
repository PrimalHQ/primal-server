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

(* {1 The app.jl funcalls} — SQL functions written for ocaml-handlers (sql/app.sql,
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

(* {1 The app.jl funcalls, second pass} — statements written from app.jl where the ocaml-handlers SQL functions
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

(* [hidden_pubkeys_default] with Julia's spam_softban_exempt relative to [viewer]: the viewer
   themself and the pubkeys the viewer follows are exempt from the spam group *)
let hidden_pubkeys_default_for (c : Db.cache Db.conn) ~viewer ~(scope : string) ~(pubkeys_json : string) ~author_exempt
    : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select a::text from jsonb_array_elements_text($pubkeys_json::jsonb) x(a) \
     where (decode(a::text, 'hex') is distinct from $?author_exempt \
            and decode(a::text, 'hex') is distinct from $?viewer \
            and not exists (select 1 from pubkey_followers pf where pf.pubkey = decode(a::text, 'hex') and pf.follower_pubkey = $?viewer) \
            and exists (select 1 from filterlist fl where fl.grp = 'spam' and fl.target_type = 'pubkey' and fl.target = decode(a::text, 'hex') and fl.blocked)) \
        or ($scope = 'trending' \
            and exists (select 1 from filterlist fl where fl.grp = 'nsfw' and fl.target_type = 'pubkey' and fl.target = decode(a::text, 'hex') and fl.blocked))"]
  |> List.filter_map Fun.id

(* whether the importer compiled content-moderation rules for this user (cmr_* tables) *)
let user_has_cmr (c : Db.cache Db.conn) ~pubkey : bool =
  let dbh = Db.raw c in
  match
    [%pgsql dbh
      "select 1 where exists (select 1 from cmr_groups where user_pubkey = $pubkey) \
          or exists (select 1 from cmr_pubkeys_scopes where user_pubkey = $pubkey) \
          or exists (select 1 from cmr_pubkeys_allowed where user_pubkey = $pubkey)"]
  with
  | [] -> false
  | _ -> true

(* {1 Notifications and the periodic counters} *)

type notif_row = {
  n_created_at : int64;
  n_type : int64;
  arg1 : string option; (* bytea *)
  arg2 : string option; (* bytea *)
  arg3 : string option; (* jsonb as text *)
  arg4 : string option; (* jsonb as text *)
}

let notif_of (created_at, typ, arg1, arg2, arg3, arg4) =
  match (created_at, typ) with
  | Some n_created_at, Some n_type -> Some { n_created_at; n_type; arg1; arg2; arg3; arg4 }
  | _ -> None

(* app_ext.jl get_notifications: newest first; without a type filter Julia drops USER_UNFOLLOWED_YOU
   rows whose follower follows again (accept_result), so that lives in the WHERE here. *)
let notifications (c : Db.cache Db.conn) ~pubkey ~since ~until ~limit ~offset ~user_pubkey ~(types_json : string option)
    : notif_row list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until and limit = i64 limit and offset = i64 offset in
  match types_json with
  | None ->
      [%pgsql dbh
        "select created_at, type, arg1, arg2, arg3::text, arg4::text from pubkey_notifications pn \
         where pubkey = $pubkey and created_at >= $since and created_at <= $until \
           and notification_is_visible(type, arg1, arg2, arg3, $?user_pubkey) \
           and not (type = 2 and exists (select 1 from pubkey_followers pf where pf.pubkey = $pubkey and pf.follower_pubkey = pn.arg1)) \
         order by created_at desc limit $limit offset $offset"]
      |> List.filter_map notif_of
  | Some types_json ->
      [%pgsql dbh
        "select created_at, type, arg1, arg2, arg3::text, arg4::text from pubkey_notifications pn \
         where pubkey = $pubkey and created_at >= $since and created_at <= $until \
           and type = any(array(select (jsonb_array_elements_text($types_json::jsonb))::int8)) \
           and notification_is_visible(type, arg1, arg2, arg3, $?user_pubkey) \
         order by created_at desc limit $limit offset $offset"]
      |> List.filter_map notif_of

(* LIVE_EVENT_HAPPENING: the live event behind a coordinate *)
let parametrized_event_ids (c : Db.cache Db.conn) ~pubkey ~kind ~(identifier : string) : string list =
  let dbh = Db.raw c in
  let kind = i64 kind in
  [%pgsql dbh
    "select encode(event_id, 'hex') from parametrized_replaceable_events where pubkey = $pubkey and kind = $kind and identifier = $identifier"]
  |> List.filter_map Fun.id

(* enrich_feed_events with one timestamp for every post (Julia get_notifications passes now) *)
let enrich_events_at (c : Db.cache Db.conn) ~(event_ids_json : string) ~t ~user_pubkey ~apply_humaness_check : string list =
  let dbh = Db.raw c in
  let t = i64 t in
  [%pgsql dbh
    "select distinct e::text from enrich_feed_events( \
       array(select row(decode(a::text, 'hex'), $t)::post from jsonb_array_elements_text($event_ids_json::jsonb) x(a)), \
       $?user_pubkey, $apply_humaness_check, 'created_at') f(e) where e is not null"]
  |> List.filter_map Fun.id

(* (hex id, hex author) of the stored events among [event_ids_json] *)
let event_authors (c : Db.cache Db.conn) ~(event_ids_json : string) : (string * string) list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select encode(e.id, 'hex'), encode(e.pubkey, 'hex') from events e \
     where e.id = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($event_ids_json::jsonb) x(a)))"]
  |> List.filter_map (function Some i, Some p -> Some (i, p) | _ -> None)

(* app_ext.jl set_notifications_seen: zero every counter of the user (the NotificationType instances) *)
let reset_notification_counts (c : Db.cache Db.conn) ~pubkey : unit =
  let dbh = Db.raw c in
  ignore
    [%pgsql dbh
      "update pubkey_notification_cnts set type1 = 0, type2 = 0, type3 = 0, type4 = 0, type5 = 0, type6 = 0, type7 = 0, type8 = 0, \
         type101 = 0, type102 = 0, type103 = 0, type104 = 0, type201 = 0, type202 = 0, type203 = 0, type204 = 0, \
         type301 = 0, type302 = 0, type401 = 0, type501 = 0, type601 = 0 where pubkey = $pubkey"]

(* the NotificationType instances, in Julia's enum order (the key order of NOTIFICATIONS_SUMMARY) *)
let notification_types = [ 1; 2; 3; 4; 5; 6; 7; 8; 101; 102; 103; 104; 201; 202; 203; 204; 301; 302; 401; 501; 601 ]

(* app_ext.jl get_notification_counts for many users at once: (hex pubkey, counts in [notification_types] order) *)
let notification_counts (c : Db.cache Db.conn) ~(pubkeys_json : string) : (string * int64 list) list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select encode(pubkey, 'hex'), type1, type2, type3, type4, type5, type6, type7, type8, type101, type102, type103, type104, \
       type201, type202, type203, type204, type301, type302, type401, type501, type601 \
     from pubkey_notification_cnts where pubkey = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($pubkeys_json::jsonb) x(a)))"]
  |> List.filter_map (fun (pk, t1, t2, t3, t4, t5, t6, t7, t8, t101, t102, t103, t104, t201, t202, t203, t204, t301, t302, t401, t501, t601) ->
         match pk with
         | None -> None
         | Some pk ->
             let z = Option.value ~default:0L in
             let zi = function Some v -> Int64.of_int32 v | None -> 0L in
             Some
               ( pk,
                 [ z t1; z t2; z t3; z t4; z t5; z t6; z t7; z t8; z t101; z t102; z t103; z t104; z t201; z t202; z t203; z t204;
                   zi t301; zi t302; zi t401; zi t501; zi t601 ] ))

(* app.jl get_directmsg_count(receiver) without sender: the total row *)
let directmsg_counts (c : Db.cache Db.conn) ~(pubkeys_json : string) : (string * int64) list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select encode(receiver, 'hex'), cnt from pubkey_directmsgs_cnt \
     where receiver = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($pubkeys_json::jsonb) x(a))) and sender is null"]
  |> List.filter_map (function Some k, Some v -> Some (k, v) | _ -> None)

(* {1 Explore / scored content} (app_ext.jl scored_content, scored_users, the explore funcalls) *)

type scored_field = Created_at | Score | Satszapped (* latest | popular,trending | mostzapped *)

let scored_field_name = function Created_at -> "created_at" | Score -> "score" | Satszapped -> "satszapped"

type scored_row = { s_pubkey : string; s_event_id : string; s_value : int64 }

let scored_rows l = List.filter_map (function Some pk, Some eid, Some v -> Some { s_pubkey = pk; s_event_id = eid; s_value = v } | _ -> None) l


(* group_by_pubkey (explore_global_trending / mostzapped): the best event per author among the
   top authors, with Julia's trending hiding inside the grouping.
   The p-tag mute check here and in scored_global is a scalar subquery over the event's own tags
   (bt.id) with the viewer's trending mutes read once: as `not exists (... cmr, basic_tags ...)` the
   planner joined from the mutes to every tag naming a muted pubkey (bt.arg1): the 24 h grouped
   trending on the stage host took 3.5-45 s for a viewer with 7 trending mutes (now 1.2-2.3 s) and
   6.4 s with 113 (now 2-3.2 s), same rows. The `cardinality(...) > 0` gate is a one-time filter (no
   mutes: no tag is read), and the `is null` guard lets a custom plan drop the check for anonymous
   requests as the old form did (0.27 s; the subquery's cost estimate otherwise steers it to a
   26 M-row score bitmap). A generic plan of the old form took 9.7 s anonymous, this one 0.75 s. *)
let scored_global_grouped (c : Db.cache Db.conn) ~(field : scored_field) ~created_after ~user_pubkey ~n ~offset ~gm_mode ~kinds_json : scored_row list =
  let dbh = Db.raw c in
  let created_after = i64 created_after and n = i64 n and offset = i64 offset in
  scored_rows
    (match field with
    | Created_at ->
        [%pgsql dbh
          "with a as (select es.author_pubkey, max(es.created_at) as maxfield from event_stats es \
             where es.created_at > 0 and $created_after <= es.created_at and ($?kinds_json::text is null or exists (select 1 from events ek where ek.id = es.event_id and ek.kind = any(array(select (jsonb_array_elements_text($?kinds_json::jsonb))::int8)))) \
               and not is_event_hidden($?user_pubkey, 'trending', es.event_id) \
       and not exists (select 1 from filterlist fl where fl.target = es.event_id and fl.target_type = 'event' and fl.grp = 'trending' and fl.blocked) \
       and ($?user_pubkey::bytea is null or not coalesce((select true from basic_tags bt where cardinality(array(select cmr.pubkey from cmr_pubkeys_scopes cmr where cmr.user_pubkey = $?user_pubkey and cmr.scope = 'trending')) > 0 and bt.id = es.event_id and bt.tag = 'p' and bt.arg1 = any(array(select cmr.pubkey from cmr_pubkeys_scopes cmr where cmr.user_pubkey = $?user_pubkey and cmr.scope = 'trending')) limit 1), false)) \
             group by es.author_pubkey order by maxfield desc limit $n offset $offset) \
           select a.author_pubkey, es.event_id, es.created_at from a, event_stats es \
           where a.author_pubkey = es.author_pubkey and a.maxfield = es.created_at and es.created_at > 0 and $created_after <= es.created_at \
             and ($?kinds_json::text is null or exists (select 1 from events ek where ek.id = es.event_id and ek.kind = any(array(select (jsonb_array_elements_text($?kinds_json::jsonb))::int8)))) and ($?gm_mode::text is null \
       or ($?gm_mode::text = 'gmonly' and exists (select 1 from events eg where eg.id = es.event_id and (eg.content ilike '%gm%' or eg.content ilike '%good morning%'))) \
       or ($?gm_mode::text = 'nogm' and not exists (select 1 from events eg where eg.id = es.event_id and (eg.content ilike '%gm%' or eg.content ilike '%good morning%'))))"]
    | Score ->
        [%pgsql dbh
          "with a as (select es.author_pubkey, max(es.score) as maxfield from event_stats es \
             where es.score > 0 and $created_after <= es.created_at and ($?kinds_json::text is null or exists (select 1 from events ek where ek.id = es.event_id and ek.kind = any(array(select (jsonb_array_elements_text($?kinds_json::jsonb))::int8)))) \
               and not is_event_hidden($?user_pubkey, 'trending', es.event_id) \
       and not exists (select 1 from filterlist fl where fl.target = es.event_id and fl.target_type = 'event' and fl.grp = 'trending' and fl.blocked) \
       and ($?user_pubkey::bytea is null or not coalesce((select true from basic_tags bt where cardinality(array(select cmr.pubkey from cmr_pubkeys_scopes cmr where cmr.user_pubkey = $?user_pubkey and cmr.scope = 'trending')) > 0 and bt.id = es.event_id and bt.tag = 'p' and bt.arg1 = any(array(select cmr.pubkey from cmr_pubkeys_scopes cmr where cmr.user_pubkey = $?user_pubkey and cmr.scope = 'trending')) limit 1), false)) \
             group by es.author_pubkey order by maxfield desc limit $n offset $offset) \
           select a.author_pubkey, es.event_id, es.score from a, event_stats es \
           where a.author_pubkey = es.author_pubkey and a.maxfield = es.score and es.score > 0 and $created_after <= es.created_at \
             and ($?kinds_json::text is null or exists (select 1 from events ek where ek.id = es.event_id and ek.kind = any(array(select (jsonb_array_elements_text($?kinds_json::jsonb))::int8)))) and ($?gm_mode::text is null \
       or ($?gm_mode::text = 'gmonly' and exists (select 1 from events eg where eg.id = es.event_id and (eg.content ilike '%gm%' or eg.content ilike '%good morning%'))) \
       or ($?gm_mode::text = 'nogm' and not exists (select 1 from events eg where eg.id = es.event_id and (eg.content ilike '%gm%' or eg.content ilike '%good morning%'))))"]
    | Satszapped ->
        [%pgsql dbh
          "with a as (select es.author_pubkey, max(es.satszapped) as maxfield from event_stats es \
             where es.satszapped > 0 and $created_after <= es.created_at and ($?kinds_json::text is null or exists (select 1 from events ek where ek.id = es.event_id and ek.kind = any(array(select (jsonb_array_elements_text($?kinds_json::jsonb))::int8)))) \
               and not is_event_hidden($?user_pubkey, 'trending', es.event_id) \
       and not exists (select 1 from filterlist fl where fl.target = es.event_id and fl.target_type = 'event' and fl.grp = 'trending' and fl.blocked) \
       and ($?user_pubkey::bytea is null or not coalesce((select true from basic_tags bt where cardinality(array(select cmr.pubkey from cmr_pubkeys_scopes cmr where cmr.user_pubkey = $?user_pubkey and cmr.scope = 'trending')) > 0 and bt.id = es.event_id and bt.tag = 'p' and bt.arg1 = any(array(select cmr.pubkey from cmr_pubkeys_scopes cmr where cmr.user_pubkey = $?user_pubkey and cmr.scope = 'trending')) limit 1), false)) \
             group by es.author_pubkey order by maxfield desc limit $n offset $offset) \
           select a.author_pubkey, es.event_id, es.satszapped from a, event_stats es \
           where a.author_pubkey = es.author_pubkey and a.maxfield = es.satszapped and es.satszapped > 0 and $created_after <= es.created_at \
             and ($?kinds_json::text is null or exists (select 1 from events ek where ek.id = es.event_id and ek.kind = any(array(select (jsonb_array_elements_text($?kinds_json::jsonb))::int8)))) and ($?gm_mode::text is null \
       or ($?gm_mode::text = 'gmonly' and exists (select 1 from events eg where eg.id = es.event_id and (eg.content ilike '%gm%' or eg.content ilike '%good morning%'))) \
       or ($?gm_mode::text = 'nogm' and not exists (select 1 from events eg where eg.id = es.event_id and (eg.content ilike '%gm%' or eg.content ilike '%good morning%'))))"]
    )


(* the ungrouped global query: the top (n + offset) * 10 candidates by the field, then Julia's
   trending hiding, then the page *)
let scored_global (c : Db.cache Db.conn) ~(field : scored_field) ~created_after ~since ~until ~user_pubkey ~n ~offset ~kinds_json : scored_row list =
  let dbh = Db.raw c in
  let created_after = i64 created_after and n = i64 n and offset = i64 offset in
  let candidates = Int64.mul (Int64.add n offset) 10L in
  let since = Option.map i64 since and until = Option.map i64 until in
  scored_rows
    (match field with
    | Created_at ->
        [%pgsql dbh
          "with top_candidates as materialized ( \
             select es.author_pubkey, es.event_id, es.created_at from event_stats es \
             where es.created_at > 0 and $created_after <= es.created_at \
               and ($?since::int8 is null or $?since::int8 <= es.created_at) and ($?until::int8 is null or $?until::int8 >= es.created_at) \
               and ($?kinds_json::text is null or exists (select 1 from events ek where ek.id = es.event_id and ek.kind = any(array(select (jsonb_array_elements_text($?kinds_json::jsonb))::int8)))) \
             order by es.created_at desc limit $candidates) \
           select es.author_pubkey, es.event_id, es.created_at from top_candidates es \
           where not is_event_hidden($?user_pubkey, 'trending', es.event_id) \
       and not exists (select 1 from filterlist fl where fl.target = es.event_id and fl.target_type = 'event' and fl.grp = 'trending' and fl.blocked) \
       and ($?user_pubkey::bytea is null or not coalesce((select true from basic_tags bt where cardinality(array(select cmr.pubkey from cmr_pubkeys_scopes cmr where cmr.user_pubkey = $?user_pubkey and cmr.scope = 'trending')) > 0 and bt.id = es.event_id and bt.tag = 'p' and bt.arg1 = any(array(select cmr.pubkey from cmr_pubkeys_scopes cmr where cmr.user_pubkey = $?user_pubkey and cmr.scope = 'trending')) limit 1), false)) \
           order by es.created_at desc limit $n offset $offset"]
    | Score ->
        [%pgsql dbh
          "with top_candidates as materialized ( \
             select es.author_pubkey, es.event_id, es.score from event_stats es \
             where es.score > 0 and $created_after <= es.created_at \
               and ($?since::int8 is null or $?since::int8 <= es.score) and ($?until::int8 is null or $?until::int8 >= es.score) \
               and ($?kinds_json::text is null or exists (select 1 from events ek where ek.id = es.event_id and ek.kind = any(array(select (jsonb_array_elements_text($?kinds_json::jsonb))::int8)))) \
             order by es.score desc limit $candidates) \
           select es.author_pubkey, es.event_id, es.score from top_candidates es \
           where not is_event_hidden($?user_pubkey, 'trending', es.event_id) \
       and not exists (select 1 from filterlist fl where fl.target = es.event_id and fl.target_type = 'event' and fl.grp = 'trending' and fl.blocked) \
       and ($?user_pubkey::bytea is null or not coalesce((select true from basic_tags bt where cardinality(array(select cmr.pubkey from cmr_pubkeys_scopes cmr where cmr.user_pubkey = $?user_pubkey and cmr.scope = 'trending')) > 0 and bt.id = es.event_id and bt.tag = 'p' and bt.arg1 = any(array(select cmr.pubkey from cmr_pubkeys_scopes cmr where cmr.user_pubkey = $?user_pubkey and cmr.scope = 'trending')) limit 1), false)) \
           order by es.score desc limit $n offset $offset"]
    | Satszapped ->
        [%pgsql dbh
          "with top_candidates as materialized ( \
             select es.author_pubkey, es.event_id, es.satszapped from event_stats es \
             where es.satszapped > 0 and $created_after <= es.created_at \
               and ($?since::int8 is null or $?since::int8 <= es.satszapped) and ($?until::int8 is null or $?until::int8 >= es.satszapped) \
               and ($?kinds_json::text is null or exists (select 1 from events ek where ek.id = es.event_id and ek.kind = any(array(select (jsonb_array_elements_text($?kinds_json::jsonb))::int8)))) \
             order by es.satszapped desc limit $candidates) \
           select es.author_pubkey, es.event_id, es.satszapped from top_candidates es \
           where not is_event_hidden($?user_pubkey, 'trending', es.event_id) \
       and not exists (select 1 from filterlist fl where fl.target = es.event_id and fl.target_type = 'event' and fl.grp = 'trending' and fl.blocked) \
       and ($?user_pubkey::bytea is null or not coalesce((select true from basic_tags bt where cardinality(array(select cmr.pubkey from cmr_pubkeys_scopes cmr where cmr.user_pubkey = $?user_pubkey and cmr.scope = 'trending')) > 0 and bt.id = es.event_id and bt.tag = 'p' and bt.arg1 = any(array(select cmr.pubkey from cmr_pubkeys_scopes cmr where cmr.user_pubkey = $?user_pubkey and cmr.scope = 'trending')) limit 1), false)) \
           order by es.satszapped desc limit $n offset $offset"]
    )


(* timeframe latest with kinds: straight from the event table *)
let latest_global_kinds (c : Db.cache Db.conn) ~created_after ~(kinds_json : string) ~n ~offset : scored_row list =
  let dbh = Db.raw c in
  let created_after = i64 created_after and n = i64 n and offset = i64 offset in
  [%pgsql dbh
    "select e.pubkey, e.id, e.created_at from event e \
     where e.kind = any(array(select (jsonb_array_elements_text($kinds_json::jsonb))::int8)) and $created_after <= e.created_at \
     order by e.created_at desc limit $n offset $offset"]
  |> List.map (fun (pk, eid, v) -> { s_pubkey = pk; s_event_id = eid; s_value = v })

(* scope tribe/follows: the page of each author's events by the field *)
let scored_by_pubkeys (c : Db.cache Db.conn) ~(field : scored_field) ~created_after ~since ~until ~(pubkeys_json : string) ~n ~offset : scored_row list =
  let dbh = Db.raw c in
  let created_after = i64 created_after and lo = Int64.add (i64 offset) 1L and hi = i64 (offset + n) in
  let since = Option.map i64 since and until = Option.map i64 until in
  scored_rows
    (match field with
    | Created_at ->
        [%pgsql dbh
          "select author_pubkey, event_id, created_at from ( \
             select es.author_pubkey, es.event_id, es.created_at, row_number() over (partition by es.author_pubkey order by es.created_at desc) as rn \
             from event_stats es \
             where es.author_pubkey = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($pubkeys_json::jsonb) x(a))) \
               and $created_after <= es.created_at \
               and ($?since::int8 is null or $?since::int8 <= es.created_at) and ($?until::int8 is null or $?until::int8 >= es.created_at)) t \
           where rn >= $lo and rn <= $hi"]
    | Score ->
        [%pgsql dbh
          "select author_pubkey, event_id, score from ( \
             select es.author_pubkey, es.event_id, es.score, row_number() over (partition by es.author_pubkey order by es.score desc) as rn \
             from event_stats es \
             where es.author_pubkey = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($pubkeys_json::jsonb) x(a))) \
               and $created_after <= es.created_at \
               and ($?since::int8 is null or $?since::int8 <= es.score) and ($?until::int8 is null or $?until::int8 >= es.score)) t \
           where rn >= $lo and rn <= $hi"]
    | Satszapped ->
        [%pgsql dbh
          "select author_pubkey, event_id, satszapped from ( \
             select es.author_pubkey, es.event_id, es.satszapped, row_number() over (partition by es.author_pubkey order by es.satszapped desc) as rn \
             from event_stats es \
             where es.author_pubkey = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($pubkeys_json::jsonb) x(a))) \
               and $created_after <= es.created_at \
               and ($?since::int8 is null or $?since::int8 <= es.satszapped) and ($?until::int8 is null or $?until::int8 >= es.satszapped)) t \
           where rn >= $lo and rn <= $hi"]
    )


(* Julia's in-memory post filter of scored_content, table-driven: Filterlist.access_pubkey_unblocked
   (filterlist rows with blocked = false), import_pubkey_blocked (spam/csam/impersonation),
   analytics_pubkey_blocked / analytics_event_blocked (grp trending), deleted events, the
   trending-blocked nip05 domains (App.TRENDING_BLOCKED_DOMAINS) and followers >= 5. Takes
   [[event hex, pubkey hex], ...] and returns the event ids that pass. *)
let scored_pass (c : Db.cache Db.conn) ~(posts_json : string) ~(domains_json : string) : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select p->>0 from jsonb_array_elements($posts_json::jsonb) x(p) \
     where exists (select 1 from filterlist fl where fl.target = decode(p->>1, 'hex') and fl.target_type = 'pubkey' and not fl.blocked) \
        or (not exists (select 1 from filterlist fl where fl.target = decode(p->>1, 'hex') and fl.target_type = 'pubkey' and fl.blocked and fl.grp in ('spam', 'csam', 'impersonation', 'trending')) \
            and not exists (select 1 from filterlist fl where fl.target = decode(p->>0, 'hex') and fl.target_type = 'event' and fl.blocked and fl.grp = 'trending') \
            and not exists (select 1 from deleted_events de where de.event_id = decode(p->>0, 'hex')) \
            and not exists (select 1 from meta_data md, events e, jsonb_array_elements_text($domains_json::jsonb) d \
                            where md.key = decode(p->>1, 'hex') and e.id = md.value \
                              and (lower(substring(e.content from '\"nip05\"\\s*:\\s*\"[^\"@]*@([^\"]+)\"')) = d::text \
                                   or lower(substring(e.content from '\"nip05\"\\s*:\\s*\"[^\"@]*@([^\"]+)\"')) like '%.' || d::text)) \
            and coalesce((select pfc.value from pubkey_followers_cnt pfc where pfc.key = decode(p->>1, 'hex')), 0) >= 5)"]
  |> List.filter_map Fun.id

(* enrich_feed_events over (event hex, value) pairs; the value plays created_at in the SQL *)
let enrich_posts (c : Db.cache Db.conn) ~(posts_json : string) ~user_pubkey ~apply_humaness_check : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select distinct e::text from enrich_feed_events( \
       array(select row(decode(p->>0, 'hex'), (p->>1)::int8)::post from jsonb_array_elements($posts_json::jsonb) x(p)), \
       $?user_pubkey, $apply_humaness_check, 'created_at') f(e) where e is not null"]
  |> List.filter_map Fun.id

(* advanced_search: enrich_feed_events over (event hex, orderkey) pairs with Julia's orderby name *)
let enrich_posts_ordered (c : Db.cache Db.conn) ~(posts_json : string) ~user_pubkey ~apply_humaness_check ~(orderby : string) : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select distinct e::text from enrich_feed_events( \
       array(select row(decode(p->>0, 'hex'), (p->>1)::int8)::post from jsonb_array_elements($posts_json::jsonb) x(p)), \
       $?user_pubkey, $apply_humaness_check, $orderby) f(e) where e is not null"]
  |> List.filter_map Fun.id

(* app_ext.jl scored_users: best score24h per author since [since] *)
let scored_users (c : Db.cache Db.conn) ~since ~limit : (string * int64) list =
  let dbh = Db.raw c in
  let since = i64 since and limit = i64 limit in
  [%pgsql dbh
    "select encode(author_pubkey, 'hex'), max(score24h) as maxscore from event_stats where $since <= created_at \
     group by author_pubkey order by maxscore desc limit $limit"]
  |> List.filter_map (function Some pk, Some v -> Some (pk, v) | _ -> None)

(* scored_users' filter: unblocked, or not analytics-blocked, not domain-hidden and followers >= 5 *)
let scored_users_pass (c : Db.cache Db.conn) ~(pubkeys_json : string) ~(domains_json : string) : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select a::text from jsonb_array_elements_text($pubkeys_json::jsonb) x(a) \
     where exists (select 1 from filterlist fl where fl.target = decode(a::text, 'hex') and fl.target_type = 'pubkey' and not fl.blocked) \
        or (not exists (select 1 from filterlist fl where fl.target = decode(a::text, 'hex') and fl.target_type = 'pubkey' and fl.blocked and fl.grp = 'trending') \
            and not exists (select 1 from meta_data md, events e, jsonb_array_elements_text($domains_json::jsonb) d \
                            where md.key = decode(a::text, 'hex') and e.id = md.value \
                              and (lower(substring(e.content from '\"nip05\"\\s*:\\s*\"[^\"@]*@([^\"]+)\"')) = d::text \
                                   or lower(substring(e.content from '\"nip05\"\\s*:\\s*\"[^\"@]*@([^\"]+)\"')) like '%.' || d::text)) \
            and coalesce((select pfc.value from pubkey_followers_cnt pfc where pfc.key = decode(a::text, 'hex')), 0) >= 5)"]
  |> List.filter_map Fun.id

(* Julia followers(est, pubkey): up to 10000 followers *)
let followers_hex (c : Db.cache Db.conn) ~pubkey : string list =
  let dbh = Db.raw c in
  [%pgsql dbh "select encode(follower_pubkey, 'hex') from pubkey_followers where pubkey = $pubkey limit 10000"] |> List.filter_map Fun.id

(* app_ext.jl trending_hashtags: (hashtag, author followers, author post count) in created_at order,
   for the whitelisted hashtags since [since] *)
let hashtag_rows (c : Db.cache Db.conn) ~since ~(whitelist_json : string) : (string * int64 * int64) list =
  let dbh = Db.raw c in
  let since = i64 since in
  [%pgsql dbh
    "with h as (select eh.event_id, eh.hashtag, eh.created_at, eh.rowid from event_hashtags eh \
                where eh.created_at >= $since and eh.hashtag = any(array(select jsonb_array_elements_text($whitelist_json::jsonb)))), \
          he as (select h.hashtag, h.created_at, h.rowid, ev.pubkey from h join events ev on ev.id = h.event_id), \
          st as (select a.pubkey, (select count(1) from pubkey_events pe where pe.pubkey = a.pubkey) as nposts, \
                        coalesce((select pfc.value from pubkey_followers_cnt pfc where pfc.key = a.pubkey), 0) as followers \
                 from (select distinct pubkey from he) a) \
     select he.hashtag, st.followers, st.nposts from he join st on st.pubkey = he.pubkey order by he.created_at asc, he.rowid asc"]
  |> List.filter_map (function Some h, Some f, Some n -> Some (h, f, n) | _ -> None)

(* app.jl explore_zaps *)
(* Main.TrustRank.humaness_threshold[]: the rank of the 50000th best pubkey (dag.jl) *)
let humaness_threshold (c : Db.cache Db.conn) : float =
  let dbh = Db.raw c in
  match [%pgsql dbh "select humaness_threshold_trustrank()"] with Some t :: _ -> t | _ -> 0.0

let explore_zaps (c : Db.cache Db.conn) ~since ~until ~created_after ~limit ~offset : zap_row list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until and created_after = i64 created_after and limit = i64 limit and offset = i64 offset in
  (* the threshold evaluated once (a CTE), not per row *)
  [%pgsql dbh
    "with th as materialized (select humaness_threshold_trustrank() as rank) \
     select zr.zap_receipt_id, zr.created_at, zr.event_id, zr.sender, zr.receiver, zr.amount_sats \
     from og_zap_receipts zr, pubkey_trustrank tr, events es, th \
     where zr.amount_sats >= $since and zr.amount_sats <= $until and zr.created_at >= $created_after \
       and zr.sender = tr.pubkey and tr.rank >= th.rank \
       and zr.event_id = es.id and es.kind = any ('{1, 30023}'::int8[]) \
     order by zr.amount_sats desc, zr.event_id asc limit $limit offset $offset"]
  |> List.filter_map (fun (zid, ca, eid, s, r, a) ->
         match (zid, ca, a) with
         | Some zap_receipt_id, Some zr_created_at, Some amount_sats ->
             Some { zap_receipt_id; zr_created_at; zr_event_id = eid; sender = s; receiver = r; amount_sats }
         | _ -> None)

type people_row = { p_pubkey : string; p_cnt : int64; p_increase : int64; p_ratio : float }

(* app.jl explore_people: follower-count increases outside the viewer's follows *)
let explore_people (c : Db.cache Db.conn) ~user_pubkey ~since ~until ~limit ~offset : people_row list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until and limit = i64 limit and offset = i64 offset in
  [%pgsql dbh
    "select dfi.pubkey, dfi.cnt, dfi.increase, dfi.ratio from daily_followers_cnt_increases dfi \
     where dfi.increase >= $since and dfi.increase <= $until \
       and not exists (select 1 from pubkey_followers pf1 where pf1.follower_pubkey = $user_pubkey and pf1.pubkey = dfi.pubkey) \
       and user_has_bio(dfi.pubkey) \
     order by dfi.increase desc, dfi.pubkey asc limit $limit offset $offset"]
  |> List.map (fun (p_pubkey, p_cnt, p_increase, p_ratio) -> { p_pubkey; p_cnt; p_increase; p_ratio })

(* est.dyn[:cache][key]: a JSON array of messages *)
let cache_messages (c : Db.cache Db.conn) ~(key : string) : string list =
  let dbh = Db.raw c in
  [%pgsql dbh "select jsonb_array_elements(value)::text from cache where key = $key"] |> List.filter_map Fun.id

(* app_ext.jl explore_legend_counts: follows (the contact list, i.e. pubkey_followers rows of the
   follower), inner network = follows + up to 10000 followers, outer network = follows + their follows *)
let legend_counts (c : Db.cache Db.conn) ~pubkey : int64 * int64 * int64 =
  let dbh = Db.raw c in
  match
    [%pgsql dbh
      "with f as (select pubkey from pubkey_followers where follower_pubkey = $pubkey), \
            fl as (select follower_pubkey as pubkey from pubkey_followers where pubkey = $pubkey limit 10000) \
       select (select count(*) from f), \
              (select count(distinct pubkey) from (select pubkey from f union all select pubkey from fl) x), \
              (select count(distinct pf2.pubkey) from (select pubkey from f union all select pf2.pubkey from f join pubkey_followers pf2 on pf2.follower_pubkey = f.pubkey) pf2)"]
  with
  | (Some a, Some b, Some d) :: _ -> (a, b, d)
  | _ -> (0L, 0L, 0L)

(* {1 The long tail of app.jl / app_ext.jl} *)

let directmsgs (c : Db.cache Db.conn) ~receiver ~sender ~since ~until ~limit ~offset : (string * int64) list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until and limit = i64 limit and offset = i64 offset in
  [%pgsql dbh
    "select encode(event_id, 'hex'), created_at from pubkey_directmsgs \
     where ((receiver = $receiver and sender = $sender) or (receiver = $sender and sender = $receiver)) \
       and created_at >= $since and created_at <= $until order by created_at desc limit $limit offset $offset"]
  |> List.filter_map (function Some e, Some t -> Some (e, t) | _ -> None)

type dm_contact = { latest_event_id : string option; latest_at : int64; peer : string; dm_cnt : int64 }

let dm_rows l =
  List.filter_map
    (fun (eid, at, peer, cnt) -> match (at, peer) with Some latest_at, Some peer -> Some { latest_event_id = eid; latest_at; peer; dm_cnt = Option.value cnt ~default:0L } | _ -> None)
    l

(* app.jl get_directmsg_contacts_2: peers that wrote to the user, and peers the user wrote to *)
let directmsg_contacts_in (c : Db.cache Db.conn) ~user ~since ~until : dm_contact list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until in
  dm_rows
    [%pgsql dbh
      "select encode(latest_event_id, 'hex'), latest_at, encode(sender, 'hex'), cnt from pubkey_directmsgs_cnt \
       where receiver = $user and sender is not null and latest_at >= $since and latest_at <= $until order by latest_at desc limit 10000"]

let directmsg_contacts_out (c : Db.cache Db.conn) ~user ~since ~until : dm_contact list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until in
  dm_rows
    [%pgsql dbh
      "select encode(latest_event_id, 'hex'), latest_at, encode(receiver, 'hex'), 0::int8 from pubkey_directmsgs_cnt \
       where sender = $user and latest_at >= $since and latest_at <= $until order by latest_at desc limit 10000"]

let directmsg_cnt (c : Db.cache Db.conn) ~receiver ~sender : int64 option =
  let dbh = Db.raw c in
  match
    [%pgsql dbh
      "select cnt from pubkey_directmsgs_cnt where receiver = $receiver and (case when $?sender::bytea is null then sender is null else sender = $?sender::bytea end) limit 1"]
  with
  | Some v :: _ -> Some v
  | _ -> None

let reset_directmsg_count (c : Db.cache Db.conn) ~receiver ~sender ~by : unit =
  let dbh = Db.raw c in
  ignore
    [%pgsql dbh
      "update pubkey_directmsgs_cnt set cnt = greatest(0, cnt - $by) \
       where receiver = $receiver and (case when $?sender::bytea is null then sender is null else sender = $?sender::bytea end)"]

let reset_directmsg_counts (c : Db.cache Db.conn) ~receiver : unit =
  let dbh = Db.raw c in
  ignore [%pgsql dbh "update pubkey_directmsgs_cnt set cnt = 0 where receiver = $receiver"]

let zap_rows l =
  List.filter_map
    (fun (zid, ca, eid, s, r, a) ->
      match (zid, ca, a) with
      | Some zap_receipt_id, Some zr_created_at, Some amount_sats -> Some { zap_receipt_id; zr_created_at; zr_event_id = eid; sender = s; receiver = r; amount_sats }
      | _ -> None)
    l

(* app.jl zaps_feed: per pubkey, zaps sent or received, newest first *)
let zaps_of_pubkeys (c : Db.cache Db.conn) ~(pubkeys_json : string) ~since ~until ~limit ~offset : zap_row list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until and limit = i64 limit and offset = i64 offset in
  zap_rows
    [%pgsql dbh
      "select zr.zap_receipt_id, zr.created_at, zr.event_id, zr.sender, zr.receiver, zr.amount_sats \
       from jsonb_array_elements_text($pubkeys_json::jsonb) x(a) cross join lateral \
         (select z.zap_receipt_id, z.created_at, z.event_id, z.sender, z.receiver, z.amount_sats from og_zap_receipts z \
          where (z.sender = decode(a::text, 'hex') or z.receiver = decode(a::text, 'hex')) and z.created_at >= $since and z.created_at <= $until \
          order by z.created_at desc limit $limit offset $offset) zr"]

let zaps_by_sender (c : Db.cache Db.conn) ~sender ~since ~until ~limit ~offset : zap_row list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until and limit = i64 limit and offset = i64 offset in
  zap_rows
    [%pgsql dbh
      "select zap_receipt_id, created_at, event_id, sender, receiver, amount_sats from og_zap_receipts \
       where sender = $sender and created_at >= $since and created_at <= $until order by created_at desc limit $limit offset $offset"]

let zaps_by_receiver (c : Db.cache Db.conn) ~receiver ~since ~until ~limit ~offset : zap_row list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until and limit = i64 limit and offset = i64 offset in
  zap_rows
    [%pgsql dbh
      "select zap_receipt_id, created_at, event_id, sender, receiver, amount_sats from og_zap_receipts \
       where receiver = $receiver and created_at >= $since and created_at <= $until order by created_at desc limit $limit offset $offset"]

let zaps_by_receiver_amount (c : Db.cache Db.conn) ~receiver ~since ~until ~limit ~offset : zap_row list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until and limit = i64 limit and offset = i64 offset in
  zap_rows
    [%pgsql dbh
      "select zap_receipt_id, created_at, event_id, sender, receiver, amount_sats from og_zap_receipts \
       where receiver = $receiver and amount_sats >= $since and amount_sats <= $until order by amount_sats desc limit $limit offset $offset"]

(* app.jl event_actions *)
let event_action_refs (c : Db.cache Db.conn) ~event_id ~kind ~limit ~offset : (string * string) list =
  let dbh = Db.raw c in
  let kind = i64 kind and limit = i64 limit and offset = i64 offset in
  [%pgsql dbh
    "select encode(ref_event_id, 'hex'), encode(ref_pubkey, 'hex') from event_pubkey_action_refs \
     where event_id = $event_id and ref_kind = $kind order by ref_created_at desc limit $limit offset $offset"]
  |> List.filter_map (function Some e, Some p -> Some (e, p) | _ -> None)

let event_action_refs_article (c : Db.cache Db.conn) ~pubkey ~identifier ~kind ~limit ~offset : (string * string) list =
  let dbh = Db.raw c in
  let kind = i64 kind and limit = i64 limit and offset = i64 offset in
  [%pgsql dbh
    "select encode(r.ref_event_id, 'hex'), encode(r.ref_pubkey, 'hex') from reads_versions rv, event_pubkey_action_refs r \
     where rv.pubkey = $pubkey and rv.identifier = $identifier and rv.eid = r.event_id and r.ref_kind = $kind \
     order by r.ref_created_at desc limit $limit offset $offset"]
  |> List.filter_map (function Some e, Some p -> Some (e, p) | _ -> None)

(* app.jl user_followers: mutual followers first, then the most followed *)
let user_followers_mutual (c : Db.cache Db.conn) ~pubkey : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select encode(pf1.follower_pubkey, 'hex') from pubkey_followers pf1, pubkey_followers pf2 \
     where pf1.pubkey = $pubkey and pf2.pubkey = pf1.follower_pubkey and pf2.follower_pubkey = $pubkey"]
  |> List.filter_map Fun.id

let user_followers_top (c : Db.cache Db.conn) ~pubkey ~limit : string list =
  let dbh = Db.raw c in
  let limit = i64 limit in
  [%pgsql dbh
    "select distinct encode(pf.follower_pubkey, 'hex'), pfc.value from pubkey_followers pf, pubkey_followers_cnt pfc \
     where pf.pubkey = $pubkey and pf.follower_pubkey = pfc.key order by pfc.value desc limit $limit"]
  |> List.filter_map (fun (p, _) -> p)

(* app.jl mutual_follows: the viewer's follows that follow [pubkey] *)
let mutual_follows (c : Db.cache Db.conn) ~pubkey ~user_pubkey : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select encode(pf.pubkey, 'hex') from pubkey_followers pf where pf.follower_pubkey = $user_pubkey \
       and exists (select 1 from pubkey_followers pf2 where pf2.pubkey = $pubkey and pf2.follower_pubkey = pf.pubkey)"]
  |> List.filter_map Fun.id

let reposts_of (c : Db.cache Db.conn) ~pubkey ~event_id : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select get_event_jsonb(es.id)::text from basic_tags bt, events es \
     where bt.tag = 'e' and bt.arg1 = $event_id and bt.id = es.id and es.kind = 6 and bt.pubkey = $pubkey"]
  |> List.filter_map Fun.id

(* app.jl follow_lists without the whitelist: recent kind-39089 lists by non-spam authors *)
let follow_packs (c : Db.cache Db.conn) ~since ~until ~limit ~offset : string list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until and limit = i64 limit and offset = i64 offset in
  [%pgsql dbh
    "select get_event_jsonb(es.id)::text from parametrized_replaceable_events pre, events es \
     where pre.kind = 39089 and pre.created_at >= $since and pre.created_at <= $until and pre.event_id = es.id \
       and not exists (select 1 from filterlist fl where fl.target = pre.pubkey and fl.target_type = 'pubkey' and fl.grp = 'spam' and fl.blocked) \
     order by pre.created_at desc limit $limit offset $offset"]
  |> List.filter_map Fun.id

let most_followed_of (c : Db.cache Db.conn) ~(pubkeys_json : string) ~limit : string list =
  let dbh = Db.raw c in
  let limit = i64 limit in
  [%pgsql dbh
    "select encode(key, 'hex') from pubkey_followers_cnt \
     where key = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($pubkeys_json::jsonb) x(a))) order by value desc limit $limit"]
  |> List.filter_map Fun.id

let param_list_event_ids (c : Db.cache Db.conn) ~pubkey ~identifier : string list =
  let dbh = Db.raw c in
  [%pgsql dbh "select encode(event_id, 'hex') from parameterized_replaceable_list where pubkey = $pubkey and identifier = $identifier"]
  |> List.filter_map Fun.id

let ln_address_pubkey (c : Db.cache Db.conn) ~(ln_address : string) : string option =
  let dbh = Db.raw c in
  match [%pgsql dbh "select pubkey from pubkey_ln_address where ln_address = $ln_address limit 1"] with Some p :: _ -> Some p | _ -> None

let relays_top (c : Db.cache Db.conn) ~limit : (string * int64) list =
  let dbh = Db.raw c in
  let limit = i64 limit in
  [%pgsql dbh "select url, times_referenced from relays order by times_referenced desc limit $limit"]

let trustrank_top (c : Db.cache Db.conn) ~limit : (string * float) list =
  let dbh = Db.raw c in
  let limit = i64 limit in
  [%pgsql dbh "select encode(pubkey, 'hex'), rank from pubkey_trustrank order by rank desc limit $limit"]
  |> List.filter_map (function Some p, r -> Some (p, r) | _ -> None)

(* app.jl articles_stats *)
let articles_stats (c : Db.cache Db.conn) ~pubkey ~kind : int64 * int64 * int64 =
  let dbh = Db.raw c in
  let kind = string_of_int kind in
  match
    [%pgsql dbh
      "select (select count(1) from reads where pubkey = $pubkey)::int8, \
              (select count(distinct ts.id) from (select id, jsonb_array_elements(tags) ->> 0 as tag, jsonb_array_elements(tags) ->> 1 as arg from events where pubkey = $pubkey and kind = 31234) ts \
               where ts.tag = 'k' and ts.arg = $kind)::int8, \
              (select coalesce(sum(satszapped), 0) from reads where pubkey = $pubkey)::int8"]
  with
  | (a, d, s) :: _ -> (Option.value a ~default:0L, Option.value d ~default:0L, Option.value s ~default:0L)
  | [] -> (0L, 0L, 0L)

let drafts (c : Db.cache Db.conn) ~pubkey ~kind ~since ~until ~limit ~offset : string list =
  let dbh = Db.raw c in
  let kind = string_of_int kind and since = i64 since and until = i64 until and limit = i64 limit and offset = i64 offset in
  [%pgsql dbh
    "with ts as (select id, jsonb_array_elements(tags) ->> 0 as tag, jsonb_array_elements(tags) ->> 1 as arg from events where pubkey = $pubkey and kind = 31234) \
     select get_event_jsonb(es.id)::text from ts, events es \
     where ts.arg = $kind and ts.id = es.id and es.created_at >= $since and es.created_at <= $until \
     order by es.created_at desc limit $limit offset $offset"]
  |> List.filter_map Fun.id

let top_article_eid (c : Db.cache Db.conn) ~pubkey ~(by : string) : string option =
  let dbh = Db.raw c in
  let r =
    match by with
    | "satszapped" -> [%pgsql dbh "select encode(latest_eid, 'hex') from reads where pubkey = $pubkey order by satszapped desc limit 1"]
    | "interactions" -> [%pgsql dbh "select encode(latest_eid, 'hex') from reads where pubkey = $pubkey order by (likes + zaps + replies + reposts) desc limit 1"]
    | _ -> []
  in
  match r with Some e :: _ -> Some e | _ -> None

(* reads row of an article as Julia's EVENT_STATS content *)
let reads_stats (c : Db.cache Db.conn) ~eid : (int64 * int64 * int64 * int64 * int64) option =
  let dbh = Db.raw c in
  match [%pgsql dbh "select likes, replies, reposts, zaps, satszapped from reads where latest_eid = $eid limit 1"] with
  | (l, r, rp, z, s) :: _ -> Some (Option.value l ~default:0L, Option.value r ~default:0L, Option.value rp ~default:0L, Option.value z ~default:0L, Option.value s ~default:0L)
  | [] -> None

(* app.jl thread_view_parents: the chain of thread parents (event_thread_parents), stored events only *)
let thread_parents (c : Db.cache Db.conn) ~event_id : (string * int64) list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "with recursive p as (select $event_id::bytea as id, 0 as d union all select etp.value, p.d + 1 from p join event_thread_parents etp on etp.key = p.id where p.d < 200) \
     select encode(e.id, 'hex'), e.created_at from p join events e on e.id = p.id order by e.created_at asc"]
  |> List.filter_map (function Some e, Some t -> Some (e, t) | _ -> None)

let event_replies (c : Db.cache Db.conn) ~event_id ~since ~until ~limit ~offset : (string * int64) list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until and limit = i64 limit and offset = i64 offset in
  [%pgsql dbh
    "select encode(reply_event_id, 'hex'), reply_created_at from event_replies \
     where event_id = $event_id and reply_created_at >= $since and reply_created_at <= $until order by reply_created_at desc limit $limit offset $offset"]
  |> List.filter_map (function Some e, Some t -> Some (e, t) | _ -> None)

(* app.jl long_form_content_replies (before the root-tag filter) *)
let lfc_replies (c : Db.cache Db.conn) ~pubkey ~identifier ~since ~until ~limit ~offset : (string * int64) list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until and limit = i64 limit and offset = i64 offset in
  [%pgsql dbh
    "with a as (select er.reply_event_id as eid, er.reply_created_at as created_at from reads_versions rv, event_replies er \
                where rv.pubkey = $pubkey and rv.identifier = $identifier and rv.eid = er.event_id and er.reply_created_at >= $since and er.reply_created_at <= $until), \
          b as (select at.eid, at.created_at from a_tags at \
                where at.kind = 1 and at.ref_kind = 30023 and at.ref_pubkey = $pubkey and at.ref_identifier = $identifier and at.created_at >= $since and at.created_at <= $until) \
     select encode(eid, 'hex'), created_at from ((select * from a) union (select * from b)) u order by created_at desc limit $limit offset $offset"]
  |> List.filter_map (function Some e, Some t -> Some (e, t) | _ -> None)

let event_tags_of (c : Db.cache Db.conn) ~(event_ids_json : string) : (string * string) list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select encode(id, 'hex'), tags::text from events where id = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($event_ids_json::jsonb) x(a)))"]
  |> List.filter_map (function Some i, Some t -> Some (i, t) | _ -> None)

let scored_media_eids (c : Db.cache Db.conn) ~pubkey ~limit : string list =
  let dbh = Db.raw c in
  let limit = i64 limit in
  [%pgsql dbh
    "select encode(es.event_id, 'hex') from event_stats es, event_media em \
     where es.author_pubkey = $pubkey and es.event_id = em.event_id order by es.score24h desc limit $limit"]
  |> List.filter_map Fun.id

(* app.jl highlights (article form): kind 1 / 9802 events referencing the article, hidden ones out *)
let article_highlights (c : Db.cache Db.conn) ~pubkey ~identifier ~kind : string list =
  let dbh = Db.raw c in
  let kind = i64 kind in
  [%pgsql dbh
    "select get_event_jsonb(e.id)::text from a_tags at, events e \
     where at.ref_pubkey = $pubkey and at.ref_identifier = $identifier and at.ref_kind = $kind and (at.kind = 1 or at.kind = 9802) and at.eid = e.id \
       and not exists (select 1 from filterlist fl where fl.target = e.id and fl.target_type = 'event' and fl.blocked) \
       and not exists (select 1 from deleted_events de where de.event_id = e.id) \
     order by at.created_at desc"]
  |> List.filter_map Fun.id

(* the pubkeys of [hexes] whose metadata event's nip05 domain is one of [domains_json] *)
let domain_hidden_pubkeys (c : Db.cache Db.conn) ~(pubkeys_json : string) ~(domains_json : string) : string list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select a::text from jsonb_array_elements_text($pubkeys_json::jsonb) x(a) \
     where exists (select 1 from meta_data md, events e, jsonb_array_elements_text($domains_json::jsonb) d \
                   where md.key = decode(a::text, 'hex') and e.id = md.value \
                     and (lower(substring(e.content from '\"nip05\"\\s*:\\s*\"[^\"@]*@([^\"]+)\"')) = d::text \
                          or lower(substring(e.content from '\"nip05\"\\s*:\\s*\"[^\"@]*@([^\"]+)\"')) like '%.' || d::text))"]
  |> List.filter_map Fun.id

let media_note_ids (c : Db.cache Db.conn) ~pubkey ~since ~until ~limit ~offset : (string * int64) list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until and limit = i64 limit and offset = i64 offset in
  [%pgsql dbh
    "select distinct encode(es.id, 'hex'), es.created_at from events es, event_media em \
     where es.pubkey = $pubkey and es.kind = 1 and es.id = em.event_id and es.created_at >= $since and es.created_at <= $until \
     order by es.created_at desc limit $limit offset $offset"]
  |> List.filter_map (function Some e, Some t -> Some (e, t) | _ -> None)

(* {1 response_messages_for_posts building blocks} *)

type stats_row = { st_eid : string; likes : int64; replies : int64; mentions : int64; reposts : int64; zaps : int64; satszapped : int64; score : int64; score24h : int64 }

let event_stats_rows (c : Db.cache Db.conn) ~(event_ids_json : string) : stats_row list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select encode(event_id, 'hex'), likes, replies, mentions, reposts, zaps, satszapped, score, score24h from event_stats \
     where event_id = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($event_ids_json::jsonb) x(a)))"]
  |> List.filter_map (fun (e, l, r, m, rp, z, s, sc, s24) ->
         match e with
         | Some st_eid ->
             let z0 = Option.value ~default:0L in
             Some { st_eid; likes = z0 l; replies = z0 r; mentions = z0 m; reposts = z0 rp; zaps = z0 z; satszapped = z0 s; score = z0 sc; score24h = z0 s24 }
         | None -> None)

(* app.jl ext_long_form_event_stats: reads row of the article version *)
let reads_stats_rows (c : Db.cache Db.conn) ~(event_ids_json : string) : (string * (int64 * int64 * int64 * int64 * int64)) list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select encode(latest_eid, 'hex'), likes, zaps, satszapped, replies, reposts from reads \
     where latest_eid = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($event_ids_json::jsonb) x(a)))"]
  |> List.filter_map (fun (e, l, z, s, r, rp) ->
         match e with
         | Some e -> let z0 = Option.value ~default:0L in Some (e, (z0 l, z0 z, z0 s, z0 r, z0 rp))
         | None -> None)

let event_relays_rows (c : Db.cache Db.conn) ~(event_ids_json : string) : (string * string) list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select encode(er.event_id, 'hex'), coalesce(rum.dest, er.relay_url) from event_relay er left join relay_url_map rum on rum.src = er.relay_url \
     where er.event_id = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($event_ids_json::jsonb) x(a)))"]
  |> List.filter_map (function Some e, Some r when r <> "" -> Some (e, r) | _ -> None)

(* app.jl event_actions_cnt for many events of one viewer: (hex, replied, liked, reposted, zapped) *)
let event_actions_rows (c : Db.cache Db.conn) ~(event_ids_json : string) ~user_pubkey : (string * (bool * bool * bool * bool)) list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select encode(event_id, 'hex'), replied, liked, reposted, zapped from event_pubkey_actions \
     where pubkey = $user_pubkey and event_id = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($event_ids_json::jsonb) x(a)))"]
  |> List.filter_map (fun (e, r, l, rp, z) ->
         match e with
         | Some e -> let b = function Some v -> v <> 0L | None -> false in Some (e, (b r, b l, b rp, b z))
         | None -> None)

let poll_votes_rows (c : Db.cache Db.conn) ~(event_ids_json : string) ~user_pubkey : (string * string) list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select encode(poll_id, 'hex'), option_id from poll_user_votes \
     where pubkey = $user_pubkey and poll_id = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($event_ids_json::jsonb) x(a)))"]
  |> List.filter_map (function Some e, Some o -> Some (e, o) | _ -> None)

(* ext_event_response for many events: media then previews, keyed by event hex *)
let event_extras_rows (c : Db.cache Db.conn) ~(event_ids_json : string) : (string * string) list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select encode(x.id, 'hex'), r.e::text from (select decode(a::text, 'hex') as id from jsonb_array_elements_text($event_ids_json::jsonb) x(a)) x, event_media_response(x.id) r(e) \
     union all \
     select encode(x.id, 'hex'), r.e::text from (select decode(a::text, 'hex') as id from jsonb_array_elements_text($event_ids_json::jsonb) x(a)) x, event_preview_response(x.id) r(e)"]
  |> List.filter_map (function Some e, Some m -> Some (e, m) | _ -> None)

(* event_zaps_by_satszapped, article form: zap_receipts of every version of the article *)
let article_zaps_top (c : Db.cache Db.conn) ~pubkey ~identifier ~limit : zap_row list =
  let dbh = Db.raw c in
  let limit = i64 limit in
  [%pgsql dbh
    "select zr.eid, zr.created_at, zr.target_eid, zr.sender, zr.receiver, zr.satszapped from reads_versions rv, zap_receipts zr \
     where rv.pubkey = $pubkey and rv.identifier = $identifier and rv.eid = zr.target_eid order by zr.satszapped desc limit $limit"]
  |> zap_rows

let parametrized_event_id_one (c : Db.cache Db.conn) ~pubkey ~kind ~(identifier : string) : string option =
  let dbh = Db.raw c in
  let kind = i64 kind in
  match
    [%pgsql dbh "select encode(event_id, 'hex') from parametrized_replaceable_events where pubkey = $pubkey and kind = $kind and identifier = $identifier limit 1"]
  with
  | Some e :: _ -> Some e
  | _ -> None

(* {1 Advanced search and the feeds built on it} *)

(* app.jl important_notes_i_might_have_missed_feed: reposts by follows in the last 24 h *)
let important_notes (c : Db.cache Db.conn) ~user_pubkey ~reposted_after ~since ~until ~limit ~offset : (string * int64) list =
  let dbh = Db.raw c in
  let reposted_after = i64 reposted_after and since = i64 since and until = i64 until and limit = i64 limit and offset = i64 offset in
  [%pgsql dbh
    "select encode(es.id, 'hex'), es.created_at from events es, basic_tags bt, pubkey_followers pf \
     where pf.follower_pubkey = $user_pubkey and pf.pubkey = bt.pubkey and bt.kind = 6 and bt.created_at >= $reposted_after \
       and bt.tag = 'e' and bt.id = es.id and es.created_at >= $since and es.created_at <= $until \
     order by es.created_at desc limit $limit offset $offset"]
  |> List.filter_map (function Some id, Some t -> Some (id, t) | _ -> None)

(* app.jl muted_threads_feed: the e-tagged events of the user's mute list *)
let muted_threads (c : Db.cache Db.conn) ~user_pubkey ~since ~until ~limit ~offset : (string * int64) list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until and limit = i64 limit and offset = i64 offset in
  [%pgsql dbh
    "select encode(es.id, 'hex'), es.created_at from replaceable_events re, basic_tags bt, events es \
     where re.pubkey = $user_pubkey and re.kind = 10000 and re.event_id = bt.id and bt.tag = 'e' and bt.arg1 = es.id \
       and es.created_at >= $since and es.created_at <= $until \
     order by es.created_at desc limit $limit offset $offset"]
  |> List.filter_map (function Some id, Some t -> Some (id, t) | _ -> None)

(* app_ext.jl wide_net_notes_feed: events e-tagged by notes/reposts/reactions/zaps of the follows *)
let wide_net_notes (c : Db.cache Db.conn) ~pubkey ~since ~until ~limit ~offset : (string * int64) list =
  let dbh = Db.raw c in
  let since = i64 since and until = i64 until and limit = i64 limit and offset = i64 offset in
  [%pgsql dbh
    "select es.id, es.created_at from pubkey_followers pf, basic_tags bt1, basic_tags bt2, events es \
     where pf.follower_pubkey = $pubkey \
       and (bt1.kind = 1 or bt1.kind = 6 or bt1.kind = 7 or bt1.kind = 9735) and bt1.pubkey = pf.pubkey \
       and bt1.id = bt2.id and bt2.tag = 'e' and bt2.arg1 = es.id and es.created_at >= $since and es.created_at <= $until \
     order by es.created_at desc limit $limit offset $offset"]
  |> List.filter_map (function Some id, Some t -> Some (Hex_util.encode id, t) | _ -> None)

(* {1 The remaining readers} *)

(* app.jl get_dvm_feeds / get_featured_dvm_feeds: NIP-89 handler events of content-discovery DVMs
   whose feed was fetched successfully in the last hour (dvm_feeds.updated_at is naive local time).
   Julia joined the event_tags view (every tag of every kind-31990 event: 2.3 M events, 3-23 s); the
   same rows come from the few fresh dvm_feeds rows, their pubkeys' 31990 events ((pubkey, kind,
   identifier) index) and a look at those events' own tags (4 ms). *)
let dvm_feed_eids (c : Db.cache Db.conn) ~(featured : bool) ~(kind : string option) : string list =
  let dbh = Db.raw c in
  let kind = if featured then kind else None in
  [%pgsql dbh
    "select distinct encode(pre.event_id, 'hex') from dvm_feeds df, parametrized_replaceable_events pre, events es \
     where df.updated_at >= now()::timestamp - interval '1 hour' and df.ok \
       and (case when $?kind::text is null then true else df.kind = $?kind end) \
       and pre.pubkey = df.pubkey and pre.kind = 31990 and es.id = pre.event_id and es.kind = 31990 \
       and exists (select 1 from jsonb_array_elements(es.tags) t where t->>0 = 'k' and t->>1 = '5300')"]
  |> List.filter_map Fun.id

let dvm_likes (c : Db.cache Db.conn) ~pubkey ~(identifier : string) : int64 =
  let dbh = Db.raw c in
  match [%pgsql dbh "select count(1) from a_tags where kind = 7 and ref_kind = 31990 and ref_pubkey = $pubkey and ref_identifier = $identifier"] with
  | Some n :: _ -> n
  | _ -> 0L

let dvm_satszapped (c : Db.cache Db.conn) ~pubkey : int64 =
  let dbh = Db.raw c in
  match [%pgsql dbh "select coalesce(sum(satszapped), 0)::int8 from zap_receipts where receiver = $pubkey"] with Some n :: _ -> n | _ -> 0L

let dvm_feed_kinds (c : Db.cache Db.conn) ~pubkey ~(identifier : string) : string option list =
  let dbh = Db.raw c in
  [%pgsql dbh "select df.kind from dvm_feeds df where df.pubkey = $pubkey and df.identifier = $identifier"] |> List.map Option.some

(* app.jl get_dvm_feed_follows_actions: the viewer's follows who replied to, reacted to or zapped the DVM feed *)
let dvm_follows_actions_pks (c : Db.cache Db.conn) ~dvm_kind ~dvm_pubkey ~(dvm_id : string) ~user_pubkey ~limit : string list =
  let dbh = Db.raw c in
  let dvm_kind = i64 dvm_kind and limit = i64 limit in
  [%pgsql dbh
    "select encode(pks.pubkey, 'hex') from \
       ((select es.pubkey from a_tags at, event es \
         where at.ref_kind = $dvm_kind and at.ref_pubkey = $dvm_pubkey and at.ref_identifier = $dvm_id and (at.kind = 1 or at.kind = 7) and es.id = at.eid) \
        union \
        (select zr.sender as pubkey from a_tags at, zap_receipts zr \
         where at.ref_kind = $dvm_kind and at.ref_pubkey = $dvm_pubkey and at.ref_identifier = $dvm_id and at.kind = 9735 and at.eid = zr.eid)) pks, \
       pubkey_followers pf, pubkey_followers_cnt pfc \
     where pf.pubkey = pks.pubkey and $user_pubkey = pf.follower_pubkey and pks.pubkey = pfc.key \
     group by pks.pubkey order by max(pfc.value) desc limit $limit"]
  |> List.filter_map Fun.id

let dvm_user_action_kinds (c : Db.cache Db.conn) ~dvm_kind ~dvm_pubkey ~(dvm_id : string) ~user_pubkey : int64 list =
  let dbh = Db.raw c in
  let dvm_kind = i64 dvm_kind in
  [%pgsql dbh
    "select at.kind from a_tags at, event es \
     where at.ref_kind = $dvm_kind and at.ref_pubkey = $dvm_pubkey and at.ref_identifier = $dvm_id and at.eid = es.id and es.pubkey = $user_pubkey"]
  |> List.filter_map Fun.id

let dvm_user_zapped (c : Db.cache Db.conn) ~dvm_kind ~dvm_pubkey ~(dvm_id : string) ~user_pubkey : bool =
  let dbh = Db.raw c in
  let dvm_kind = i64 dvm_kind in
  match
    [%pgsql dbh
      "select 1 from a_tags at, zap_receipts zr \
       where at.ref_kind = $dvm_kind and at.ref_pubkey = $dvm_pubkey and at.ref_identifier = $dvm_id and at.kind = 9735 and at.eid = zr.eid and zr.sender = $user_pubkey limit 1"]
  with
  | [] -> false
  | _ -> true

(* app_ext.jl trending_images *)
let pubkey_events_count (c : Db.cache Db.conn) ~pubkey : int64 =
  let dbh = Db.raw c in
  match [%pgsql dbh "select count(1) from pubkey_events where pubkey = $pubkey"] with Some n :: _ -> n | _ -> 0L

let score24h_of (c : Db.cache Db.conn) ~event_id : int64 option =
  let dbh = Db.raw c in
  match [%pgsql dbh "select score24h from event_stats where event_id = $event_id"] with v :: _ -> v | [] -> None

(* {1 Settings and the remaining writes} *)

(* app.jl invoices_to_zap_receipts: invoice -> zap receipt event JSON *)
let invoices_zap_receipts (c : Db.cache Db.conn) ~(invoices_json : string) : (string * string) list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select zri.invoice, get_event_jsonb(zri.zap_receipt_eid)::text from zap_receipt_invoices zri \
     where zri.invoice = any (array(select jsonb_array_elements_text($invoices_json::jsonb))::varchar[])"]
  |> List.filter_map (function i, Some e -> Some (i, e) | _ -> None)

let poll_stats_options (c : Db.cache Db.conn) ~event_id : string option =
  let dbh = Db.raw c in
  match [%pgsql dbh "select options::text from poll_stats where event_id = $event_id"] with Some o :: _ -> Some o | _ -> None

(* est.events[est.meta_data[pubkey]] *)
let metadata_event_json (c : Db.cache Db.conn) ~pubkey : string option =
  let dbh = Db.raw c in
  match [%pgsql dbh "select get_event_jsonb(md.value)::text from meta_data md where md.key = $pubkey"] with Some j :: _ -> Some j | _ -> None

(* {1 Relay-facing funcalls} *)

let event_relay_url_one (c : Db.cache Db.conn) ~event_id : string option =
  let dbh = Db.raw c in
  match [%pgsql dbh "select relay_url from event_relay where event_id = $event_id limit 1"] with Some u :: _ -> Some u | _ -> None

(* app.jl dvm_feed: the DVM checker's fresh results (updated_at is naive local time) *)
let dvm_feed_results (c : Db.cache Db.conn) ~pubkey : string option =
  let dbh = Db.raw c in
  match
    [%pgsql dbh
      "select results::text from dvm_feeds where pubkey = $pubkey and updated_at >= now()::timestamp - interval '15 minutes' and ok and results is not null limit 1"]
  with
  | Some r :: _ -> Some r
  | _ -> None

(* {1 InternalServices (the internal HTTP port)} *)

(* collect_metadata: the metadata event of every pubkey that has one *)
let metadata_events_json (c : Db.cache Db.conn) ~(pubkeys_json : string) : (string * string) list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select encode(md.key, 'hex'), get_event_jsonb(md.value)::text from meta_data md \
     where md.key = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($pubkeys_json::jsonb) x(a)))"]
  |> List.filter_map (function Some k, Some e -> Some (k, e) | _ -> None)

let media_url_smallest (c : Db.cache Db.conn) ~(url : string) : string option =
  let dbh = Db.raw c in
  match [%pgsql dbh "select media_url from media where url = $url order by (width*height) limit 1"] with Some u :: _ -> Some u | _ -> None

let media_url_largest_still (c : Db.cache Db.conn) ~(url : string) : string option =
  let dbh = Db.raw c in
  match [%pgsql dbh "select media_url from media where url = $url and animated = 0 and size != 'small' order by (width*height) limit 1"] with Some u :: _ -> Some u | _ -> None

let media_url_medium (c : Db.cache Db.conn) ~(url : string) : string option =
  let dbh = Db.raw c in
  match [%pgsql dbh "select media_url from media where url = $url and size = 'medium' and animated = 0 limit 1"] with Some u :: _ -> Some u | _ -> None

let media_known (c : Db.cache Db.conn) ~(url : string) : bool =
  let dbh = Db.raw c in
  match [%pgsql dbh "select 1 from media m where m.url = $url limit 1"] with [] -> false | _ -> true

let event_media_url_one (c : Db.cache Db.conn) ~event_id : string option =
  let dbh = Db.raw c in
  match [%pgsql dbh "select url from event_media where event_id = $event_id limit 1"] with Some u :: _ -> Some u | _ -> None

let video_thumbnail_one (c : Db.cache Db.conn) ~(video_url : string) : string option =
  let dbh = Db.raw c in
  match [%pgsql dbh "select thumbnail_url from video_thumbnails where video_url = $video_url limit 1"] with Some u :: _ -> Some u | _ -> None

(* preview of a live event: the activity whose host is [pubkey] *)
let live_event_id (c : Db.cache Db.conn) ~pubkey ~(identifier : string) : string option =
  let dbh = Db.raw c in
  match
    [%pgsql dbh
      "select encode(event_id, 'hex') from parametrized_replaceable_events pre \
       where pre.kind = 30311 \
         and pre.pubkey = (select pubkey from basic_tags where kind = 30311 and tag = 'p' and arg1 = $pubkey and lower(arg3) = 'host' order by created_at desc limit 1) \
         and pre.identifier = $identifier limit 1"]
  with
  | Some e :: _ -> Some e
  | _ -> None

(* url_lookup: the preferred storage of an upload by its hash *)
let media_storage_url_by_hash (c : Db.cache Db.conn) ~(h : string) : string option =
  let dbh = Db.raw c in
  match
    [%pgsql dbh
      "select media_url from media_storage ms, media_storage_priority msp \
       where ms.h = $h and ms.storage_provider = msp.storage_provider order by msp.priority limit 1"]
  with
  | u :: _ -> Some u
  | [] -> None

(* {1 purge_media_} *)

let media_storage_set_block (c : Db.cache Db.conn) ~(storage_provider : string) ~(h : string) ~(block : string) : unit =
  let dbh = Db.raw c in
  ignore [%pgsql dbh "update media_storage set media_block_id = $block::uuid where storage_provider = $storage_provider and h = $h"]

let media_storage_urls_by_sha256 (c : Db.cache Db.conn) ~sha256 : string list =
  let dbh = Db.raw c in
  [%pgsql dbh "select media_url from media_storage where sha256 = $sha256"]

let media_storage_set_block_by_sha256 (c : Db.cache Db.conn) ~sha256 ~(block : string) ~(cache_only : bool) : unit =
  let dbh = Db.raw c in
  if cache_only then ignore [%pgsql dbh "update media_storage set media_block_id = $block::uuid where sha256 = $sha256 and media_url like '%/cache/%'"]
  else ignore [%pgsql dbh "update media_storage set media_block_id = $block::uuid where sha256 = $sha256"]

let media_cache_urls_by_orig_sha256 (c : Db.cache Db.conn) ~sha256 : string list =
  let dbh = Db.raw c in
  [%pgsql dbh "select media_url from media where orig_sha256 = $sha256 and media_url like '%/cache/%'"] |> List.filter_map Fun.id

let media_urls_for_url (c : Db.cache Db.conn) ~(url : string) : string list =
  let dbh = Db.raw c in
  [%pgsql dbh "select media_url from media where url = $url"] |> List.filter_map Fun.id

let video_thumbnails_for_video (c : Db.cache Db.conn) ~(video_url : string) : string list =
  let dbh = Db.raw c in
  [%pgsql dbh "select thumbnail_url from video_thumbnails where video_url = $video_url"] |> List.filter_map Fun.id

(* {1 Blossom} *)


(* {1 Bookmarks feed, plain events, the membership content funcalls} *)

(* (hex id, kind, created_at) of the stored events among [event_ids_json] that event_created_at
   knows (Julia's bookmarks walk reads created_at from est.event_created_at and skips the rest) *)
let events_meta_by_ids (c : Db.cache Db.conn) ~(event_ids_json : string) : (string * int64 * int64) list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "select encode(e.id, 'hex'), e.kind, eca.created_at from events e, event_created_at eca \
     where e.id = any(array(select decode(a::text, 'hex') from jsonb_array_elements_text($event_ids_json::jsonb) x(a))) and eca.event_id = e.id"]
  |> List.filter_map (function Some h, Some k, Some t -> Some (h, k, t) | _ -> None)

(* membership_content_stats: the author's event counts per kind *)
let kind_counts (c : Db.cache Db.conn) ~pubkey : (int64 * int64) list =
  let dbh = Db.raw c in
  [%pgsql dbh "select kind, count(1) as cnt from events where pubkey = $pubkey group by kind order by cnt desc"]
  |> List.filter_map (function Some k, Some n -> Some (k, n) | _ -> None)

(* membership_recovery_contact_lists_: per day, the author's kind-3 event with most follows, newest 30 days *)
let recovery_contact_lists (c : Db.cache Db.conn) ~pubkey : (string * int64) list =
  let dbh = Db.raw c in
  [%pgsql dbh
    "with cls as (select created_at/(24*3600)::int8 as day, id, created_at, jsonb_array_length(tags) as follows \
                  from events where pubkey = $pubkey and kind = 3) \
     select distinct on (day) encode(id, 'hex'), created_at from cls order by day desc, follows desc, id limit 30"]
  |> List.filter_map (function Some h, Some t -> Some (h, t) | _ -> None)

(* get_user_events: the author's events from [since] in created_at order (event json, kind,
   created_at, the d tag of parametrized replaceable events); [kinds_json] = null for all kinds *)
let user_events (c : Db.cache Db.conn) ~pubkey ~since ~(kinds_json : string option) ~limit : (string * int64 * int64 * string option) list =
  let dbh = Db.raw c in
  let since = i64 since and limit = i64 limit in
  let rows =
    match kinds_json with
    | None ->
        [%pgsql dbh
          "select get_event_jsonb(e.id)::text, e.kind, e.created_at, (select t->>1 from jsonb_array_elements(e.tags) t where t->>0 = 'd' limit 1) \
           from events e where e.pubkey = $pubkey and e.created_at >= $since order by e.created_at asc limit $limit"]
    | Some kinds_json ->
        [%pgsql dbh
          "select get_event_jsonb(e.id)::text, e.kind, e.created_at, (select t->>1 from jsonb_array_elements(e.tags) t where t->>0 = 'd' limit 1) \
           from events e where e.pubkey = $pubkey and e.created_at >= $since \
             and e.kind = any(array(select (a::text)::int8 from jsonb_array_elements_text($kinds_json::jsonb) x(a))) \
           order by e.created_at asc limit $limit"]
  in
  List.filter_map (function Some j, Some k, Some t, d -> Some (j, k, t, d) | _ -> None) rows

(* The number of events a content rebroadcast sends: every non-replaceable event plus one per
   replaceable key (kind 0, 3, 10000-19999: the kind; 30000-39999: kind + d tag) *)
let user_event_count (c : Db.cache Db.conn) ~pubkey ~(kinds_json : string option) : int64 =
  let dbh = Db.raw c in
  let kinds_json = Option.value kinds_json ~default:"null" in
  match
    [%pgsql dbh
      "with es as (select kind, (select t->>1 from jsonb_array_elements(tags) t where t->>0 = 'd' limit 1) as d from events \
                   where pubkey = $pubkey and ($kinds_json::jsonb = 'null'::jsonb or kind = any(array(select (a::text)::int8 from jsonb_array_elements_text($kinds_json::jsonb) x(a))))) \
       select (select count(*) from es where not (kind in (0, 3) or (kind >= 10000 and kind < 20000) or (kind >= 30000 and kind < 40000))) \
            + (select count(distinct kind) from es where kind in (0, 3) or (kind >= 10000 and kind < 20000)) \
            + (select count(distinct (kind, d)) from es where kind >= 30000 and kind < 40000)"]
  with
  | Some n :: _ -> n
  | _ -> 0L
