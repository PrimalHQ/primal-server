(* Push notifications (device delivery: APNS / FCM / web-push), mirroring the Julia server.

   In the Julia codebase this is only scaffolding: notification() invokes
   Main.PushNotifications.notification(est, notif) ONLY when PUSH_NOTIFICATIONS_ENABLED[] is set
   (cache_storage_ext.jl:607,726-733), and that flag is hardcoded off — the PushNotifications
   module itself is a stub with no APNS/FCM/web-push backend. The only other push-related code is
   the App-layer token-registration endpoints (app.jl:4225-4246), which upsert into a membership
   notification_tokens table that does not exist on this deployment.

   We reproduce that surface faithfully but keep it disabled at runtime: [enabled] defaults to
   false, [notification] is a no-op device-push hook called from Cache_storage_ext.notification,
   and the token-registration helpers parse/verify their input but do not persist (the table is
   absent and delivery is off). Flip [enabled] only once a real backend is implemented. *)

module CS = Cache_storage
module N = Nostr

(* Julia PUSH_NOTIFICATIONS_ENABLED (cache_storage_ext.jl:607). *)
let enabled = ref false

(* Device-push entry point, mirroring the gated Main.eval(:(PushNotifications.notification)) call
   in notification() (cache_storage_ext.jl:726-733). Called once per in-DB notification when
   [enabled]; a stub today (no delivery backend to port). The arguments match the notification
   tuple stored in pubkey_notifications. *)
let notification (_est : CS.est) ~(recipient : string) ~(created_at : int) ~(ntype : int)
    ~(args : CS.notif_arg list) : unit =
  ignore (recipient, created_at, ntype, args);
  ()

(* App.parse_event_from_user_for_push_notification_token (app.jl:4225): parse a wrapped
   event-from-user, reject if it is from the future, verify its signature, and pull the device
   token out of its JSON content. *)
let parse_token_event (event_from_user : Yojson.Safe.t) : (N.t * string) option =
  match N.of_json event_from_user with
  | exception _ -> None
  | e ->
      if e.N.created_at >= Utils.current_time () + 300 then None (* "event from the future" *)
      else if not (N.verify e) then None
      else (
        match Yojson.Safe.from_string e.N.content with
        | exception _ -> None
        | json -> (
            match Yojson.Safe.Util.member "token" json with `String t -> Some (e, t) | _ -> None))

(* App.update_push_notification_token (app.jl:4233): in the Julia server this upserts the parsed
   tokens into membership.notification_tokens. That table is absent on this deployment and push
   delivery is disabled, so persistence is a documented no-op; we still parse and validate. *)
let update_push_notification_token ~(events_from_users : Yojson.Safe.t list) ~(platform : string)
    ~(token : string) : (N.t * string) list =
  let platform = String.lowercase_ascii platform in
  let tokens = List.filter_map parse_token_event events_from_users in
  List.iter (fun (_e, t) -> if t <> token then failwith "update_push_notification_token: token mismatch") tokens;
  ignore platform;
  (* TODO: persist to membership.notification_tokens once push delivery is implemented. *)
  tokens
