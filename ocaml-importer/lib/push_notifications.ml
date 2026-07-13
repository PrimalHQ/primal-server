(* Push notifications (device delivery via APNS / FCM), a port of the Julia PushNotifications
   module (primal-net-server/src/push_notifications.jl).

   Architecture, mirroring Julia:

   - Delivery goes through an external sender subprocess (the Rust push-notification-sender
     binary, config [push_notification_sender_bin]) speaking JSON lines over stdin/stdout: we
     write {"type":"push_notifications","platform":P,"notifications":[...]} requests and read one
     JSON response line per request (see push-notification-sender/README.md).

   - [notification] (called from Cache_storage_ext.notification for every stored, non-blocked
     notification when [enabled]) runs in a worker domain: it applies the per-user
     pushNotifications settings, renders title/body/link (pubkey display names from kind-0
     metadata, event summaries, media images) and resolves the receiver's device tokens
     (membership notification_tokens), then pushes one payload per token onto a cross-domain
     buffer. All DB access uses the worker's own connections (est).

   - [run] (a main-domain fiber, started only when enabled) owns the subprocess: every [period]
     seconds it drains the buffer, batches by 50 and groups by platform (Julia transmission),
     sends each request and reads its response with a timeout, logs both directions to
     t_push_notifications_log, and publishes send metrics to the pushgateway (under its own
     "<job>-push" label — a pushgateway POST replaces the job's whole metric group, so sharing
     the importer job would clobber the cache_any metrics).

   - Watchdog: instead of Julia's blind restart-if-nothing-sent-for-180s monitor, [run] sends the
     sender's {"type":"ping"} request when the pipeline has been idle for [ping_interval]; a
     failed/timed-out ping (or any request I/O error) kills and respawns the subprocess. An
     in-flight batch is dropped on restart (as in Julia, where the drained batch is lost when
     transmission dies).

   Not ported (per scope decision): the TCP intake server (Julia PORT=20000) and the
   "wallet-transaction" notification type it carries — the wallet server keeps talking to the
   Julia cache server. *)

open Eio.Std
module CS = Cache_storage
module N = Nostr
module Notif = Notifications

(* Julia PUSH_NOTIFICATIONS_ENABLED (cache_storage_ext.jl:607); set from the config file. *)
let enabled = ref false

(* Julia LOG: dump each subprocess request/response JSON to stdout. *)
let log_requests = ref false

(* {1 Cross-domain notification buffer} (Julia [notifications] ThreadSafe list).
   Entries are complete per-token sender payloads plus their platform (used for grouping). *)

type pending = { platform : string; payload : Yojson.Safe.t }

let buf_mutex = Mutex.create ()
let buf : pending list ref = ref []

let enqueue (p : pending) : unit =
  Mutex.lock buf_mutex;
  buf := p :: !buf;
  Mutex.unlock buf_mutex

(* Drain the buffer in arrival order. *)
let drain () : pending list =
  Mutex.lock buf_mutex;
  let ns = List.rev !buf in
  buf := [];
  Mutex.unlock buf_mutex;
  ns

(* {1 Small helpers} *)

let hex = Hex_util.encode
let hexp s = Some (hex s)

(* Julia fmtsats: thousands separators ("12345" -> "12,345"). *)
let fmtsats (sats : int) : string =
  let s = string_of_int sats in
  let n = String.length s in
  let b = Buffer.create (n + (n / 3)) in
  String.iteri
    (fun i c ->
      if i > 0 && (n - i) mod 3 = 0 && c <> '-' && s.[0] <> '-' then Buffer.add_char b ',';
      Buffer.add_char b c)
    s;
  Buffer.contents b

(* insert into t_push_notifications_log (Julia logs both the incoming notification and each
   subprocess round-trip there). Failures are reported via the return value so callers with a
   reconnectable handle can react; they must never block delivery. *)
let log_row (dbh : Postgres.dbh) (tag : string) (d : Yojson.Safe.t) : unit =
  ignore
    (Postgres.query dbh "insert into t_push_notifications_log values (now(), $1, $2::jsonb)"
       [ Some tag; Some (Yojson.Safe.to_string d) ])

let log_row_opt (dbh : Postgres.dbh) (tag : string) (d : Yojson.Safe.t) : unit =
  try log_row dbh tag d with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> ()

