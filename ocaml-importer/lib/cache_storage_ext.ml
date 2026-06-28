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
  | h :: _ -> h
  | [] -> (
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
      "insert into og_zap_receipts (zap_receipt_id, created_at, sender, receiver, amount_sats, event_id) \
       values ($zap_receipt_id, $created_at, $?sender, $?receiver, $amount, $?event_id)"]

(* {1 ext_* entry points} *)

(* Seed pubkey_zapped for a newly-tracked pubkey (Julia ext_pubkey). *)
let ext_pubkey (est : CS.est) (pubkey : string) : unit =
  let dbh = est.CS.dbh in
  ignore
    [%pgsql dbh "insert into pubkey_zapped (pubkey, zaps, satszapped) values ($pubkey, 0, 0) on conflict do nothing"]

(* update_user_search (FTS) + metadata media import; both deferred. *)
let ext_metadata_changed (_est : CS.est) (_e : Nostr.t) : unit = ()

let ext_text_note (est : CS.est) (e : Nostr.t) : unit =
  check_spam_content_hash est e;
  for_mentiones est e (fun tg ->
      match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
      | Some "p", Some _ -> () (* YOU_WERE_MENTIONED_IN_POST notification — TODO *)
      | Some "e", Some h -> (
          (* YOUR_POST_WAS_MENTIONED_IN_POST notification — TODO. The repost-via-mention
             scoring below DOES land in event_stats. *)
          match CS.decode32 h with
          | None -> ()
          | Some eid ->
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
          [%pgsql dbh "insert into event_hashtags (event_id, hashtag, created_at) values ($event_id, $hashtag, $created_at)"];
        (match [%pgsql dbh "select 1 from hashtags where hashtag = $hashtag limit 1"] with
        | [] -> ignore [%pgsql dbh "insert into hashtags (hashtag, score) values ($hashtag, 0)"]
        | _ -> ());
        ignore [%pgsql dbh "update hashtags set score = score + 1 where hashtag = $hashtag"];
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
    (CS.Score_event_cb { initiator = e.pubkey; scored_at = e.created_at; action = "repost"; increment = 7 })

let ext_zap (est : CS.est) (e : Nostr.t) (parent_eid : string) (amount_sats : int) : unit =
  match CS.zap_sender e with
  | None -> ()
  | Some sender ->
      CS.event_hook est parent_eid
        (CS.Score_event_cb { initiator = sender; scored_at = e.created_at; action = "zap"; increment = 5 });
      if ext_is_human est sender then begin
        CS.event_hook est parent_eid (CS.Event_stats_cb ("satszapped", amount_sats));
        (* YOUR_POST_WAS_ZAPPED & friends notifications — TODO *)
        import_zap_receipt est e parent_eid amount_sats
      end

let ext_pubkey_zap (est : CS.est) (e : Nostr.t) (zapped_pk : string) (amount_sats : int) : unit =
  match CS.zap_sender e with
  | Some sender when ext_is_human est sender ->
      let dbh = est.CS.dbh in
      let amount = i64 amount_sats in
      ignore
        [%pgsql dbh "update pubkey_zapped set zaps = zaps + 1, satszapped = satszapped + $amount where pubkey = $zapped_pk"]
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
  ignore [%pgsql dbh "update hashtags set score = score - $delta where hashtag = $hashtag"]

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
          [%pgsql dbh "select count(1) from event_pubkey_action_refs where event_id = $event_id and ref_pubkey = $initiator and ref_kind = $rk"]
        with
        | Some n :: _ -> n > 1L
        | _ -> false
      in
      let increment = if dup then 0 else increment in
      if increment > 0 then begin
        let inc = i64 increment in
        ignore [%pgsql dbh "update event_stats set score = score + $inc where event_id = $event_id"];
        let expire_at = scored_at + (24 * 3600) in
        if expire_at > current_time () then begin
          ignore [%pgsql dbh "update event_stats set score24h = score24h + $inc where event_id = $event_id"];
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
  }

let register () = CS.set_ext ext_hooks
