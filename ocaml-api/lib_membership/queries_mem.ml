(* Membership-DB queries of the native funcalls (compile-time checked against primal_membership_ref). *)

module PGOCaml = Postgres.PGOCaml

(* ws-connector get_notifications_seen: None when the user has no row (-> NOTICE "unknown user"). *)
let notifications_seen_until (c : Db.membership Db.conn) ~pubkey : int64 option =
  let dbh = Db.raw c in
  match [%pgsql dbh "select seen_until from pubkey_notifications_seen where pubkey = $pubkey"] with
  | Some t :: _ -> Some t
  | None :: _ -> Some 0L
  | [] -> None

(* {1 Phase 3b} *)

(* app_ext.jl get_app_subsettings: the stored settings as JSON text *)
let app_subsettings (c : Db.membership Db.conn) ~pubkey ~(subkey : string) : string option =
  let dbh = Db.raw c in
  match [%pgsql dbh "select settings::text from app_subsettings where pubkey = $pubkey and subkey = $subkey limit 1"] with
  | Some s :: _ -> Some s
  | _ -> None

let set_app_subsettings (c : Db.membership Db.conn) ~pubkey ~(subkey : string) ~updated_at ~(settings_json : string) : unit =
  let dbh = Db.raw c in
  let updated_at = Int64.of_int updated_at in
  ignore
    [%pgsql dbh
      "insert into app_subsettings values ($pubkey, $subkey, $updated_at, $settings_json::jsonb) \
       on conflict (pubkey, subkey) do update set updated_at = $updated_at, settings = $settings_json::jsonb"]

(* app.jl membership_media_management_stats: (upload_type, count, bytes) per type *)
let media_management_stats (c : Db.membership Db.conn) ~pubkey : (string * int64 * int64) list =
  let dbh = Db.raw c in
  [%pgsql dbh "select upload_type, cnt, size from membership_media_management_stats($pubkey)"]
  |> List.filter_map (function
       | Some t, cnt, size -> Some (t, Option.value cnt ~default:0L, Option.value size ~default:0L)
       | _ -> None)

let max_storage (c : Db.membership Db.conn) ~pubkey : int64 option =
  let dbh = Db.raw c in
  match
    [%pgsql dbh
      "select mt.max_storage from memberships ms, membership_tiers mt where ms.pubkey = $pubkey and ms.tier = mt.tier"]
  with
  | Some v :: _ -> Some v
  | _ -> None

(* Julia ext_user_get_settings: a user without an app_settings row gets the default settings *)
let has_app_settings (c : Db.membership Db.conn) ~pubkey : bool =
  let dbh = Db.raw c in
  match [%pgsql dbh "select 1 from app_settings where key = $pubkey limit 1"] with [] -> false | _ -> true