let notif_arg_json : CS.notif_arg -> Yojson.Safe.t = function
  | CS.Aeid s | CS.Apk s -> `String (hex s)
  | CS.Aint n -> `Int n
  | CS.Astr s -> `String s

(* {1 Per-user pushNotifications settings}

   Julia: settings = App.ext_user_get_settings(est, pubkey); pnsettings = settings["pushNotifications"].
   ext_user_get_settings deep-merges the user's app_settings event content over the server's
   default-settings.json, whose pushNotifications defaults are all true. Same query shape as
   Cache_storage_ext.app_setting_flag, just under the 'pushNotifications' key with default true. *)
let push_setting_enabled (est : CS.est) (pubkey : string) ~(key : string) : bool =
  match
    Postgres.query est.CS.mem_dbh
      "select coalesce(((value::jsonb->>'content')::jsonb->'pushNotifications'->$2::text)::bool, \
       true) from app_settings where key = decode($1,'hex') limit 1"
      [ hexp pubkey; Some key ]
  with
  | (Some v :: _) :: _ -> v = "t"
  | _ -> true (* no app_settings row: the default (true), like Julia's default-settings merge *)

(* {1 Pubkey display metadata} (Julia InternalServices.mdpubkey / mdtitle) *)

(* first non-empty of displayName / display_name / name / username, trimmed *)
let mdtitle (c : (string * Yojson.Safe.t) list) : string =
  let get k = match List.assoc_opt k c with Some (`String s) -> Some (String.trim s) | _ -> None in
  match
    List.filter_map get [ "displayName"; "display_name"; "name"; "username" ]
    |> List.find_opt (fun s -> s <> "")
  with
  | Some t -> t
  | None -> ""

(* Julia mdpubkey: blocked pubkeys (membership filterlist, any blocked row) get empty
   title/image, which makes the caller drop the push; otherwise title/image come from the kind-0
   metadata event, with the image upgraded to a cached media variant when available. *)
let mdpubkey (est : CS.est) (pk : string) : string * string =
  let blocked =
    match
      Postgres.query est.CS.mem_dbh
        "select 1 from filterlist where target_type = 'pubkey' and target = decode($1,'hex') and blocked limit 1"
        [ hexp pk ]
    with
    | [] -> false
    | _ -> true
  in
  if blocked then ("", "")
  else
    let title, image =
      match CS.get_meta_data_event est pk with
      | None -> ("", "")
      | Some me -> (
          match Yojson.Safe.from_string me.N.content with
          | exception _ -> ("", "")
          | `Assoc c ->
              let image = match List.assoc_opt "picture" c with Some (`String s) -> s | _ -> "" in
              (mdtitle c, image)
          | _ -> ("", ""))
    in
    let image =
      if image = "" then image
      else
        match
          Postgres.query est.CS.dbh
            "select media_url from media where url = $1 order by (width*height) limit 1"
            [ Some image ]
        with
        | (Some media_url :: _) :: _ -> media_url
        | _ -> image
    in
    (title, image)

(* {1 Event summary} (Julia event_summary -> get_meta_elements("/e/..").description ->
   content_refs_resolved with re_url stripped, newlines to spaces)

   The content scanner resolves inline references and strips URLs in one pass:
   - "#[i]"           -> "@<name>" when tag i is a p-tag with resolvable metadata, else ""
   - "nostr:npub..."/"nostr:nprofile..." (also bare npub1/nprofile1) -> "@<name>", else ""
   - http(s)://...    -> "" (Julia re_url strip)
   For long-form events (kind 30023) the title tag wins. *)

let is_bech32_char c = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')

let resolve_pk_name (est : CS.est) (pk : string) : string option =
  match mdpubkey est pk with "", _ -> None | t, _ -> Some ("@" ^ t)

