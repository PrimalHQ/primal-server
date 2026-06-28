(* ext_* hooks, mirroring Julia src/cache_storage_ext.jl.

   These are the "extension" callbacks the core import path (cache_storage.ml) invokes through
   its [ext] registry: pubkey_zapped seeding, zap receipts, event scoring, hashtag indexing,
   and the content-hash spam guard. They are registered with [Cache_storage.set_ext] by
   [register ()] (called once at startup, from bin/main.ml).

   Out of scope for the staging importer (matching the Julia importer's effective behaviour):
   - media import (Julia gates every download on DOWNLOAD_MEDIA, off in the importer) — the
     import_note_urls / image-tag paths are no-ops here;
   - notifications (notifications_cb / pubkey_notifications / NotificationType) — a large
     separate subsystem (notifications.jl); the score_event_cb and event_stats_cb hooks that
     also feed event_stats ARE implemented;
   - user_search FTS indexing (update_user_search) — a separate tsvector subsystem.
   Each is marked with a TODO where it would otherwise sit. *)

module CS = Cache_storage
module PGOCaml = Postgres.PGOCaml
module Notif = Notifications
open Pg_types (* filterlist enum constructors (Spam / Impersonation / Pubkey / Event) *)

let i64 = Int64.of_int
let current_time = Utils.current_time

(* {1 trust / hidden predicates} (Julia ext_is_human / ext_is_hidden) *)

(* Julia ext_is_human's default threshold is TrustRank.humaness_threshold[], a global Ref that is
   initialised to 0.0 (trust_rank.jl:10) and recomputed by TrustRank.load as the rank of the
   50,000th-highest-ranked pubkey in pubkey_trustrank (trust_rank.jl:20:
   first(sorted, 50000)[end][2]). load runs only in the separate TrustRankMaker process, but the
   value it derives comes from the same shared pubkey_trustrank table — so we reproduce that
   cutoff here directly from the table at startup (load_humaness_threshold) rather than leave it
   pinned at 0.0. IMPORTER_HUMANESS_THRESHOLD, when set, is an explicit override that wins over
   the computed value. *)
let env_threshold =
  match Sys.getenv_opt "IMPORTER_HUMANESS_THRESHOLD" with
  | Some v -> ( try Some (float_of_string v) with _ -> None)
  | None -> None

let humaness_threshold = ref (Option.value env_threshold ~default:0.0)

(* Mirror TrustRank.load: humaness_threshold = rank of the 50,000th-highest-ranked pubkey (or the
   lowest rank present, if fewer than 50,000 rows). min over the top-50000-by-rank window is
   exactly Julia's first(sorted, 50000)[end][2]. Skipped when IMPORTER_HUMANESS_THRESHOLD pins an
   explicit override; an empty table keeps 0.0. Call once at startup, before the worker domains
   read the value; returns the threshold now in force. *)
let load_humaness_threshold (est : CS.est) : float =
  (match env_threshold with
  | Some _ -> () (* explicit override already in the ref *)
  | None -> (
      let dbh = est.CS.dbh in
      match
        [%pgsql dbh
          "select min(rank) from (select rank from pubkey_trustrank order by rank desc limit \
           50000) t"]
      with
      | Some r :: _ -> humaness_threshold := r
      | _ -> () (* empty table: keep 0.0 *)));
  !humaness_threshold

(* Julia ext_is_human: a human_override (membership) wins; otherwise pubkey_trustrank.rank >
   threshold. *)
let ext_is_human ?threshold (est : CS.est) (pubkey : string) : bool =
  let threshold = match threshold with Some t -> t | None -> !humaness_threshold in
  let mdbh = est.CS.mem_dbh in
  match [%pgsql mdbh "select is_human from human_override where pubkey = $pubkey"] with
  | Some h :: _ -> h
  | _ -> (
      (* no override row, or is_human NULL (nullable in live) -> fall through to trustrank *)
      let dbh = est.CS.dbh in
      match
        [%pgsql dbh "select 1 from pubkey_trustrank where pubkey = $pubkey and rank > $threshold limit 1"]
      with
      | [] -> false
      | _ -> true)

(* Julia ext_is_hidden(eid/pubkey): read the filterlist (local cache DB). *)
let ext_is_hidden_event (est : CS.est) (id : string) : bool =
  Filterlist.is_event_blocked_spam est.CS.dbh id

let ext_is_hidden_pubkey (est : CS.est) (pk : string) : bool =
  Filterlist.is_pubkey_blocked_spam est.CS.dbh pk

(* {1 spam content hash} (Julia spam_content_sha256 / store_/check_spam_content_hash) *)

let spam_content_sha256 (content : string) : string =
  Digestif.SHA256.(to_raw_string (digest_string content))

(* Record the content hash of a confirmed-spam note (called from the spam detector's spamevent
   processor) so future identical notes can be flagged on note #1. *)
let store_spam_content_hash (est : CS.est) (e : Nostr.t) : unit =
  if e.kind = Nostr.kind_text_note then begin
    let dbh = est.CS.dbh in
    let content_sha256 = spam_content_sha256 e.content and added_at = i64 (current_time ()) in
    ignore
      [%pgsql dbh "insert into spam_note_content_hash (content_sha256, added_at) values ($content_sha256, $added_at) on conflict do nothing"]
  end

(* If a new note's content exactly matches a previously-confirmed spam note, flag its author as
   spam immediately. Guarded to low-follower, non-allowlisted accounts. Writes the filterlist
   row to the membership DB (source of truth). *)
let check_spam_content_hash (est : CS.est) (e : Nostr.t) : unit =
  if
    e.kind = Nostr.kind_text_note
    && (not (Filterlist.is_pubkey_unblocked est.CS.dbh e.pubkey))
    && CS.pubkey_followers_cnt est e.pubkey < 50
  then begin
    let dbh = est.CS.dbh in
    let h = spam_content_sha256 e.content in
    match [%pgsql dbh "select 1 from spam_note_content_hash where content_sha256 = $h limit 1"] with
    | [] -> ()
    | _ ->
        let comment =
          Printf.sprintf "spam-content-hash: sha256 of note %s matches known spam content"
            (Hex_util.encode e.id)
        in
        Filterlist.block_pubkey_spam ~mem_dbh:est.CS.mem_dbh e.pubkey ~comment
  end

(* {1 content scanning helpers} (Julia for_hashtags / for_mentiones) *)

let is_hashtag_char c =
  (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_' || c = '-'

(* Julia re_hashtag = (^|[^0-9a-zA-Z_-])#([0-9a-zA-Z_-]+), TEXT_NOTE only. *)
let for_hashtags (e : Nostr.t) (body : string -> unit) : unit =
  if e.kind = Nostr.kind_text_note then begin
    let s = e.content in
    let n = String.length s in
    let i = ref 0 in
    while !i < n do
      if s.[!i] = '#' && (!i = 0 || not (is_hashtag_char s.[!i - 1])) then begin
        let j = ref (!i + 1) in
        while !j < n && is_hashtag_char s.[!j] do
          incr j
        done;
        if !j > !i + 1 then body (String.sub s (!i + 1) (!j - !i - 1));
        i := !j
      end
      else incr i
    done
  end

(* Julia for_mentiones: collect the events/pubkeys a note mentions, yielding 2-field tags.
   We implement the tag-derived mentions — #[N] content refs into the tag list, and a/e tags
   carrying a 4th "mention" marker (a-tags resolved to their current event id). The bech32
   "nostr:" content mentions (re_mention / nip19_decode) are a TODO pending bech32.ml. *)
let for_mentiones (est : CS.est) (e : Nostr.t) (body : Nostr.tag -> unit) : unit =
  if
    e.kind = Nostr.kind_text_note
    || e.kind = Nostr.kind_long_form_content
    || e.kind = Nostr.kind_repost
  then begin
    let tags = Array.of_list e.tags in
    let acc = ref [] in
    let push name value = acc := [ `String name; `String value ] :: !acc in
    let push_tag (tg : Nostr.tag) =
      match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
      | Some name, Some value -> push name value
      | _ -> ()
    in
    (* hashref content references into the tag list, of the form hash-bracket-N-bracket;
       Julia indexes 1-based, we index 0-based. *)
    let content = e.content in
    let n0 = String.length content in
    let i = ref 0 in
    while !i < n0 do
      if !i + 1 < n0 && content.[!i] = '#' && content.[!i + 1] = '[' then begin
        let j = ref (!i + 2) in
        while !j < n0 && content.[!j] >= '0' && content.[!j] <= '9' do
          incr j
        done;
        if !j < n0 && content.[!j] = ']' && !j > !i + 2 then begin
          (match int_of_string_opt (String.sub content (!i + 2) (!j - !i - 2)) with
          | Some ref_idx when ref_idx >= 0 && ref_idx < Array.length tags ->
              let tg = tags.(ref_idx) in
              if Nostr.tag_len tg >= 2 then push_tag tg
          | _ -> ());
          i := !j + 1
        end
        else i := !j
      end
      else incr i
    done;
    (* a/e tags carrying a 4th "mention" marker *)
    List.iter
      (fun tg ->
        if Nostr.tag_len tg >= 4 && Nostr.tag_field tg 3 = Some "mention" then
          match Nostr.tag_name tg with
          | Some "e" -> push_tag tg
          | Some "a" -> (
              match Nostr.tag_field tg 1 with
              | Some s -> (
                  match CS.parse_a_tag s with
                  | Some (kind, pubkey, identifier) -> (
                      match CS.lookup_parametrized_replaceable_event est ~kind ~pubkey ~identifier with
                      | Some eid -> push "e" (Hex_util.encode eid)
                      | None -> ())
                  | None -> ())
              | None -> ())
          | _ -> ())
      e.tags;
    (* bech32 nip19 content mentions (Julia re_mention): npub/nprofile -> p, note/nevent -> e,
       naddr -> resolve the parametrized-replaceable event -> e. *)
    let is_b32 c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') in
    let prefixes = [ "npub1"; "note1"; "naddr1"; "nevent1"; "nprofile1" ] in
    let starts_with s p =
      String.length s >= String.length p && String.sub s 0 (String.length p) = p
    in
    let p = ref 0 in
    while !p < n0 do
      if is_b32 content.[!p] then begin
        let q = ref !p in
        while !q < n0 && is_b32 content.[!q] do incr q done;
        let tok = String.sub content !p (!q - !p) in
        (if List.exists (starts_with tok) prefixes then
           match Bech32.nip19_decode tok with
           | Some (Bech32.Npub pk) | Some (Bech32.Nprofile pk) -> push "p" (Hex_util.encode pk)
           | Some (Bech32.Note eid) | Some (Bech32.Nevent eid) -> push "e" (Hex_util.encode eid)
           | Some (Bech32.Naddr { kind; author; identifier }) -> (
               match CS.lookup_parametrized_replaceable_event est ~kind ~pubkey:author ~identifier with
               | Some eid -> push "e" (Hex_util.encode eid)
               | None -> ())
           | None -> ());
        p := !q
      end
      else incr p
    done;
    (* Julia unique() over the 2-field tags, preserving first occurrence. *)
    let seen = Hashtbl.create 16 in
    List.iter
      (fun tg ->
        let k = match tg with `String a :: `String b :: _ -> a ^ "\x00" ^ b | _ -> "" in
        if not (Hashtbl.mem seen k) then begin
          Hashtbl.add seen k ();
          body tg
        end)
      (List.rev !acc)
  end

(* Julia import_note_urls: media-URL extraction + download. Every branch is gated on
   DOWNLOAD_MEDIA, off in the importer, so this is a no-op. TODO: media import subsystem. *)
let import_note_urls (_est : CS.est) (_e : Nostr.t) : unit = ()

(* {1 zaps} (Julia import_zap_receipt / zap_receiver) *)

let zap_receiver (e : Nostr.t) : string option =
  List.find_map
    (fun tg ->
      match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
      | Some "p", Some h -> CS.decode32 h
      | _ -> None)
    e.tags

let import_zap_receipt (est : CS.est) (e : Nostr.t) (parent_eid : string) (amount_sats : int) : unit =
  let dbh = est.CS.dbh in
  let zap_receipt_id = e.id and created_at = i64 e.created_at in
  let sender = CS.zap_sender e and receiver = zap_receiver e in
  let amount = i64 amount_sats and event_id = Some parent_eid in
  ignore
    [%pgsql dbh
      "insert into og_zap_receipts_1_dc85307383 (zap_receipt_id, created_at, sender, receiver, amount_sats, event_id) \
       values ($zap_receipt_id, $created_at, $?sender, $?receiver, $amount, $?event_id)"]

(* {1 notifications} (Julia notification / notification_counter_update / notifications_cb /
   import_reply_notifications)

   notification() builds and stores one in-DB notification row (pubkey_notifications) and bumps the
   per-type counter (pubkey_notification_cnts). The deferred-firing path is the Notifications_cb
   event hook: when a post acquires a like/repost/zap/mention/highlight/bookmark, a hook is queued
   against the post; notifications_cb fires once the post is present and constructs the concrete
   notification() call. Reply/mention notifications fan out synchronously via
   import_reply_notifications. *)

(* The first two positional args of every NotificationType are an EventId/PubKeyId written to the
   bytea arg1/arg2 columns; the rest are JSON-encoded into the jsonb arg3/arg4 columns exactly as
   Julia's JSON.json would (EventId/PubKeyId -> hex string, Int -> number, String -> string). *)
let notif_arg_bytes = function CS.Aeid h -> Some h | CS.Apk p -> Some p | _ -> None

let notif_arg_json = function
  | CS.Aeid h -> Yojson.Safe.to_string (`String (Hex_util.encode h))
  | CS.Apk p -> Yojson.Safe.to_string (`String (Hex_util.encode p))
  | CS.Aint i -> string_of_int i
  | CS.Astr s -> Yojson.Safe.to_string (`String s)

(* Julia notification_counter_update (cache_storage_ext.jl:13): bump pubkey_notification_cnts.typeN
   for the recipient, but only when every PubKeyId involved (recipient + pubkey args) is a trusted
   user. The column name cannot be a bound parameter, so it is selected by a match. *)
let notification_counter_update (est : CS.est) (recipient : string) (ntype : int)
    (args : CS.notif_arg list) : unit =
  let pubkeys = recipient :: List.filter_map (function CS.Apk p -> Some p | _ -> None) args in
  if List.for_all (fun pk -> CS.is_trusted_user est pk) pubkeys then begin
    let dbh = est.CS.dbh in
    ignore
      [%pgsql dbh "insert into pubkey_notification_cnts_1_d78f6fcade (pubkey) values ($recipient) on conflict (pubkey) do nothing"];
    match ntype with
    | 1 -> ignore [%pgsql dbh "update pubkey_notification_cnts_1_d78f6fcade set type1 = type1 + 1 where pubkey = $recipient"]
    | 3 -> ignore [%pgsql dbh "update pubkey_notification_cnts_1_d78f6fcade set type3 = type3 + 1 where pubkey = $recipient"]
    | 4 -> ignore [%pgsql dbh "update pubkey_notification_cnts_1_d78f6fcade set type4 = type4 + 1 where pubkey = $recipient"]
    | 5 -> ignore [%pgsql dbh "update pubkey_notification_cnts_1_d78f6fcade set type5 = type5 + 1 where pubkey = $recipient"]
    | 6 -> ignore [%pgsql dbh "update pubkey_notification_cnts_1_d78f6fcade set type6 = type6 + 1 where pubkey = $recipient"]
    | 7 -> ignore [%pgsql dbh "update pubkey_notification_cnts_1_d78f6fcade set type7 = type7 + 1 where pubkey = $recipient"]
    | 8 -> ignore [%pgsql dbh "update pubkey_notification_cnts_1_d78f6fcade set type8 = type8 + 1 where pubkey = $recipient"]
    | 301 -> ignore [%pgsql dbh "update pubkey_notification_cnts_1_d78f6fcade set type301 = type301 + 1 where pubkey = $recipient"]
    | 302 -> ignore [%pgsql dbh "update pubkey_notification_cnts_1_d78f6fcade set type302 = type302 + 1 where pubkey = $recipient"]
    | 401 -> ignore [%pgsql dbh "update pubkey_notification_cnts_1_d78f6fcade set type401 = type401 + 1 where pubkey = $recipient"]
    | 601 -> ignore [%pgsql dbh "update pubkey_notification_cnts_1_d78f6fcade set type601 = type601 + 1 where pubkey = $recipient"]
    | n ->
        (* POST_*/LIVE_EVENT types aren't generated by the importer, so this is unreachable today;
           a new notification type without a column here would silently miscount, so make it loud. *)
        Printf.eprintf "notification_counter_update: unhandled notification type %d (counter not bumped)\n%!" n
  end

(* {1 serving-layer notification gates} (Julia notification() gates, cache_storage_ext.jl:616-742)

   These reproduce the gates that read the membership/app_settings tables. Those tables are absent
   from primal1 (the schema the [%pgsql] ppx checks against) but are always present in a real
   membership DB, so the queries here are RAW (Postgres.query, not [%pgsql]) and the WHOLE set is
   gated on app_settings being present in the membership connection (init_notification_gating). When
   it is absent (e.g. mem_dbh = primal1) the gates are inert and behaviour matches the pre-gating
   importer; point mem_dbh at a membership DB via the PGMEMBERSHIP env vars to activate them. *)

let app_settings_present = ref false

(* Detect once whether the membership connection has app_settings; call on the main domain before
   the worker domains spawn so they all observe the final value. Returns the value now in force. *)
let init_notification_gating (est : CS.est) : bool =
  let present =
    match Postgres.query est.CS.mem_dbh "select to_regclass('public.app_settings') is not null" [] with
    | (Some v :: _) :: _ -> v = "t"
    | _ -> false
  in
  app_settings_present := present;
  present

let hexp s = Some (Hex_util.encode s)

(* recipient is a Primal app user (Julia: pubkey in est.app_settings). *)
let is_app_user (est : CS.est) (pubkey : string) : bool =
  match
    Postgres.query est.CS.mem_dbh "select 1 from app_settings where key = decode($1,'hex') limit 1"
      [ hexp pubkey ]
  with
  | [] -> false
  | _ -> true

(* a boolean notificationsAdditional setting; true iff a row matches Julia's
   "... and coalesce((value->'content'->'notificationsAdditional'->KEY)::bool, DEFAULT)". Both the
   JSON key and the default are bound parameters ($2::text disambiguates jsonb->text from the array
   jsonb->int overload, $3::bool the coalesce default), so the SQL is a fixed literal — no
   interpolation. *)
let app_setting_flag (est : CS.est) (pubkey : string) ~(key : string) ~(default : bool) : bool =
  match
    Postgres.query est.CS.mem_dbh
      "select 1 from app_settings where key = decode($1,'hex') and \
       coalesce(((value::jsonb->>'content')::jsonb->'notificationsAdditional'->$2::text)::bool, \
       $3::bool) limit 1"
      [ hexp pubkey; Some key; Some (string_of_bool default) ]
  with
  | [] -> false
  | _ -> true

(* recipient follows initiator (Julia pubkey_followers: follower_pubkey = recipient, pubkey =
   initiator). Cache base table, [%pgsql]-checkable. *)
let is_follower (est : CS.est) ~(recipient : string) ~(initiator : string) : bool =
  let dbh = est.CS.dbh in
  match
    [%pgsql dbh "select 1 from pubkey_followers_1_d52305fb47 where follower_pubkey = $recipient and pubkey = $initiator limit 1"]
  with
  | [] -> false
  | _ -> true

(* Julia notification_blocked_sender_not_follower (cache_storage_ext.jl:760). *)
let blocked_sender_not_follower (est : CS.est) ~(recipient : string) ~(initiator : string option) : bool =
  if app_setting_flag est recipient ~key:"only_show_reactions_from_users_i_follow" ~default:false then
    match initiator with None -> true | Some i -> not (is_follower est ~recipient ~initiator:i)
  else false

(* Julia notification_additional_settings (cache_storage_ext.jl:673-715). *)
let gate_additional (est : CS.est) (recipient : string) (ntype : int) (arr : CS.notif_arg array) : bool =
  let pk i = if i < Array.length arr then (match arr.(i) with CS.Apk p -> Some p | _ -> None) else None in
  if ntype = Notif.new_direct_message then
    app_setting_flag est recipient ~key:"only_show_dm_notifications_from_users_i_follow" ~default:true
    && (match pk 1 with Some sender -> not (is_follower est ~recipient ~initiator:sender) | None -> false)
  else if ntype = Notif.reply_to_reply then
    not (app_setting_flag est recipient ~key:"include_deep_replies" ~default:true)
  else
    let initiator =
      if ntype = Notif.new_user_followed_you || ntype = Notif.user_unfollowed_you then pk 0
      else if ntype = Notif.your_post_was_mentioned_in_post then pk 2
      else pk 1 (* zapped / liked / reposted / replied_to / mentioned / highlighted / bookmarked *)
    in
    blocked_sender_not_follower est ~recipient ~initiator

(* Julia notification_settings gate (cache_storage_ext.jl:735): a row with enabled=false blocks. *)
let gate_notification_settings (est : CS.est) (recipient : string) (ntype : int) : bool =
  match
    Postgres.query est.CS.mem_dbh
      "select enabled from notification_settings where pubkey = decode($1,'hex') and type = $2 limit 1"
      [ hexp recipient; Some (Notif.name ntype) ]
  with
  | (Some v :: _) :: _ -> not (v = "t")
  | _ -> false

(* Julia hellthread block (cache_storage_ext.jl:641): for mention notifications whose referenced
   event mentions >10 pubkeys, block when the recipient keeps the (default-on) setting. *)
let gate_hellthread (est : CS.est) (recipient : string) (ntype : int) (arr : CS.notif_arg array) : bool =
  if
    ntype = Notif.you_were_mentioned_in_post
    || ntype = Notif.post_you_were_mentioned_in_was_zapped
    || ntype = Notif.post_you_were_mentioned_in_was_liked
    || ntype = Notif.post_you_were_mentioned_in_was_reposted
    || ntype = Notif.post_you_were_mentioned_in_was_replied_to
  then
    match (if Array.length arr > 0 then arr.(0) else CS.Aint 0) with
    | CS.Aeid eid -> (
        match CS.get_event est eid with
        | Some ev ->
            let mentions = ref 0 in
            for_mentiones est ev (fun tg -> if Nostr.tag_name tg = Some "p" then incr mentions);
            !mentions > 10
            && app_setting_flag est recipient ~key:"ignore_events_with_too_many_mentions" ~default:true
        | None -> false)
    | _ -> false
  else false

let str_contains (hay : string) (needle : string) : bool =
  let nl = String.length needle and hl = String.length hay in
  if nl = 0 then true
  else
    let rec go i = if i + nl > hl then false else if String.sub hay i nl = needle then true else go (i + 1) in
    go 0

(* Julia notification_blocked_by_mutelist (cache_storage_ext.jl:769): the recipient's mute list
   (kind 10000) can block by referenced event (e), pubkey (p), hashtag (t), or word. *)
let gate_mutelist (est : CS.est) (recipient : string) (arr : CS.notif_arg array) : bool =
  let dbh = est.CS.dbh in
  let mute_event =
    match [%pgsql dbh "select value from mute_list_1_f693a878b9 where key = $recipient"] with
    | mid :: _ -> CS.get_event est mid
    | [] -> None
  in
  match mute_event with
  | None -> false
  | Some mv ->
      let args = Array.to_list arr in
      let arg_pks = List.filter_map (function CS.Apk p -> Some p | _ -> None) args in
      let arg_eids = List.filter_map (function CS.Aeid e -> Some e | _ -> None) args in
      let first_eid = if Array.length arr > 0 then (match arr.(0) with CS.Aeid e -> Some e | _ -> None) else None in
      let referenced_event_with eid =
        match first_eid with
        | Some e -> ( match CS.get_event est e with Some ev -> eid ev | None -> false)
        | None -> false
      in
      List.exists
        (fun t ->
          if Nostr.tag_len t < 2 then false
          else
            match (Nostr.tag_name t, Nostr.tag_field t 1) with
            | Some "e", Some h -> (
                match CS.decode32 h with
                | None -> false
                | Some muted_eid ->
                    List.exists
                      (fun aeid ->
                        match CS.get_event est aeid with
                        | Some ev ->
                            List.exists
                              (fun t0 ->
                                match (Nostr.tag_name t0, Nostr.tag_field t0 1) with
                                | Some "e", Some h0 -> CS.decode32 h0 = Some muted_eid
                                | _ -> false)
                              ev.tags
                        | None -> false)
                      arg_eids)
            | Some "p", Some h -> ( match CS.decode32 h with Some muted_pk -> List.mem muted_pk arg_pks | None -> false)
            | Some "t", Some ht ->
                referenced_event_with (fun ev ->
                    let b = ref false in
                    for_hashtags ev (fun hh -> if hh = ht then b := true);
                    !b)
            | Some "word", Some w -> referenced_event_with (fun ev -> str_contains ev.content w)
            | _ -> false)
        mv.tags

(* Julia notification (cache_storage_ext.jl:611). Membership-table gates run only when app_settings
   is present (init_notification_gating); the self-notification, hidden-event and USER_UNFOLLOWED_YOU
   gates always apply. *)
let notification (est : CS.est) (recipient : string) (notif_created_at : int) (ntype : int)
    (args : CS.notif_arg list) : unit =
  let arr = Array.of_list args in
  let blocked =
    ntype = Notif.user_unfollowed_you
    || List.exists
         (function CS.Apk pk -> pk = recipient | CS.Aeid eid -> ext_is_hidden_event est eid | _ -> false)
         args
    || (!app_settings_present
       && ((not (is_app_user est recipient))
          || gate_hellthread est recipient ntype arr
          || gate_mutelist est recipient arr
          || gate_additional est recipient ntype arr
          || gate_notification_settings est recipient ntype))
  in
  if blocked then ()
  else begin
    assert (List.length args = Notif.arg_count ntype);
    if !Push_notifications.enabled then
      Push_notifications.notification est ~recipient ~created_at:notif_created_at ~ntype ~args;
    let dbh = est.CS.dbh in
    let nth i = if i < Array.length arr then Some arr.(i) else None in
    let arg1 = match nth 0 with Some a -> Option.value (notif_arg_bytes a) ~default:"" | None -> "" in
    let arg2 = match nth 1 with Some a -> notif_arg_bytes a | None -> None in
    let arg3 = match nth 2 with Some a -> Some (notif_arg_json a) | None -> None in
    let arg4 = match nth 3 with Some a -> Some (notif_arg_json a) | None -> None in
    let created_at = i64 notif_created_at and ntype64 = i64 ntype in
    ignore
      [%pgsql dbh
        "insert into pubkey_notifications_1_e5459ab9dd (pubkey, created_at, type, arg1, arg2, arg3, arg4) \
         values ($recipient, $created_at, $ntype64, $arg1, $?arg2, $?arg3, $?arg4)"];
    notification_counter_update est recipient ntype args
  end

(* Julia notifications_cb (cache_storage_ext.jl:808). [e] is the post whose deferred hooks fired;
   the first hook arg (when present) is the hex id of the acting event (e0). *)
let notifications_cb (est : CS.est) (e : Nostr.t) (ntype : int) (args : Yojson.Safe.t list) : unit =
  let arg_str i = match List.nth_opt args i with Some (`String s) -> Some s | _ -> None in
  let arg_int i = match List.nth_opt args i with Some (`Int n) -> Some n | _ -> None in
  let e0_of i =
    match arg_str i with
    | Some hx -> ( match CS.decode32 hx with Some eid -> CS.get_event est eid | None -> None)
    | None -> None
  in
  let n = ntype in
  if n = Notif.your_post_was_zapped then (
    match e0_of 0 with
    | Some e0 -> (
        match CS.zap_sender e0 with
        | Some sender ->
            let amount = Option.value (arg_int 1) ~default:0 and msg = Option.value (arg_str 2) ~default:"" in
            notification est e.pubkey e0.created_at n [ CS.Aeid e.id; CS.Apk sender; CS.Aint amount; CS.Astr msg ]
        | None -> ())
    | None -> ())
  else if n = Notif.your_post_was_liked then (
    match e0_of 0 with
    | Some e0 ->
        let reaction = Option.value (arg_str 1) ~default:"" in
        notification est e.pubkey e0.created_at n [ CS.Aeid e.id; CS.Apk e0.pubkey; CS.Astr reaction ]
    | None -> ())
  else if n = Notif.your_post_was_reposted then (
    match e0_of 0 with
    | Some e0 -> notification est e.pubkey e0.created_at n [ CS.Aeid e.id; CS.Apk e0.pubkey ]
    | None -> ())
  else if n = Notif.your_post_was_mentioned_in_post then (
    match e0_of 0 with
    | Some e0 -> notification est e.pubkey e0.created_at n [ CS.Aeid e.id; CS.Aeid e0.id; CS.Apk e0.pubkey ]
    | None -> ())
  else if n = Notif.your_post_was_highlighted then (
    match e0_of 0 with
    | Some e0 -> notification est e.pubkey e0.created_at n [ CS.Aeid e.id; CS.Apk e0.pubkey; CS.Aeid e0.id ]
    | None -> ())
  else if n = Notif.your_post_was_bookmarked then (
    match e0_of 0 with
    | Some e0 -> notification est e.pubkey e0.created_at n [ CS.Aeid e.id; CS.Apk e0.pubkey ]
    | None -> ())
  else if n = Notif.new_direct_message then (
    match
      List.find_map
        (fun tg -> match (Nostr.tag_name tg, Nostr.tag_field tg 1) with Some "p", Some h -> CS.decode32 h | _ -> None)
        e.tags
    with
    | Some receiver -> notification est receiver e.created_at n [ CS.Aeid e.id; CS.Apk e.pubkey ]
    | None -> ())
  else () (* POST_* mention-chain types are commented out in Julia notifications_cb *)

(* Julia import_reply_notifications (cache_storage.jl:1495): direct reply, replies up the thread,
   mentions in the note, and mentions up the thread. The thread chains come from the
   thread_view_parent_posts(eid) SQL function (present in primal1). *)
let import_reply_notifications (est : CS.est) (e : Nostr.t) : unit =
  let notified = Hashtbl.create 16 in
  let already pk = Hashtbl.mem notified pk in
  let mark pk = Hashtbl.replace notified pk () in
  let notify recipient ntype args = notification est recipient e.created_at ntype args in
  (* direct reply *)
  (match CS.parse_parent_eid est e with
  | Some parent_eid -> (
      match CS.get_event est parent_eid with
      | Some ep ->
          notify ep.pubkey Notif.your_post_was_replied_to [ CS.Aeid ep.id; CS.Apk e.pubkey; CS.Aeid e.id ];
          mark ep.pubkey
      | None -> ())
  | None -> ());
  let dbh = est.CS.dbh in
  let id = e.id in
  (* The thread ancestor chain (each present event paired with the pubkeys it contributes),
     reversed to leaf-last as Julia does. *)
  let build_chain (pks_of : Nostr.t -> string list) : (string * string list) list =
    let ids = List.filter_map Fun.id [%pgsql dbh "select p.event_id from thread_view_parent_posts($id) p"] in
    List.filter_map (fun eid -> match CS.get_event est eid with Some e1 -> Some (eid, pks_of e1) | None -> None) ids
    |> List.rev
  in
  let notify_chain chain ~(gt : int) =
    let len = List.length chain in
    if len > gt && len <= 15 then
      List.iteri
        (fun i (eid, pks) ->
          if i < len - 1 then
            List.iter
              (fun pk ->
                if not (already pk) then begin
                  notify pk Notif.reply_to_reply [ CS.Aeid eid; CS.Apk e.pubkey; CS.Aeid e.id ];
                  mark pk
                end)
              pks)
        chain
  in
  (* replies in thread (each ancestor author), Julia 2 < |chain| <= 15 *)
  notify_chain (build_chain (fun e1 -> [ e1.Nostr.pubkey ])) ~gt:2;
  (* mentions in this note *)
  for_mentiones est e (fun tg ->
      match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
      | Some "p", Some h -> (
          match CS.decode32 h with
          | Some pk ->
              notify pk Notif.you_were_mentioned_in_post [ CS.Aeid e.id; CS.Apk e.pubkey ];
              mark pk
          | None -> ())
      | _ -> ());
  (* mentions in thread (pubkeys each ancestor mentions), Julia 1 < |chain| <= 15 *)
  let mentioned_pks (e1 : Nostr.t) : string list =
    let acc = ref [] in
    for_mentiones est e1 (fun tg ->
        match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
        | Some "p", Some h -> ( match CS.decode32 h with Some pk -> acc := pk :: !acc | None -> ())
        | _ -> ());
    List.rev !acc
  in
  notify_chain (build_chain mentioned_pks) ~gt:1

(* {1 ext_* entry points} *)

(* Seed pubkey_zapped for a newly-tracked pubkey (Julia ext_pubkey). *)
let ext_pubkey (est : CS.est) (pubkey : string) : unit =
  let dbh = est.CS.dbh in
  ignore
    [%pgsql dbh "insert into pubkey_zapped_1_17f1f622a9 (pubkey, zaps, satszapped) values ($pubkey, 0, 0) on conflict do nothing"]

(* update_user_search (FTS) + metadata media import; both deferred. *)
let ext_metadata_changed (_est : CS.est) (_e : Nostr.t) : unit = ()

let ext_text_note (est : CS.est) (e : Nostr.t) : unit =
  check_spam_content_hash est e;
  for_mentiones est e (fun tg ->
      match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
      | Some "p", Some _ -> ()
          (* YOU_WERE_MENTIONED_IN_POST is fired from import_reply_notifications, not here
             (cache_storage_ext.jl:382 is commented out). *)
      | Some "e", Some h -> (
          match CS.decode32 h with
          | None -> ()
          | Some eid ->
              (* YOUR_POST_WAS_MENTIONED_IN_POST: fired for every e-tag mention, regardless of
                 hidden (cache_storage_ext.jl:386). *)
              CS.event_hook est eid
                (CS.Notifications_cb (Notif.your_post_was_mentioned_in_post, [ `String (Hex_util.encode e.id) ]));
              (* repost-via-mention scoring lands in event_stats (hidden-gated). *)
              if not (ext_is_hidden_event est e.id) then begin
                CS.event_hook est eid (CS.Event_stats_cb ("reposts", 1));
                CS.event_hook est eid
                  (CS.Score_event_cb
                     { initiator = e.pubkey; scored_at = e.created_at; action = "repost"; increment = 7 })
              end)
      | _ -> ());
  import_note_urls est e;
  if ext_is_human est e.pubkey then
    for_hashtags e (fun hashtag ->
        let hashtag = String.lowercase_ascii hashtag in
        let dbh = est.CS.dbh in
        let event_id = e.id and created_at = i64 e.created_at in
        ignore
          [%pgsql dbh "insert into event_hashtags_1_295f217c0e (event_id, hashtag, created_at) values ($event_id, $hashtag, $created_at)"];
        (match [%pgsql dbh "select 1 from hashtags_1_1e5c72161a where hashtag = $hashtag limit 1"] with
        | [] -> ignore [%pgsql dbh "insert into hashtags_1_1e5c72161a (hashtag, score) values ($hashtag, 0)"]
        | _ -> ());
        ignore [%pgsql dbh "update hashtags_1_1e5c72161a set score = score + 1 where hashtag = $hashtag"];
        CS.schedule_hook est
          ~execute_at:(current_time () + (4 * 3600))
          (`List [ `String "expire_hashtag_score_cb"; `String hashtag; `Int 1 ]))