(* the user's app settings JSON (Julia ext_user_get_settings deep-merges it over the defaults) *)
let app_settings_value (c : Db.membership Db.conn) ~pubkey : string option =
  let dbh = Db.raw c in
  match [%pgsql dbh "select value from app_settings where key = $pubkey limit 1"] with
  | Some v :: _ -> Some v
  | _ -> None

(* app_ext.jl set_notifications_seen: est.pubkey_notifications_seen[pubkey] = created_at *)
let set_notifications_seen (c : Db.membership Db.conn) ~pubkey ~seen_until : unit =
  let dbh = Db.raw c in
  let seen_until = Int64.of_int seen_until in
  ignore
    [%pgsql dbh
      "insert into pubkey_notifications_seen (pubkey, seen_until) values ($pubkey, $seen_until) \
       on conflict (pubkey) do update set seen_until = $seen_until"]

type rebroadcast = {
  started_at : float option;
  finished_at : float option;
  event_idx_intermediate : int64 option;
  event_count : int64 option;
  status : string option;
  kinds_json : string option;
}

(* app.jl membership_content_rebroadcast_status *)
let rebroadcast_status (c : Db.membership Db.conn) ~pubkey : rebroadcast option =
  let dbh = Db.raw c in
  match
    [%pgsql dbh
      "select extract(epoch from started_at)::float8, extract(epoch from finished_at)::float8, event_idx_intermediate, event_count, status, kinds::text \
       from event_rebroadcasting where pubkey = $pubkey"]
  with
  | (started_at, finished_at, event_idx_intermediate, event_count, status, kinds_json) :: _ ->
      Some { started_at; finished_at; event_idx_intermediate; event_count; status; kinds_json }
  | [] -> None

(* {1 Phase 4c} *)

(* est.app_settings[pubkey]: the settings event JSON *)
let app_settings_event (c : Db.membership Db.conn) ~pubkey : string option =
  let dbh = Db.raw c in
  match [%pgsql dbh "select value from app_settings where key = $pubkey limit 1"] with Some v :: _ -> Some v | _ -> None

(* get_app_settings stores the synthesized default as the user's settings *)
let insert_app_settings (c : Db.membership Db.conn) ~pubkey ~(value : string) ~event_id ~now : unit =
  let dbh = Db.raw c in
  let now = Int64.of_int now in
  ignore
    [%pgsql dbh
      "insert into app_settings (key, value, accessed_at, created_at, event_id) values ($pubkey, $value, $now, $now, $event_id) on conflict (key) do nothing"]

(* app.jl app_settings(): accessed_at + the log row on every settings call *)
let touch_app_settings (c : Db.membership Db.conn) ~pubkey ~(event_json : string) ~now : unit =
  let dbh = Db.raw c in
  let now = Int64.of_int now in
  ignore [%pgsql dbh "update app_settings set accessed_at = $now where key = $pubkey"];
  ignore [%pgsql dbh "insert into app_settings_log (pubkey, event, accessed_at) values ($pubkey, $event_json::json, $now)"]

let set_last_online (c : Db.membership Db.conn) ~pubkey ~online_at : unit =
  let dbh = Db.raw c in
  let online_at = Int64.of_int online_at in
  ignore
    [%pgsql dbh
      "insert into user_last_online_time (pubkey, online_at) values ($pubkey, $online_at) on conflict (pubkey) do update set online_at = excluded.online_at"]

let report (c : Db.membership Db.conn) ~pubkey ~typ ~id ~now : unit =
  let dbh = Db.raw c in
  let typ = Int64.of_int typ and now = Int64.of_int now in
  ignore [%pgsql dbh "insert into reported (pubkey, type, id, created_at) values ($pubkey, $typ, $id, $now) on conflict do nothing"]

(* {1 Phase 4d} *)

(* dag.jl search: a paying member (tier != 'free') is exempt from the pas:1 limit cap *)
let is_paying (c : Db.membership Db.conn) ~pubkey : bool =
  let dbh = Db.raw c in
  match [%pgsql dbh "select 1 from memberships where pubkey = $pubkey and tier != 'free' limit 1"] with [] -> false | _ -> true

(* app_ext.jl get_list: the curated spam/nsfw allow/block lists Julia loads into Filterlist *)
let list_pubkeys (c : Db.membership Db.conn) ~(list : string) : string list =
  let dbh = Db.raw c in
  [%pgsql dbh "select encode(pubkey, 'hex') from lists where list = $list"] |> List.filter_map Fun.id

(* {1 Phase 4f} *)

(* set_app_settings: est.app_settings[pubkey] = e, then created_at/event_id *)
let upsert_app_settings (c : Db.membership Db.conn) ~pubkey ~(value : string) ~created_at ~event_id : unit =
  let dbh = Db.raw c in
  let created_at = Int64.of_int created_at in
  ignore
    [%pgsql dbh
      "insert into app_settings (key, value, created_at, event_id) values ($pubkey, $value, $created_at, $event_id) \
       on conflict (key) do update set value = excluded.value, created_at = excluded.created_at, event_id = excluded.event_id"]

(* app_ext.jl parse_notification_settings *)
let set_notification_settings (c : Db.membership Db.conn) ~pubkey (settings : (string * bool) list) : unit =
  let dbh = Db.raw c in
  ignore [%pgsql dbh "delete from notification_settings where pubkey = $pubkey"];
  List.iter (fun (typ, enabled) -> ignore [%pgsql dbh "insert into notification_settings (pubkey, type, enabled) values ($pubkey, $typ, $enabled)"]) settings

(* app.jl update_push_notification_token *)
let delete_notification_tokens (c : Db.membership Db.conn) ~(platform : string) ~(token : string) : unit =
  let dbh = Db.raw c in
  ignore [%pgsql dbh "delete from notification_tokens where platform = $platform and token = $token"]

let insert_notification_token (c : Db.membership Db.conn) ~(platform : string) ~(token : string) ~pubkey ~(environment : string option) ~(event_json : string) : unit =
  let dbh = Db.raw c in
  ignore
    [%pgsql dbh
      "insert into notification_tokens (platform, token, pubkey, added_at, environment, event_from_user) values ($platform, $token, $pubkey, now(), $?environment, $event_json::jsonb)"]

(* app.jl update_push_notification_token_for_nip46 *)
let delete_monitoring_tokens (c : Db.membership Db.conn) ~(platform : string) ~(token : string) : unit =
  let dbh = Db.raw c in
  ignore [%pgsql dbh "delete from monitoring_notification_tokens where platform = $platform and token = $token"]

let insert_monitoring_token (c : Db.membership Db.conn) ~(platform : string) ~(token : string) ~service_pubkey ~(relays_json : string) ~(environment : string option)
    ~(event_json : string) ~(client_pubkeys_json : string) ~(scope : string) : unit =
  let dbh = Db.raw c in
  ignore
    [%pgsql dbh
      "insert into monitoring_notification_tokens (platform, token, service_pubkey, relays, added_at, environment, event_from_user, client_pubkeys, scope) \
       values ($platform, $token, $service_pubkey, $relays_json::jsonb, now(), $?environment, $event_json::jsonb, \
               array(select decode(x::text, 'hex') from jsonb_array_elements_text($client_pubkeys_json::jsonb) x), $scope)"]

(* app.jl get_queued_events_for_nip46: take the queued requests of a remote signer *)
let take_queued_nip46_events (c : Db.membership Db.conn) ~service_pubkey : string list =
  let dbh = Db.raw c in
  let rows = [%pgsql dbh "select event::text from monitoring_request_queue where service_pubkey = $service_pubkey"] |> List.filter_map Fun.id in
  ignore [%pgsql dbh "delete from monitoring_request_queue where service_pubkey = $service_pubkey"];
  rows

(* {1 Phase 5: InternalServices} *)

(* nostr_json_query_by_name *)
let verified_pubkeys_by_name (c : Db.membership Db.conn) ~(name : string) : string list =
  let dbh = Db.raw c in
  [%pgsql dbh "select encode(pubkey, 'hex') from verified_users where lower(name) = lower($name)"] |> List.filter_map Fun.id

(* mdpubkey: the membership filterlist's blocked pubkeys get no preview *)
let filterlist_pubkey_blocked (c : Db.membership Db.conn) ~pubkey : bool =
  let dbh = Db.raw c in
  match [%pgsql dbh "select 1 from filterlist where target_type = 'pubkey' and target = $pubkey and blocked limit 1"] with [] -> false | _ -> true

let short_url_by_url (c : Db.membership Db.conn) ~(url : string) : (string * string) option =
  let dbh = Db.raw c in
  match [%pgsql dbh "select path, ext from short_urls where url = $url limit 1"] with (p, e) :: _ -> Some (p, e) | [] -> None

let short_url_next_idx (c : Db.membership Db.conn) : int64 =
  let dbh = Db.raw c in
  match [%pgsql dbh "select nextval('short_urls_idx_seq')"] with Some v :: _ -> v | _ -> failwith "short_urls_idx_seq"

let short_url_insert (c : Db.membership Db.conn) ~idx ~(url : string) ~(path : string) ~(ext : string) : unit =
  let dbh = Db.raw c in
  ignore [%pgsql dbh "insert into short_urls (idx, url, path, ext) values ($idx, $url, $path, $ext)"]

let short_url_target (c : Db.membership Db.conn) ~(path : string) : string option =
  let dbh = Db.raw c in
  match [%pgsql dbh "select url from short_urls where path = $path and media_block_id is null limit 1"] with u :: _ -> Some u | [] -> None

(* {1 Phase 5b: purge_media_} *)

let media_block_insert (c : Db.membership Db.conn) ~(id : string) ~(d : string) : unit =
  let dbh = Db.raw c in
  ignore [%pgsql dbh "insert into media_block (id, t, d) values ($id::uuid, now(), $d::jsonb)"]

let media_block_update (c : Db.membership Db.conn) ~(id : string) ~(d : string) : unit =
  let dbh = Db.raw c in
  ignore [%pgsql dbh "update media_block set d = $d::jsonb where id = $id::uuid"]

let media_uploads_set_block (c : Db.membership Db.conn) ~sha256 ~pubkey ~(block : string) : unit =
  let dbh = Db.raw c in
  ignore [%pgsql dbh "update media_uploads set media_block_id = $block::uuid where sha256 = $sha256 and pubkey = $pubkey"]

let media_uploads_set_block_all (c : Db.membership Db.conn) ~sha256 ~(block : string) : unit =
  let dbh = Db.raw c in
  ignore [%pgsql dbh "update media_uploads set media_block_id = $block::uuid where sha256 = $sha256"]

let media_uploads_set_block_by_path (c : Db.membership Db.conn) ~pubkey ~(path : string) ~(block : string) : unit =
  let dbh = Db.raw c in
  ignore [%pgsql dbh "update media_uploads set media_block_id = $block::uuid where pubkey = $pubkey and path = $path"]

let media_uploads_count (c : Db.membership Db.conn) ~sha256 ~(pubkey : string option) : int64 =
  let dbh = Db.raw c in
  let r = match pubkey with
    | Some pubkey -> [%pgsql dbh "select count(1) from media_uploads where sha256 = $sha256 and pubkey = $pubkey"]
    | None -> [%pgsql dbh "select count(1) from media_uploads where sha256 = $sha256"]
  in
  match r with Some n :: _ -> n | _ -> 0L

let media_uploads_paths (c : Db.membership Db.conn) ~sha256 ~(pubkey : string option) : string list =
  let dbh = Db.raw c in
  match pubkey with
  | Some pubkey -> [%pgsql dbh "select path from media_uploads where sha256 = $sha256 and pubkey = $pubkey group by path"]
  | None -> [%pgsql dbh "select path from media_uploads where sha256 = $sha256"]

let short_urls_by_path_ext (c : Db.membership Db.conn) ~(path : string) ~(ext : string) : string list =
  let dbh = Db.raw c in
  [%pgsql dbh "select url from short_urls where path = $path and ext = $ext"]

let short_urls_set_block (c : Db.membership Db.conn) ~(path : string) ~(ext : string) ~(block : string) : unit =
  let dbh = Db.raw c in
  ignore [%pgsql dbh "update short_urls set media_block_id = $block::uuid where path = $path and ext = $ext"]

(* {1 Phase 5c: Blossom} *)

type upload = { up_mimetype : string; up_created_at : int64; up_path : string; up_size : int64; up_sha256 : string option; up_pubkey : string }

let blossom_uploads_by_pubkey (c : Db.membership Db.conn) ~pubkey : upload list =
  let dbh = Db.raw c in
  [%pgsql dbh "select mimetype, created_at, path, size, sha256 from media_uploads where pubkey = $pubkey"]
  |> List.map (fun (up_mimetype, up_created_at, up_path, up_size, up_sha256) -> { up_mimetype; up_created_at; up_path; up_size; up_sha256; up_pubkey = pubkey })