let content_summary (est : CS.est) (e : N.t) : string =
  let s = e.N.content in
  let n = String.length s in
  let b = Buffer.create n in
  let starts_with i p =
    let lp = String.length p in
    i + lp <= n && String.sub s i lp = p
  in
  let is_space c = c = ' ' || c = '\t' || c = '\n' || c = '\r' in
  let i = ref 0 in
  while !i < n do
    if starts_with !i "http://" || starts_with !i "https://" then
      (* strip the URL (Julia re_url replacement) *)
      while !i < n && not (is_space s.[!i]) do
        incr i
      done
    else if starts_with !i "#[" then begin
      (* Julia re_hashref: "#[i]" -> "@name" via the i-th tag *)
      let j = ref (!i + 2) in
      while !j < n && s.[!j] >= '0' && s.[!j] <= '9' do
        incr j
      done;
      if !j > !i + 2 && !j < n && s.[!j] = ']' then begin
        (match int_of_string_opt (String.sub s (!i + 2) (!j - !i - 2)) with
        | Some idx -> (
            match List.nth_opt e.N.tags idx with
            | Some tg -> (
                match (N.tag_name tg, N.tag_field tg 1) with
                | Some "p", Some h -> (
                    match Option.bind (CS.decode32 h) (resolve_pk_name est) with
                    | Some nm -> Buffer.add_string b nm
                    | None -> ())
                | _ -> ())
            | None -> ())
        | None -> ());
        i := !j + 1
      end
      else begin
        Buffer.add_char b s.[!i];
        incr i
      end
    end
    else if starts_with !i "nostr:" || starts_with !i "npub1" || starts_with !i "nprofile1" then begin
      let start = if starts_with !i "nostr:" then !i + 6 else !i in
      let j = ref start in
      while !j < n && is_bech32_char s.[!j] do
        incr j
      done;
      let tok = String.sub s start (!j - start) in
      (match Bech32.nip19_decode tok with
      | Some (Bech32.Npub pk) | Some (Bech32.Nprofile pk) -> (
          match resolve_pk_name est pk with Some nm -> Buffer.add_string b nm | None -> ())
      | _ -> () (* nevent/note/naddr and undecodable refs are dropped, like Julia *));
      i := !j
    end
    else begin
      Buffer.add_char b (if s.[!i] = '\n' then ' ' else s.[!i]);
      incr i
    end
  done;
  Buffer.contents b

let event_summary (est : CS.est) (eid : string) : string =
  match CS.get_event est eid with
  | None -> ""
  | Some e ->
      if e.N.kind = N.kind_long_form_content then (
        match
          List.find_map
            (fun tg ->
              match (N.tag_name tg, N.tag_field tg 1) with Some "title", Some t -> Some t | _ -> None)
            e.N.tags
        with
        | Some t -> t
        | None -> content_summary est e)
      else content_summary est e

(* {1 Content image} (Julia get_content_image): the first URL in the event's content that has a
   video thumbnail or an animated cached media variant. *)

let urls_in_content (e : N.t) : string list =
  let s = e.N.content in
  let n = String.length s in
  let is_space c = c = ' ' || c = '\t' || c = '\n' || c = '\r' in
  let starts_with i p =
    let lp = String.length p in
    i + lp <= n && String.sub s i lp = p
  in
  let acc = ref [] in
  let i = ref 0 in
  while !i < n do
    if starts_with !i "http://" || starts_with !i "https://" then begin
      let j = ref !i in
      while !j < n && not (is_space s.[!j]) do
        incr j
      done;
      acc := String.sub s !i (!j - !i) :: !acc;
      i := !j
    end
    else incr i
  done;
  List.rev !acc

let get_content_image (est : CS.est) (eid : string) : string option =
  match CS.get_event est eid with
  | None -> None
  | Some e ->
      List.find_map
        (fun url ->
          match
            Postgres.query est.CS.dbh
              "select thumbnail_url from video_thumbnails where video_url = $1 limit 1" [ Some url ]
          with
          | (Some thumb :: _) :: _ -> Some thumb
          | _ -> (
              (* Julia: `for r in ... limit 2; res = r.media_url` — the LAST of up to two rows. *)
              match
                List.rev
                  (Postgres.query est.CS.dbh
                     "select media_url from media where url = $1 and animated = 1 order by (width*height) limit 2"
                     [ Some url ])
              with
              | (Some media_url :: _) :: _ -> Some media_url
              | _ -> None))
        (urls_in_content e)

(* {1 Notification rendering} *)

(* Julia liked-reaction heart set ("🤙+❤️🧡💛💚💙💜🤎🖤🤍💖💗💓💞💕💝💟❣️💌💘💑") as the set of its
   codepoints; a single-codepoint reaction in this set renders as "Liked by X". *)
