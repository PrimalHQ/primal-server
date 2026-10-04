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