let ext_reaction (est : CS.est) (e : Nostr.t) (eid : string) : unit =
  CS.event_hook est eid
    (CS.Score_event_cb { initiator = e.pubkey; scored_at = e.created_at; action = "like"; increment = 1 })

let ext_reply (est : CS.est) (e : Nostr.t) (parent_eid : string) : unit =
  CS.event_hook est parent_eid
    (CS.Score_event_cb { initiator = e.pubkey; scored_at = e.created_at; action = "reply"; increment = 10 })

let ext_repost (est : CS.est) (e : Nostr.t) (eid : string) : unit =
  CS.event_hook est eid
    (CS.Score_event_cb { initiator = e.pubkey; scored_at = e.created_at; action = "repost"; increment = 7 });
  (* YOUR_POST_WAS_REPOSTED (cache_storage_ext.jl:474). *)
  CS.event_hook est eid
    (CS.Notifications_cb (Notif.your_post_was_reposted, [ `String (Hex_util.encode e.id) ]))

let ext_zap (est : CS.est) (e : Nostr.t) (parent_eid : string) (amount_sats : int) : unit =
  match CS.zap_sender e with
  | None -> ()
  | Some sender ->
      CS.event_hook est parent_eid
        (CS.Score_event_cb { initiator = sender; scored_at = e.created_at; action = "zap"; increment = 5 });
      if ext_is_human est sender then begin
        (* zap message = the "content" field of the description-tag JSON (cache_storage_ext.jl:484). *)
        let msg =
          List.fold_left
            (fun acc tg ->
              match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
              | Some "description", Some d -> (
                  match Yojson.Safe.from_string d with
                  | json -> ( match Yojson.Safe.Util.member "content" json with `String s -> s | _ -> acc)
                  | exception _ -> acc)
              | _ -> acc)
            "" e.tags
        in
        CS.event_hook est parent_eid (CS.Event_stats_cb ("satszapped", amount_sats));
        (* YOUR_POST_WAS_ZAPPED (cache_storage_ext.jl:491): args (zap receipt id, sats, message). *)
        CS.event_hook est parent_eid
          (CS.Notifications_cb
             (Notif.your_post_was_zapped,
              [ `String (Hex_util.encode e.id); `Int amount_sats; `String msg ]));
        import_zap_receipt est e parent_eid amount_sats
      end

let ext_pubkey_zap (est : CS.est) (e : Nostr.t) (zapped_pk : string) (amount_sats : int) : unit =
  match CS.zap_sender e with
  | Some sender when ext_is_human est sender ->
      let dbh = est.CS.dbh in
      let amount = i64 amount_sats in
      ignore
        [%pgsql dbh "update pubkey_zapped_1_17f1f622a9 set zaps = zaps + 1, satszapped = satszapped + $amount where pubkey = $zapped_pk"]
  | _ -> ()

(* long-form / video / live: only media imports, all gated on DOWNLOAD_MEDIA — no-ops here. *)
let ext_long_form_note (est : CS.est) (e : Nostr.t) : unit = import_note_urls est e
let ext_video_note (est : CS.est) (e : Nostr.t) : unit = import_note_urls est e
let ext_live_event (_est : CS.est) (_e : Nostr.t) : unit = ()

(* Julia ext_preimport_check: !(pubkey in Filterlist.import_pubkey_blocked) — read the local
   filterlist. *)
let ext_preimport_check (est : CS.est) (e : Nostr.t) : bool =
  not (Filterlist.is_import_pubkey_blocked est.CS.dbh e.pubkey)

(* Scheduled-hook callback: decrement a hashtag's score after the expiry window (Julia
   expire_hashtag_score_cb). *)
let expire_hashtag_score_cb (est : CS.est) (hashtag : string) (d : int) : unit =
  let dbh = est.CS.dbh in
  let delta = i64 d in
  ignore [%pgsql dbh "update hashtags_1_1e5c72161a set score = score - $delta where hashtag = $hashtag"]

(* Julia import_reporting (NIP-56): a whitelisted reporter's kind-1984 report blocks the
   reported pubkeys/events on the membership filterlist. The report type lives in the tag's 3rd
   field; only spam / impersonation are acted on. Gated by est.cfg.import_reporting at the call
   site and by the reporting whitelist here. *)
let import_reporting (est : CS.est) (e : Nostr.t) : unit =
  if List.mem e.pubkey est.CS.cfg.CS.reporting_whitelist then begin
    let added_at = i64 e.created_at in
    let comment = Printf.sprintf "1984/%s: %s" (Hex_util.encode e.id) e.content in
    let insert_rule target target_type grp =
      Filterlist.block ~mem_dbh:est.CS.mem_dbh ~added_at ~target ~target_type ~grp ~comment ()
    in
    List.iter
      (fun tg ->
        if Nostr.tag_len tg >= 3 then
          match Nostr.tag_field tg 2 with
          | Some "impersonation" | Some "spam" -> (
              let grp = match Nostr.tag_field tg 2 with Some "impersonation" -> Impersonation | _ -> Spam in
              match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
              | Some "p", Some h -> (
                  match CS.decode32 h with Some pk -> insert_rule pk Pubkey grp | None -> ())
              | Some "e", Some h -> (
                  match CS.decode32 h with
                  | Some eid ->
                      insert_rule eid Event grp;
                      (match CS.get_event est eid with
                      | Some ev -> insert_rule ev.pubkey Pubkey grp
                      | None -> ())
                  | None -> ())
              | _ -> ())
          | _ -> ())
      e.tags
  end

(* {1 event scoring} (Julia score_event_cb)

   Time-decayed engagement score: a reply's weight depends on its length; the increment is
   scaled by humanness and zeroed for non-human initiators or duplicate (pubkey, ref_kind)
   actions; recent activity (<24h) also bumps score24h and schedules a score_expiry row. *)
let score_event_cb (est : CS.est) (e : Nostr.t) (initiator : string) (scored_at : int)
    (action : string) (increment : int) : unit =
  let increment =
    if action = "reply" then
      let len = String.length e.content in
      if len <= 20 then 1 else if len <= 100 then 5 else 10
    else increment
  in
  let increment =
    if ext_is_human est initiator then int_of_float (1e10 *. float_of_int increment /. 91.) else 0
  in
  let ref_kind =
    match action with
    | "like" -> Some Nostr.kind_reaction
    | "reply" -> Some Nostr.kind_text_note
    | "repost" -> Some Nostr.kind_repost
    | "zap" -> Some Nostr.kind_zap_receipt
    | _ -> None
  in
  match ref_kind with
  | None -> ()
  | Some ref_kind ->
      let dbh = est.CS.dbh in
      let event_id = e.id and rk = i64 ref_kind in
      let dup =
        match
          [%pgsql dbh "select count(1) from event_pubkey_action_refs_1_f32e1ff589 where event_id = $event_id and ref_pubkey = $initiator and ref_kind = $rk"]
        with
        | Some n :: _ -> n > 1L
        | _ -> false
      in
      let increment = if dup then 0 else increment in
      if increment > 0 then begin
        let inc = i64 increment in
        ignore [%pgsql dbh "update event_stats_1_1b380f4869 set score = score + $inc where event_id = $event_id"];
        let expire_at = scored_at + (24 * 3600) in
        if expire_at > current_time () then begin
          ignore [%pgsql dbh "update event_stats_1_1b380f4869 set score24h = score24h + $inc where event_id = $event_id"];
          let author_pubkey = e.pubkey and change = inc and expire_at = i64 expire_at in
          ignore
            [%pgsql dbh "insert into score_expiry (event_id, author_pubkey, change, expire_at) values ($event_id, $author_pubkey, $change, $expire_at)"]
        end
      end

(* {1 registration} *)

let ext_hooks : CS.ext_hooks =
  {
    CS.ext_preimport_check = ext_preimport_check;
    ext_pubkey = ext_pubkey;
    ext_metadata_changed = ext_metadata_changed;
    ext_text_note = ext_text_note;
    ext_reaction = ext_reaction;
    ext_reply = ext_reply;
    ext_repost = ext_repost;
    ext_zap = ext_zap;
    ext_pubkey_zap = ext_pubkey_zap;
    ext_long_form_note = ext_long_form_note;
    ext_video_note = ext_video_note;
    ext_live_event = ext_live_event;
    ext_is_hidden_event = ext_is_hidden_event;
    ext_is_hidden_pubkey = ext_is_hidden_pubkey;
    import_reporting = import_reporting;
    score_event_cb = score_event_cb;
    expire_hashtag_score_cb = expire_hashtag_score_cb;
    notification;
    notifications_cb;
    import_reply_notifications;
  }

let register () = CS.set_ext ext_hooks