let like_codepoints =
  let s =
    "\xf0\x9f\xa4\x99+\xe2\x9d\xa4\xef\xb8\x8f\xf0\x9f\xa7\xa1\xf0\x9f\x92\x9b\xf0\x9f\x92\x9a\xf0\x9f\x92\x99\xf0\x9f\x92\x9c\xf0\x9f\xa4\x8e\xf0\x9f\x96\xa4\xf0\x9f\xa4\x8d\xf0\x9f\x92\x96\xf0\x9f\x92\x97\xf0\x9f\x92\x93\xf0\x9f\x92\x9e\xf0\x9f\x92\x95\xf0\x9f\x92\x9d\xf0\x9f\x92\x9f\xe2\x9d\xa3\xef\xb8\x8f\xf0\x9f\x92\x8c\xf0\x9f\x92\x98\xf0\x9f\x92\x91"
  in
  let acc = ref [] in
  let i = ref 0 in
  while !i < String.length s do
    let d = String.get_utf_8_uchar s !i in
    acc := Uchar.to_int (Uchar.utf_decode_uchar d) :: !acc;
    i := !i + Uchar.utf_decode_length d
  done;
  !acc

(* Julia: length(reaction) == 1 && reaction[1] in <set> — exactly one codepoint, in the set. *)
let is_like_reaction (reaction : string) : bool =
  String.length reaction > 0
  &&
  let d = String.get_utf_8_uchar reaction 0 in
  Uchar.utf_decode_length d = String.length reaction
  && List.mem (Uchar.to_int (Uchar.utf_decode_uchar d)) like_codepoints

type rendered = {
  title : string;
  body : string;
  link : string;
  initiator : string; (* raw pk *)
  initiator_name : string;
  initiator_image : string;
  event_id : string option; (* for conversation_id / content_image *)
}

(* Build the per-type push content (the big if/elseif chain in Julia PushNotifications.notification).
   Returns None when the type has no push rendering or the user's pushNotifications settings turn
   it off. Arg positions follow Cache_storage_ext.notifications_cb / import_reply_notifications /
   Cache_storage.import_contact_list. *)
