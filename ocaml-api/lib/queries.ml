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
