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