let render (est : CS.est) ~(recipient : string) ~(ntype : int) ~(args : CS.notif_arg list) :
    rendered option =
  let arr = Array.of_list args in
  let pk i = if i < Array.length arr then (match arr.(i) with CS.Apk p -> Some p | _ -> None) else None in
  let eid i = if i < Array.length arr then (match arr.(i) with CS.Aeid e -> Some e | _ -> None) else None in
  let int_ i = if i < Array.length arr then (match arr.(i) with CS.Aint v -> Some v | _ -> None) else None in
  let str i = if i < Array.length arr then (match arr.(i) with CS.Astr s -> Some s | _ -> None) else None in
  let setting key = push_setting_enabled est recipient ~key in
  let evs e = event_summary est e in
  let epage e = "https://primal.net/e/" ^ Bech32.encode_note e in
  let ppage p = "https://primal.net/p/" ^ Bech32.encode_npub p in
  let make ?event_id initiator ~title ~body ~link =
    let initiator_name, initiator_image = mdpubkey est initiator in
    Some { title = title initiator_name; body; link; initiator; initiator_name; initiator_image; event_id }
  in
  let n = ntype in
  if n = Notif.new_user_followed_you && setting "NEW_FOLLOWS" then
    match pk 0 with
    | Some follower -> make follower ~title:(fun nm -> "Followed by " ^ nm) ~body:"" ~link:(ppage follower)
    | None -> None
  else if n = Notif.user_unfollowed_you && setting "NEW_FOLLOWS" then
    match pk 0 with
    | Some follower -> make follower ~title:(fun nm -> "Unfollowed by " ^ nm) ~body:"" ~link:(ppage follower)
    | None -> None
  else if n = Notif.your_post_was_zapped && setting "ZAPS" then
    match (eid 0, pk 1) with
    | Some your_post, Some who ->
        let sats = Option.value (int_ 2) ~default:0 and msg = Option.value (str 3) ~default:"" in
        make who ~event_id:your_post
          ~title:(fun nm -> "Zapped by " ^ nm)
          ~body:(Printf.sprintf "%s sats: %s\n%s" (fmtsats sats) msg (evs your_post))
          ~link:(epage your_post)
    | _ -> None
  else if n = Notif.your_post_was_liked && setting "REACTIONS" then
    match (eid 0, pk 1) with
    | Some your_post, Some who ->
        let reaction = Option.value (str 2) ~default:"" in
        let title nm =
          if is_like_reaction reaction then "Liked by " ^ nm else nm ^ " reacted with " ^ reaction
        in
        make who ~event_id:your_post ~title ~body:(evs your_post) ~link:(epage your_post)
    | _ -> None
  else if n = Notif.your_post_was_reposted && setting "REPOSTS" then
    match (eid 0, pk 1) with
    | Some your_post, Some who ->
        make who ~event_id:your_post
          ~title:(fun nm -> "Reposted by " ^ nm)
          ~body:(evs your_post) ~link:(epage your_post)
    | _ -> None
  else if n = Notif.your_post_was_replied_to && setting "REPLIES" then
    match (pk 1, eid 2) with
    | Some who, Some reply ->
        make who ~event_id:reply ~title:(fun nm -> "Reply by " ^ nm) ~body:(evs reply) ~link:(epage reply)
    | _ -> None
  else if n = Notif.you_were_mentioned_in_post && setting "MENTIONS" then
    match (eid 0, pk 1) with
    | Some their_post, Some who ->
        make who ~event_id:their_post
          ~title:(fun nm -> nm ^ " mentioned you")
          ~body:(evs their_post) ~link:(epage their_post)
    | _ -> None
  else if n = Notif.your_post_was_mentioned_in_post && setting "MENTIONS" then
    match (eid 0, eid 1, pk 2) with
    | Some your_post, Some their_post, Some who ->
        make who ~event_id:their_post
          ~title:(fun nm -> nm ^ " quoted you")
          ~body:(Printf.sprintf "quoted note: \"%s\"" (evs your_post))
          ~link:(epage their_post)
    | _ -> None
  else if n = Notif.your_post_was_highlighted && setting "REACTIONS" then
    match (eid 0, pk 1, eid 2) with
    | Some your_post, Some who, Some highlight ->
        let body = match CS.get_event est highlight with Some e -> e.N.content | None -> "" in
        make who ~event_id:your_post ~title:(fun nm -> "Highlighted by " ^ nm) ~body ~link:(epage your_post)
    | _ -> None
  else if n = Notif.your_post_was_bookmarked && setting "REACTIONS" then
    match (eid 0, pk 1) with
    | Some your_post, Some who ->
        make who ~event_id:your_post
          ~title:(fun nm -> "Bookmarked by " ^ nm)
          ~body:(evs your_post) ~link:(epage your_post)
    | _ -> None
  else if n = Notif.new_direct_message && setting "DIRECT_MESSAGES" then
    match pk 1 with
    | Some sender ->
        make sender
          ~title:(fun nm -> nm)
          ~body:"New direct message"
          ~link:("https://primal.net/dms/" ^ Bech32.encode_npub sender)
    | None -> None
  else if n = Notif.reply_to_reply && setting "REPLIES" then
    match (pk 1, eid 2) with
    | Some who, Some reply ->
        make who ~event_id:reply
          ~title:(fun nm -> "Reply by " ^ nm ^ " in your thread")
          ~body:(evs reply) ~link:(epage reply)
    | _ -> None
  else None

(* {1 The entry point called from Cache_storage_ext.notification} (Julia
   PushNotifications.notification(est, n) — importer-generated types only). *)

let notification (est : CS.est) ~(recipient : string) ~(created_at : int) ~(ntype : int)
    ~(args : CS.notif_arg list) : unit =
  (* Julia logs every incoming notification before any check. *)
  log_row_opt est.CS.dbh "notification"
    (`Assoc
      [
        ("t", `Int (Utils.current_time ()));
        ( "n",
          `Assoc
            [
              ("pubkey", `String (hex recipient));
              ("created_at", `Int created_at);
              ("type", `Int ntype);
              ("type_name", `String (Notif.name ntype));
              ("args", `List (List.map notif_arg_json args));
            ] );
      ]);
  if Utils.current_time () - created_at > 30 * 60 then () (* Julia: "too old" *)
  else
    match render est ~recipient ~ntype ~args with
    | None -> ()
    | Some r ->
        (* Julia: notifications with an unresolvable initiator name are dropped. *)
        if r.title = "" || r.initiator_name = "" then ()
        else begin
          (* conversation_id from the root e-tag of the referenced event. (Julia builds
             "<user_pubkey>.<root eid>" but references an undefined user_pubkey inside its
             try/catch, so it always ends up nothing; we implement the evident intent with the
             receiver's pubkey.) *)
          let conversation_id =
            Option.bind r.event_id (fun eid ->
                Option.bind (CS.get_event est eid) (fun e ->
                    List.find_map
                      (fun tg ->
                        if
                          N.tag_len tg >= 4
                          && N.tag_name tg = Some "e"
                          && N.tag_field tg 3 = Some "root"
                        then
                          Option.map
                            (fun root -> hex recipient ^ "." ^ hex root)
                            (Option.bind (N.tag_field tg 1) CS.decode32)
                        else None)
                      e.N.tags))
          in
          let content_image = Option.bind r.event_id (get_content_image est) in
          let user_displayname, _ = mdpubkey est recipient in
          let extra =
            [
              ("user_pubkey", `String (hex recipient));
              ("user_displayname", `String user_displayname);
              ("initiator_displayname", `String r.initiator_name);
              ("initiator_pubkey", `String (hex r.initiator));
            ]
            @ (if r.link <> "" then [ ("link", `String r.link) ] else [])
            @ (if r.initiator_image <> "" then [ ("initiator_image", `String r.initiator_image) ] else [])
            @ (match content_image with Some u -> [ ("content_image", `String u) ] | None -> [])
            @
            match conversation_id with Some c -> [ ("conversation_id", `String c) ] | None -> []
          in
          (* one payload per registered device token (Julia's notification_tokens self-join
             computes a shared-token pubkey count, but the multi-account title prefix that used
             it is commented out — the row set reduces to a plain group by). *)
          let rows =
            try
              Postgres.query est.CS.mem_dbh
                "select platform, token, environment from notification_tokens \
                 where pubkey = decode($1,'hex') group by platform, token, environment"
                [ hexp recipient ]
            with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | _ -> []
          in
          List.iter
            (function
              | [ Some platform; Some token; Some environment ] ->
                  let payload =
                    `Assoc
                      [
                        ("platform", `String platform);
                        ("token", `String token);
                        ("environment", `String environment);
                        ("title", `String r.title);
                        ("body", `String r.body);
                        ("data", `Assoc [ ("extra", `Assoc extra) ]);
                      ]
                  in
                  enqueue { platform; payload }
              | _ -> ())
            rows
        end

(* {1 Sender subprocess + transmission fiber} *)

exception Restart of string

(* Split [l] into chunks of at most [k] (Julia Iterators.partition(ns, 50)). *)
let chunks (k : int) (l : 'a list) : 'a list list =
  let rec take i acc rest =
    if i = 0 then (List.rev acc, rest)
    else match rest with [] -> (List.rev acc, []) | x :: tl -> take (i - 1) (x :: acc) tl
  in
  let rec loop l = if l = [] then [] else let c, rest = take k [] l in c :: loop rest in
  loop l

(* Group a batch by platform, preserving arrival order within each group (Julia nsplat). *)
let by_platform (ns : pending list) : (string * Yojson.Safe.t list) list =
  List.fold_left
    (fun acc p ->
      match List.assoc_opt p.platform acc with
      | Some l -> (p.platform, l @ [ p.payload ]) :: List.remove_assoc p.platform acc
      | None -> acc @ [ (p.platform, [ p.payload ]) ])
    [] ns

(* Count delivered notifications out of a sender response (Julia monitor_subprocess_operation:
   ios counts resp.results[1], android counts resp.results). *)
let count_sent (platform : string) (resp : Yojson.Safe.t) : int =
  try
    match Yojson.Safe.Util.member "results" resp with
    | `List results ->
        if platform = "ios" then match results with `List l :: _ -> List.length l | _ -> 0
        else List.length results
    | _ -> 0
  with _ -> 0

let run ~proc_mgr ~net ~clock ~(stats : Stats.t) ~(cache_db : Postgres.conninfo)
    ~(sender_bin : string) ~(period : float) ?(ping_interval = 60.0) ?(request_timeout = 10.0)
    ?pushgateway (* (host, port, job): push_notification_* metrics, published as job "<job>-push" *)
    () : unit =
  (* This fiber's own cache-DB connection, for t_push_notifications_log rows. *)
  let log_dbh = ref (Postgres.connect cache_db) in
  let log_result d =
    try log_row !log_dbh "notification_result" d with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
        if Postgres.is_connection_error exn then (
          (try Postgres.close !log_dbh with _ -> ());
          try
            log_dbh := Postgres.connect cache_db;
            log_row_opt !log_dbh "notification_result" d
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | _ -> ())
  in
  (* Julia monitor_subprocess_operation metrics, throttled to one POST per 15s. *)
  let sent_ctr = ref 0 in
  let t_metrics = ref (Unix.gettimeofday ()) in
  let publish_metrics () =
    match pushgateway with
    | None -> ()
    | Some (host, port, job) ->
        let now = Unix.gettimeofday () in
        if now -. !t_metrics >= 15.0 then begin
          (try
             Pushgateway.set_many ~net ~clock ~host ~port ~job:(job ^ "-push")
               [
                 ("push_notification_latest", "gauge", Utils.current_time ());
                 ("push_notification_sent", "gauge", !sent_ctr);
               ]
           with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn -> Printf.eprintf "push_notifications: pushgateway: %s\n%!" (Printexc.to_string exn));
          sent_ctr := 0;
          t_metrics := now
        end
  in
  (* One subprocess session; raises Restart on any request I/O problem so the outer loop
     respawns (the switch release kills the child). *)
  let session () =
    Switch.run @@ fun sw ->
    let child_out_r, child_out_w = Eio_unix.pipe sw in
    let child_in_r, child_in_w = Eio_unix.pipe sw in
    let _proc = Eio.Process.spawn ~sw proc_mgr ~stdin:child_in_r ~stdout:child_out_w [ sender_bin ] in
    (* Drop the parent's copies of the child's pipe ends so EOF propagates. *)
    Eio.Flow.close child_in_r;
    Eio.Flow.close child_out_w;
    let br = Eio.Buf_read.of_flow ~max_size:(16 * 1024 * 1024) child_out_r in
    Printf.printf "push_notifications: sender started (%s)\n%!" sender_bin;
    let request (req : Yojson.Safe.t) : Yojson.Safe.t =
      let line = Yojson.Safe.to_string req in
      if !log_requests then Printf.printf "push_notifications: > %s\n%!" line;
      match
        try
          Eio.Flow.copy_string (line ^ "\n") child_in_w;
          `Resp
            (Eio.Time.with_timeout_exn clock request_timeout (fun () -> Eio.Buf_read.line br)
            |> Yojson.Safe.from_string)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn -> `Err (Printexc.to_string exn)
      with
      | `Resp resp ->
          if !log_requests then
            Printf.printf "push_notifications: < %s\n%!" (Yojson.Safe.to_string resp);
          resp
      | `Err msg -> raise (Restart msg)
    in
    let t_last_op = ref (Unix.gettimeofday ()) in
    while true do
      Eio.Time.sleep clock period;
      let ns = drain () in
      if ns <> [] then
        List.iter
          (fun chunk ->
            List.iter
              (fun (platform, payloads) ->
                let req =
                  `Assoc
                    [
                      ("type", `String "push_notifications");
                      ("platform", `String platform);
                      ("notifications", `List payloads);
                    ]
                in
                let resp = request req in
                t_last_op := Unix.gettimeofday ();
                let sent = count_sent platform resp in
                sent_ctr := !sent_ctr + sent;
                Stats.push_sent stats sent;
                log_result
                  (`Assoc [ ("t", `Int (Utils.current_time ())); ("req", req); ("resp", resp) ]);
                publish_metrics ())
              (by_platform chunk))
          (chunks 50 ns)
      else if Unix.gettimeofday () -. !t_last_op >= ping_interval then begin
        (* idle watchdog: a ping round-trip proves the sender is alive; a failure Restarts. *)
        ignore (request (`Assoc [ ("type", `String "ping") ]));
        t_last_op := Unix.gettimeofday ()
      end
    done
  in
  let rec loop () =
    (try session () with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | Restart msg -> Printf.eprintf "push_notifications: sender restart: %s\n%!" msg
    | exn -> Printf.eprintf "push_notifications: sender restart: %s\n%!" (Printexc.to_string exn));
    Eio.Time.sleep clock 1.0;
    loop ()
  in
  loop ()

(* {1 Token registration} (App-layer helpers; registration itself stays with the Julia app
   server, which upserts into membership.notification_tokens — the table this module reads). *)

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

(* App.update_push_notification_token (app.jl:4233). *)
let update_push_notification_token ~(events_from_users : Yojson.Safe.t list) ~(platform : string)
    ~(token : string) : (N.t * string) list =
  let platform = String.lowercase_ascii platform in
  let tokens = List.filter_map parse_token_event events_from_users in
  List.iter
    (fun (_e, t) -> if t <> token then failwith "update_push_notification_token: token mismatch")
    tokens;
  ignore platform;
  tokens
