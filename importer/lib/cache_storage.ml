(* Core event-import pipeline, mirroring Julia src/cache_storage.jl (module DB). SQL is
   inline with [%pgsql] exactly where the Julia code calls [exe(est.table, @sql("..."), ...)].
   The connection [est.dbh] is leased once per event by the caller (Worker_pool / main).

   This module has the core storage path and the per-kind dispatch; the ext_* hooks
   (notifications, scores, media, live events, moderation rules, ...) are in Cache_storage_ext,
   reached through the [ext] registry, and LNURL zapper verification is in Zap_verifier. Julia's
   relay fetching of missing events is not done by the importer. *)

module PGOCaml = Postgres.PGOCaml
module Notif = Notifications

type config = {
  verification_enabled : bool;
  verify_zappers : bool;
  trusted_zappers : string list; (* raw 32-byte pubkeys *)
  disable_trustrank : bool;
      (* Julia est.disable_trustrank: when set, seed pubkey_trustrank=1.0 for every new
         pubkey so ext_is_human is true for everyone (used when no TrustRankMaker runs). *)
  import_reporting : bool; (* Julia IMPORT_REPORTING_EVENTS: process kind-1984 reports *)
  reporting_whitelist : string list; (* raw 32-byte pubkeys allowed to report (REPORTING_WHITELIST) *)
  download_media : bool; (* Julia DOWNLOAD_MEDIA: queue import_media_pn / import_media_fast_pn nodes (media host) *)
  download_previews : bool; (* Julia DOWNLOAD_PREVIEWS: queue import_preview_pn nodes for non-media URLs (media host) *)
  lean : Lean.t; (* the optional lean write path (config key "lean"); Lean.off = the classic path *)
}

let default_config =
  {
    verification_enabled = true;
    verify_zappers = true;
    trusted_zappers = [];
    disable_trustrank = false;
    import_reporting = false;
    reporting_whitelist = [];
    download_media = false;
    download_previews = false;
    lean = Lean.off;
  }

(* [dbh] is the cache DB (Julia :p0); [mem_dbh] is the membership DB (Julia :membership),
   where the filterlist / human_override tables live. At compile time both type-check against
   the same schema DB. *)
(* [dbh]/[mem_dbh] are mutable so a worker can swap in fresh connections after Postgres drops them
   (restart / network reset) without rebuilding the whole est — see [reconnect_est] in main.ml. Each
   per-event query reads [est.dbh] afresh, so the swap takes effect on the next event. *)
type est = { cfg : config; mutable dbh : Postgres.dbh; mutable mem_dbh : Postgres.dbh }

(* A single notification argument, as it is stored in pubkey_notifications. The first two
   positional args of every NotificationType are an EventId / PubKeyId (written to the bytea
   arg1/arg2 columns); the remaining args are scalars (Int satszapped, Str reaction/message) or
   an EventId/PubKeyId, all written JSON-encoded to the jsonb arg3/arg4 columns. This mirrors the
   Julia notification() insert (cache_storage_ext.jl:744), which writes notif[4:5] natively and
   JSON.json's notif[6:7]. *)
type notif_arg = Aeid of string | Apk of string | Aint of int | Astr of string

(* {1 ext hook registry} (mirrors Julia's separately-defined cache_storage_ext.jl functions)

   Julia dispatches ext_* by name at runtime, so cache_storage.jl can call functions defined
   in cache_storage_ext.jl with no static dependency. We reproduce that with a record of
   function fields, defaulting to no-ops, populated by [Cache_storage_ext.register] at
   startup. This keeps the dependency one-way (cache_storage_ext depends on cache_storage)
   while letting the dispatch here invoke the ext implementations. *)
type ext_hooks = {
  ext_preimport_check : est -> Nostr.t -> bool;
  ext_pubkey : est -> string -> unit;
  ext_metadata_changed : est -> Nostr.t -> unit;
  ext_text_note : est -> Nostr.t -> unit;
  ext_reaction : est -> Nostr.t -> string -> unit;       (* reacted-to eid *)
  ext_reply : est -> Nostr.t -> string -> unit;          (* parent eid *)
  ext_repost : est -> Nostr.t -> string -> unit;         (* reposted eid *)
  ext_zap : est -> Nostr.t -> string -> int -> unit;     (* parent eid, amount_sats *)
  ext_pubkey_zap : est -> Nostr.t -> string -> int -> unit; (* zapped pk, amount_sats *)
  ext_long_form_note : est -> Nostr.t -> unit;
  ext_video_note : est -> Nostr.t -> unit;
  ext_live_event : est -> Nostr.t -> unit;
  ext_follow_pack : est -> Nostr.t -> unit;          (* kind 39089 follow packs -> follow_lists *)
  ext_live_event_mutelist : est -> Nostr.t -> unit;  (* kind 10555 -> live_event_pubkey_filterlist *)
  ext_zap_receipt_invoice : est -> Nostr.t -> unit;  (* kind 9735 -> zap_receipt_invoices *)
  update_content_moderation_rules : est -> string -> unit; (* user pubkey: recompute cmr_* *)
  ext_is_hidden_event : est -> string -> bool;           (* eid *)
  ext_is_hidden_pubkey : est -> string -> bool;          (* pubkey *)
  import_reporting : est -> Nostr.t -> unit;             (* kind-1984 reporting events *)
  score_event_cb : est -> Nostr.t -> string -> int -> string -> int -> unit;
      (* parent event, initiator pubkey, scored_at, action, increment *)
  expire_hashtag_score_cb : est -> string -> int -> unit; (* hashtag, delta (scheduled hook) *)
  notification : est -> string -> int -> int -> notif_arg list -> unit;
      (* recipient pubkey, notif_created_at, NotificationType code, args *)
  notifications_cb : est -> Nostr.t -> int -> Yojson.Safe.t list -> unit;
      (* the event whose deferred hooks fired, NotificationType code, raw hook args *)
  import_reply_notifications : est -> Nostr.t -> unit;   (* reply/comment notification fan-out *)
}

let no_ext =
  {
    ext_preimport_check = (fun _ _ -> true);
    ext_pubkey = (fun _ _ -> ());
    ext_metadata_changed = (fun _ _ -> ());
    ext_text_note = (fun _ _ -> ());
    ext_reaction = (fun _ _ _ -> ());
    ext_reply = (fun _ _ _ -> ());
    ext_repost = (fun _ _ _ -> ());
    ext_zap = (fun _ _ _ _ -> ());
    ext_pubkey_zap = (fun _ _ _ _ -> ());
    ext_long_form_note = (fun _ _ -> ());
    ext_video_note = (fun _ _ -> ());
    ext_live_event = (fun _ _ -> ());
    ext_follow_pack = (fun _ _ -> ());
    ext_live_event_mutelist = (fun _ _ -> ());
    ext_zap_receipt_invoice = (fun _ _ -> ());
    update_content_moderation_rules = (fun _ _ -> ());
    ext_is_hidden_event = (fun _ _ -> false);
    ext_is_hidden_pubkey = (fun _ _ -> false);
    import_reporting = (fun _ _ -> ());
    score_event_cb = (fun _ _ _ _ _ _ -> ());
    expire_hashtag_score_cb = (fun _ _ _ -> ());
    notification = (fun _ _ _ _ _ -> ());
    notifications_cb = (fun _ _ _ _ -> ());
    import_reply_notifications = (fun _ _ -> ());
  }

let ext = ref no_ext
let set_ext h = ext := h

(* Synchronous LNURL zapper verification (Julia cache_storage.jl:1265-1294), used only when no
   [zap_verifier_submit] pool is wired (the daemon wires Zap_verifier; zapbackfill sets this one,
   since a verifier needs Eio net/clock/proxy, not available in [est]). Default: reject — so
   without either and with verify_zappers on, only trusted_zappers pass. *)
let zapper_verifier : (est -> zapped_pk:string -> zap_receipt:Nostr.t -> bool) ref =
  ref (fun _ ~zapped_pk:_ ~zap_receipt:_ -> false)

let set_zapper_verifier f = zapper_verifier := f

(* Julia ext_is_hidden(est, e.id) / ext_is_hidden(est, pubkey); routed through the registry. *)
let ext_is_hidden_event (est : est) (id : string) : bool = (!ext).ext_is_hidden_event est id
let ext_is_hidden_pubkey (est : est) (pubkey : string) : bool = (!ext).ext_is_hidden_pubkey est pubkey

let max_message_size = 2_000_000
let max_satszapped = 1_100_000
let i64 = Int64.of_int

(* {1 Lean: the event transaction} (lean.transaction_per_event)

   After the claim, an event's side effects run in one transaction on [est.dbh]. The state is per
   domain (each worker domain imports one event at a time on its own connection). [after_commit]
   defers work that must not be repeated by a retry or that talks to other hosts (device pushes).
   Nested transactions (live events, follow packs, content-moderation rules) become part of the
   event's transaction ([in_event_tx_on]). *)
type tx_state = { mutable tx_dbh : Postgres.dbh option; mutable post_commit : (unit -> unit) list }

let tx_key : tx_state Domain.DLS.key = Domain.DLS.new_key (fun () -> { tx_dbh = None; post_commit = [] })
let in_event_tx () = (Domain.DLS.get tx_key).tx_dbh <> None

let in_event_tx_on (dbh : Postgres.dbh) : bool =
  match (Domain.DLS.get tx_key).tx_dbh with Some d -> d == dbh | None -> false

let after_commit (f : unit -> unit) : unit =
  let st = Domain.DLS.get tx_key in
  if st.tx_dbh <> None then st.post_commit <- f :: st.post_commit else f ()

let sqlstate : exn -> string option = function
  | PGOCaml.PostgreSQL_Error (_, fields) -> List.assoc_opt 'C' fields
  | _ -> None

(* deadlock_detected / serialization_failure: the whole event is retried *)
let is_retryable_tx_error (e : exn) : bool = match sqlstate e with Some ("40P01" | "40001") -> true | _ -> false

let guard label f = try f () with exn ->
  (* inside an event transaction a failed statement has aborted the transaction: let the
     transaction runner see it (it retries or falls back to this autocommit path) *)
  if in_event_tx () then raise exn;
  Printf.eprintf "import_event: %s: %s\n%!" label (Printexc.to_string exn)

(* {1 Lean: the per-event scope} (lean.enabled)

   While one event (or one verified zap) is applied: a memo of the events read by id (seeded with
   the event in hand, so hooks, notifications and kind 0 don't re-read it, and each hook target is
   read once), of parsed parents and of addressable-pointer lookups; and the event_stats deltas of
   every hook, written at the end as one statement per row (in id order, so concurrent workers lock
   rows in the same order). *)
type stats_delta = {
  mutable likes : int;
  mutable replies : int;
  mutable mentions : int;
  mutable reposts : int;
  mutable zaps : int;
  mutable satszapped : int;
  mutable score : int;
  mutable score24h : int;
  mutable author : string option; (* the target's pubkey and created_at, for a lazy insert *)
  mutable target_created_at : int;
  mutable note : bool; (* the target is a note kind (only those have event_stats rows) *)
}

let zero_delta () =
  { likes = 0; replies = 0; mentions = 0; reposts = 0; zaps = 0; satszapped = 0; score = 0; score24h = 0;
    author = None; target_created_at = 0; note = false }

type scope = {
  memo : (string, Nostr.t option) Hashtbl.t;
  stats : (string, stats_delta) Hashtbl.t;
  parents : (string, string option) Hashtbl.t;
  pre : (int * string * string, string option) Hashtbl.t;
}

let scope_key : scope option ref Domain.DLS.key = Domain.DLS.new_key (fun () -> ref None)
let current_scope () = !(Domain.DLS.get scope_key)
let memo_forget (id : string) = match current_scope () with Some s -> Hashtbl.remove s.memo id | None -> ()

(* {1 Kind classification} (Julia kindints / accepted_kind / is_pubkey_event) *)

let kindints =
  [ 0; 1; 2; 3; 4; 5; 6; 7; 9735; 10000; 10002; 30000; 30023;
    10003; 9802; 1984; 1068; 1018; 6969; 1311; 20; 1111 ]

let in_kindints k = List.mem k kindints

let accepted_kind k =
  k <> 30382 && k <> 30383
  && (in_kindints k || (10000 <= k && k < 20000) || (30000 <= k && k < 40000))

let is_pubkey_event_kind k =
  k = Nostr.kind_text_note || k = Nostr.kind_poll || k = Nostr.kind_zap_poll
  || k = Nostr.kind_picture || k = Nostr.kind_video_long_form
  || k = Nostr.kind_video_short_form || k = Nostr.kind_repost

let is_note_kind k =
  k = Nostr.kind_text_note || k = Nostr.kind_long_form_content || k = Nostr.kind_poll
  || k = Nostr.kind_zap_poll || k = Nostr.kind_picture || k = Nostr.kind_video_long_form
  || k = Nostr.kind_video_short_form || k = Nostr.kind_comment

(* a text-note-ish kind handled by the note branch (Julia 1200) *)
let is_text_note_branch k =
  k = Nostr.kind_text_note || k = Nostr.kind_poll || k = Nostr.kind_zap_poll
  || k = Nostr.kind_picture

let is_reply_event (e : Nostr.t) =
  (e.kind = Nostr.kind_text_note || e.kind = Nostr.kind_poll
  || e.kind = Nostr.kind_zap_poll || e.kind = Nostr.kind_picture
  || e.kind = Nostr.kind_video_long_form || e.kind = Nostr.kind_video_short_form)
  && List.exists
       (fun tg ->
         Nostr.tag_len tg >= 4
         && (match Nostr.tag_field tg 0 with Some ("e" | "a") -> true | _ -> false)
         && Nostr.tag_field tg 3 = Some "root")
       e.tags

(* {1 Small parsing helpers} *)

(* 32-byte id/pubkey from 64-char hex, else None. *)
let decode32 h = if String.length h = 64 then Hex_util.decode_opt h else None

let starts_with s p =
  String.length s >= String.length p && String.sub s 0 (String.length p) = p

(* Julia: parse_a_tag — "kind:pubkeyhex:identifier" *)
let parse_a_tag (s : string) : (int * string * string) option =
  match String.split_on_char ':' s with
  | kind :: pk :: rest -> (
      match (int_of_string_opt kind, decode32 pk) with
      | Some kind, Some pubkey -> Some (kind, pubkey, String.concat ":" rest)
      | _ -> None)
  | _ -> None

(* {1 Reads} *)

let already_imported_id (est : est) (id : string) : bool =
  let dbh = est.dbh in
  match [%pgsql dbh "select 1 from event where id = $id limit 1"] with
  | [] -> false
  | _ -> true

let already_imported (est : est) (e : Nostr.t) = already_imported_id est e.id

let event_deleted (est : est) (id : string) : bool =
  let dbh = est.dbh in
  match [%pgsql dbh "select 1 from deleted_events_1_0249f47b16 where event_id = $id limit 1"] with
  | [] -> false
  | _ -> true

let parse_tags_json (s : string) : Nostr.tag list =
  match Yojson.Safe.from_string s with
  | `List ts -> List.map (function `List f -> f | other -> [ other ]) ts
  | _ -> []

(* Julia: est.events[eid] -> Nostr.Event (reconstructed from the row). *)
let rec get_event (est : est) (id : string) : Nostr.t option =
  match current_scope () with
  | Some s -> (
      match Hashtbl.find_opt s.memo id with
      | Some r -> r
      | None ->
          let r = get_event_db est id in
          Hashtbl.replace s.memo id r;
          r)
  | None -> get_event_db est id

and get_event_db (est : est) (id : string) : Nostr.t option =
  let dbh = est.dbh in
  match
    [%pgsql dbh "select pubkey, created_at, kind, tags, content, sig from event where id = $id"]
  with
  | (pubkey, created_at, kind, tags, content, sig_) :: _ ->
      Some
        {
          Nostr.id;
          pubkey;
          created_at = Int64.to_int created_at;
          kind = Int64.to_int kind;
          tags = parse_tags_json tags;
          content;
          sig_;
        }
  | [] -> None

(* Lean: pubkey, created_at and kind of an event, for callers that need nothing else (the row is
   read without detoasting tags/content); from the scope's memo when it has the event. *)
let get_event_meta (est : est) (id : string) : (string * int * int) option =
  match current_scope () with
  | Some s when Hashtbl.mem s.memo id -> (
      match Hashtbl.find s.memo id with Some e -> Some (e.Nostr.pubkey, e.created_at, e.kind) | None -> None)
  | _ -> (
      let dbh = est.dbh in
      match [%pgsql dbh "select pubkey, created_at, kind from event where id = $id"] with
      | (pubkey, created_at, kind) :: _ -> Some (pubkey, Int64.to_int created_at, Int64.to_int kind)
      | [] -> None)

(* Lean: per-worker TTL cache of is_trusted_user (lean.enabled). *)
let trusted_cache : (string, bool) Lean.Ttl.t = Lean.Ttl.create ~ttl:60.0 ()

(* Julia is_trusted_user -> ext_is_human(threshold=0) -> pubkey_trustrank.rank > 0 *)
let is_trusted_user (est : est) (pubkey : string) : bool =
  let q () =
    let dbh = est.dbh in
    match [%pgsql dbh "select 1 from pubkey_trustrank where pubkey = $pubkey and rank > 0 limit 1"] with
    | [] -> false
    | _ -> true
  in
  if est.cfg.lean.enabled then Lean.Ttl.find_or_add trusted_cache pubkey q else q ()

(* {1 event_stats counters} (Julia event_stats_cb; dynamic column -> one query each) *)

let incr_event_stat (est : est) (event_id : string) (prop : string) (increment : int) : unit =
  let dbh = est.dbh in
  let d = i64 increment in
  match prop with
  | "likes" -> ignore [%pgsql dbh "update event_stats_1_1b380f4869 set likes = likes + $d where event_id = $event_id"]
  | "replies" -> ignore [%pgsql dbh "update event_stats_1_1b380f4869 set replies = replies + $d where event_id = $event_id"]
  | "mentions" -> ignore [%pgsql dbh "update event_stats_1_1b380f4869 set mentions = mentions + $d where event_id = $event_id"]
  | "reposts" -> ignore [%pgsql dbh "update event_stats_1_1b380f4869 set reposts = reposts + $d where event_id = $event_id"]
  | "zaps" -> ignore [%pgsql dbh "update event_stats_1_1b380f4869 set zaps = zaps + $d where event_id = $event_id"]
  | "satszapped" -> ignore [%pgsql dbh "update event_stats_1_1b380f4869 set satszapped = satszapped + $d where event_id = $event_id"]
  | "score" -> ignore [%pgsql dbh "update event_stats_1_1b380f4869 set score = score + $d where event_id = $event_id"]
  | "score24h" -> ignore [%pgsql dbh "update event_stats_1_1b380f4869 set score24h = score24h + $d where event_id = $event_id"]
  | _ -> ()

(* Lean: one statement for all of a row's deltas (lean.enabled merges a whole event's hooks; with
   only lazy_counters each hook is still its own statement). With lazy_counters a note's row is
   created by its first increment (upsert on the unique event_id; no zero row at insert), and a
   decrement (repost deletion) never creates a row. Non-note targets never had a row: plain UPDATE,
   as the classic path. *)
let write_stats_delta (est : est) (event_id : string) (d : stats_delta) : unit =
  let all = [ d.likes; d.replies; d.mentions; d.reposts; d.zaps; d.satszapped; d.score; d.score24h ] in
  if List.exists (fun x -> x <> 0) all then begin
    let dbh = est.dbh in
    let l = i64 d.likes and r = i64 d.replies and m = i64 d.mentions and rp = i64 d.reposts in
    let z = i64 d.zaps and s = i64 d.satszapped and sc = i64 d.score and s24 = i64 d.score24h in
    match d.author with
    | Some author_pubkey when est.cfg.lean.lazy_counters && d.note && List.for_all (fun x -> x >= 0) all ->
        let created_at = i64 d.target_created_at in
        ignore
          [%pgsql dbh
            "insert into event_stats_1_1b380f4869 (event_id, author_pubkey, created_at, likes, replies, mentions, \
             reposts, zaps, satszapped, score, score24h) values ($event_id, $author_pubkey, $created_at, $l, $r, $m, \
             $rp, $z, $s, $sc, $s24) on conflict (event_id) do update set \
             likes = event_stats_1_1b380f4869.likes + excluded.likes, \
             replies = event_stats_1_1b380f4869.replies + excluded.replies, \
             mentions = event_stats_1_1b380f4869.mentions + excluded.mentions, \
             reposts = event_stats_1_1b380f4869.reposts + excluded.reposts, \
             zaps = event_stats_1_1b380f4869.zaps + excluded.zaps, \
             satszapped = event_stats_1_1b380f4869.satszapped + excluded.satszapped, \
             score = event_stats_1_1b380f4869.score + excluded.score, \
             score24h = event_stats_1_1b380f4869.score24h + excluded.score24h"]
    | _ ->
        ignore
          [%pgsql dbh
            "update event_stats_1_1b380f4869 set likes = likes + $l, replies = replies + $r, mentions = mentions + $m, \
             reposts = reposts + $rp, zaps = zaps + $z, satszapped = satszapped + $s, score = score + $sc, \
             score24h = score24h + $s24 where event_id = $event_id"]
  end

let add_prop (d : stats_delta) (prop : string) (inc : int) : unit =
  match prop with
  | "likes" -> d.likes <- d.likes + inc
  | "replies" -> d.replies <- d.replies + inc
  | "mentions" -> d.mentions <- d.mentions + inc
  | "reposts" -> d.reposts <- d.reposts + inc
  | "zaps" -> d.zaps <- d.zaps + inc
  | "satszapped" -> d.satszapped <- d.satszapped + inc
  | "score" -> d.score <- d.score + inc
  | "score24h" -> d.score24h <- d.score24h + inc
  | _ -> ()

(* Lean (enabled or lazy_counters): add to a row's deltas — into the scope's buffer when one is
   open, else written at once. [target] (the event the row belongs to) gives author/created_at/kind
   for a lazy insert. *)
let stats_add (est : est) ?(target : Nostr.t option) (event_id : string) (f : stats_delta -> unit) : unit =
  let fill d =
    match target with
    | Some t when d.author = None ->
        d.author <- Some t.Nostr.pubkey;
        d.target_created_at <- t.created_at;
        d.note <- is_note_kind t.kind
    | _ -> ()
  in
  match current_scope () with
  | Some s ->
      let d =
        match Hashtbl.find_opt s.stats event_id with
        | Some d -> d
        | None ->
            let d = zero_delta () in
            Hashtbl.replace s.stats event_id d;
            d
      in
      fill d;
      f d
  | None ->
      let d = zero_delta () in
      fill d;
      f d;
      write_stats_delta est event_id d

let lean_stats (est : est) = est.cfg.lean.enabled || est.cfg.lean.lazy_counters

(* Open the per-event scope (lean.enabled) around [f], seeded with the event in hand; re-entrant (a
   zap applied inside its receipt's import joins that scope). The buffered event_stats deltas are
   written when [f] returns, and also when it raises outside an event transaction (the classic path
   had already written them by then); inside one, the rollback discards them. *)
let with_scope (est : est) (seed : Nostr.t) (f : unit -> 'a) : 'a =
  if not est.cfg.lean.enabled then f ()
  else
    let r = Domain.DLS.get scope_key in
    match !r with
    | Some s ->
        Hashtbl.replace s.memo seed.id (Some seed);
        f ()
    | None ->
        let s = { memo = Hashtbl.create 16; stats = Hashtbl.create 8; parents = Hashtbl.create 4; pre = Hashtbl.create 4 } in
        Hashtbl.replace s.memo seed.id (Some seed);
        r := Some s;
        let flush () =
          let ids = List.sort compare (Hashtbl.fold (fun k _ acc -> k :: acc) s.stats []) in
          List.iter (fun id -> write_stats_delta est id (Hashtbl.find s.stats id)) ids;
          Hashtbl.reset s.stats
        in
        Fun.protect
          ~finally:(fun () -> r := None)
          (fun () ->
            match f () with
            | v ->
                flush ();
                v
            | exception e ->
                if not (in_event_tx ()) then (try flush () with _ -> ());
                raise e)

(* {1 event_hooks} (Julia event_hook / event_hook_execute; funcall stored as JSON)

   Typed deferred call, stored as JSON in event_hooks until the event it waits for is imported. *)
type hook_call =
  | Event_stats_cb of string * int
  | Score_event_cb of { initiator : string; scored_at : int; action : string; increment : int }
  | Notifications_cb of int * Yojson.Safe.t list
      (* NotificationType code + the hook args (Julia (:notifications_cb, type, args...)); the
         first arg, when present, is the hex id of the acting event (looked up as e0). *)
  | Other of Yojson.Safe.t list

let hook_to_json = function
  | Event_stats_cb (prop, inc) -> `List [ `String "event_stats_cb"; `String prop; `Int inc ]
  | Score_event_cb { initiator; scored_at; action; increment } ->
      (* matches Julia's stored (:score_event_cb, e.pubkey, e.created_at, :action, inc):
         the pubkey JSON-lowers to hex, the symbol to a string. *)
      `List [ `String "score_event_cb"; `String (Hex_util.encode initiator);
              `Int scored_at; `String action; `Int increment ]
  | Notifications_cb (ntype, args) -> `List (`String "notifications_cb" :: `Int ntype :: args)
  | Other args -> `List args

let hook_of_json (j : Yojson.Safe.t) : hook_call =
  match j with
  | `List (`String "event_stats_cb" :: `String prop :: `Int inc :: _) ->
      Event_stats_cb (prop, inc)
  | `List (`String "score_event_cb" :: `String init_hex :: `Int scored_at :: `String action :: `Int increment :: _) -> (
      match Hex_util.decode_opt init_hex with
      | Some initiator -> Score_event_cb { initiator; scored_at; action; increment }
      | None -> Other [])
  | `List (`String "notifications_cb" :: `Int ntype :: args) -> Notifications_cb (ntype, args)
  | `List args -> Other args
  | _ -> Other []

(* event_hook_execute: Julia evals the funcall against the *event* whose hooks fired, so the
   executor receives the full parent event (needed by score_event_cb for content/pubkey). *)
let apply_hook (est : est) (e : Nostr.t) = function
  | Event_stats_cb (prop, inc) ->
      if lean_stats est then stats_add est ~target:e e.id (fun d -> add_prop d prop inc)
      else incr_event_stat est e.id prop inc
  | Score_event_cb { initiator; scored_at; action; increment } ->
      (!ext).score_event_cb est e initiator scored_at action increment
  | Notifications_cb (ntype, args) -> (!ext).notifications_cb est e ntype args
  | Other _ -> () (* unknown deferred funcall: ignore (Julia would error; we drop it) *)

let event_hook (est : est) (eid : string) (call : hook_call) : unit =
  if est.cfg.lean.enabled then begin
    (* one read instead of exists + read (and none for the event in hand: scope memo) *)
    match get_event est eid with
    | Some e -> apply_hook est e call
    | None ->
        let dbh = est.dbh in
        let event_id = eid and funcall = Yojson.Safe.to_string (hook_to_json call) in
        ignore [%pgsql dbh "insert into event_hooks (event_id, funcall) values ($event_id, $funcall)"]
  end
  else if already_imported_id est eid then
    (* Julia: eid in est.events -> event_hook_execute(est, est.events[eid], funcall) *)
    (match get_event est eid with Some e -> apply_hook est e call | None -> ())
  else begin
    let dbh = est.dbh in
    let event_id = eid and funcall = Yojson.Safe.to_string (hook_to_json call) in
    ignore [%pgsql dbh "insert into event_hooks (event_id, funcall) values ($event_id, $funcall)"]
  end

let fire_event_hooks (est : est) (e : Nostr.t) : unit =
  let dbh = est.dbh in
  let id = e.id in
  if est.cfg.lean.enabled then
    (* one statement: claim and remove the pending hooks together *)
    List.iter
      (fun funcall -> apply_hook est e (hook_of_json (Yojson.Safe.from_string funcall)))
      [%pgsql dbh "delete from event_hooks where event_id = $id returning funcall"]
  else begin
  let rows = [%pgsql dbh "select funcall from event_hooks where event_id = $id"] in
  List.iter
    (fun funcall -> apply_hook est e (hook_of_json (Yojson.Safe.from_string funcall)))
    rows;
  ignore [%pgsql dbh "delete from event_hooks where event_id = $id"]
  end

(* Lean (enabled): pending hooks wait for an event that may never arrive; delete those older than
   [days], in bounded batches (event_hooks.created_at; an index on it keeps each batch cheap).
   Called from the hooks loop. Returns the number deleted. *)
let expire_event_hooks ?(batch = 20_000) ?(max_batches = 50) (est : est) ~(days : int) : int =
  let dbh = est.dbh in
  let cutoff = Unix.gettimeofday () -. (float_of_int days *. 86400.) in
  let n = Int64.of_int batch in
  let total = ref 0 in
  (try
     for _ = 1 to max_batches do
       let got =
         List.length
           [%pgsql dbh
             "delete from event_hooks where ctid in \
              (select ctid from event_hooks where created_at < to_timestamp($cutoff) limit $n) returning event_id"]
       in
       total := !total + got;
       if got < batch then raise Exit
     done
   with Exit -> ());
  !total

(* schedule_hook (Julia cache_storage.jl): defer a funcall to run after [execute_at]. A past-due
   hook is dropped (Julia ran it at once); the others are persisted in scheduled_hooks, which
   [run_scheduled_hooks] fires. *)
let schedule_hook (est : est) ~(execute_at : int) (funcall : Yojson.Safe.t) : unit =
  if execute_at <= Utils.current_time () then ()
  else begin
    let dbh = est.dbh in
    let execute_at = i64 execute_at and funcall = Yojson.Safe.to_string funcall in
    ignore [%pgsql dbh "insert into scheduled_hooks (execute_at, funcall) values ($execute_at, $funcall)"]
  end

(* scheduled_hook_execute / run_scheduled_hooks (Julia cache_storage.jl:690,1810): fire all
   due scheduled hooks and delete them. Currently the only scheduled hook is
   expire_hashtag_score_cb (routed through the ext registry). Driven by a periodic fiber in
   bin/main.ml. *)
let scheduled_hook_execute (est : est) (j : Yojson.Safe.t) : unit =
  match j with
  | `List (`String "expire_hashtag_score_cb" :: `String hashtag :: `Int d :: _) ->
      (!ext).expire_hashtag_score_cb est hashtag d
  | _ -> ()

(* Rows claimed per round. The original select-all/execute-all/delete-all shape wedged the runner
   permanently once the backlog grew (2026-08-04: 4.3M due rows, one invocation running for 69h
   and never reaching the DELETE, so no progress was ever committed and every restart redid the
   same work from scratch — while its 4.3M single-row UPDATEs saturated Postgres and starved the
   import workers). Claiming a bounded batch with DELETE .. RETURNING makes each batch's progress
   durable, so the runner always converges. *)
let scheduled_hooks_batch = 20_000

(* Atomically claim up to [n] due hooks: the DELETE both removes and yields them, so a crash
   mid-batch loses at most one batch instead of replaying the whole backlog. ctid keeps the
   delete to exactly the rows the inner ordered/limited scan picked. *)
let claim_scheduled_hooks (est : est) ~(now : int64) ~(n : int64) : string list =
  let dbh = est.dbh in
  [%pgsql dbh
    "delete from scheduled_hooks where ctid in \
     (select ctid from scheduled_hooks where execute_at <= $now order by execute_at limit $n) \
     returning funcall"]

(* Run one claimed batch. expire_hashtag_score_cb decrements are folded per hashtag first: a
   batch is dominated by a few hot tags (the tag 'the' alone accounted for 80k of the 4.3M
   backlog), so
   summing the deltas turns tens of thousands of UPDATEs into one per distinct hashtag. *)
let run_scheduled_hooks_batch (est : est) (funcalls : string list) : unit =
  let hashtag_deltas : (string, int) Hashtbl.t = Hashtbl.create 4096 in
  let others = ref [] in
  List.iter
    (fun s ->
      match Yojson.Safe.from_string s with
      | `List (`String "expire_hashtag_score_cb" :: `String hashtag :: `Int d :: _) ->
          let prev = Option.value ~default:0 (Hashtbl.find_opt hashtag_deltas hashtag) in
          Hashtbl.replace hashtag_deltas hashtag (prev + d)
      | j -> others := j :: !others
      | exception _ -> ())
    funcalls;
  Hashtbl.iter (fun hashtag d -> (!ext).expire_hashtag_score_cb est hashtag d) hashtag_deltas;
  List.iter (fun j -> scheduled_hook_execute est j) (List.rev !others)

(* Drain the due backlog in batches. [max_batches] bounds one invocation so the caller's fiber
   comes back periodically (and its stats slot goes idle) even with millions of rows pending;
   the periodic runner simply picks up where this left off. Returns the number of hooks run. *)
let run_scheduled_hooks ?(max_batches = 50) (est : est) : int =
  let now = i64 (Utils.current_time ()) in
  let n = Int64.of_int scheduled_hooks_batch in
  let total = ref 0 in
  (try
     for _ = 1 to max_batches do
       let due = claim_scheduled_hooks est ~now ~n in
       let got = List.length due in
       if got = 0 then raise Exit;
       run_scheduled_hooks_batch est due;
       total := !total + got;
       if got < scheduled_hooks_batch then raise Exit
     done
   with Exit -> ());
  !total

(* {1 event_pubkey_actions} (Julia init_event_pubkey_action / event_pubkey_action) *)

let init_event_pubkey_action (est : est) ~(eid : string) ~(re : Nostr.t) : unit =
  let dbh = est.dbh in
  let event_id = eid and pubkey = re.pubkey and created_at = i64 re.created_at in
  ignore
    [%pgsql
      dbh
        "insert into event_pubkey_actions_1_d62afee35d (event_id, pubkey, created_at, updated_at, \
         replied, liked, reposted, zapped) values ($event_id, $pubkey, $created_at, 0, 0, \
         0, 0, 0) on conflict (event_id, pubkey) do nothing"]

let event_pubkey_action (est : est) ~(eid : string) ~(re : Nostr.t) ~(action : string) : unit =
  init_event_pubkey_action est ~eid ~re;
  let dbh = est.dbh in
  let event_id = eid and pubkey = re.pubkey and updated_at = i64 re.created_at in
  (match action with
  | "replied" -> ignore [%pgsql dbh "update event_pubkey_actions_1_d62afee35d set replied = 1, updated_at = $updated_at where event_id = $event_id and pubkey = $pubkey"]
  | "liked" -> ignore [%pgsql dbh "update event_pubkey_actions_1_d62afee35d set liked = 1, updated_at = $updated_at where event_id = $event_id and pubkey = $pubkey"]
  | "reposted" -> ignore [%pgsql dbh "update event_pubkey_actions_1_d62afee35d set reposted = 1, updated_at = $updated_at where event_id = $event_id and pubkey = $pubkey"]
  | "zapped" -> ignore [%pgsql dbh "update event_pubkey_actions_1_d62afee35d set zapped = 1, updated_at = $updated_at where event_id = $event_id and pubkey = $pubkey"]
  | _ -> ());
  let event_id = eid and ref_event_id = re.id and ref_pubkey = re.pubkey in
  let ref_created_at = i64 re.created_at and ref_kind = i64 re.kind in
  ignore
    [%pgsql
      dbh
        "insert into event_pubkey_action_refs_1_f32e1ff589 (event_id, ref_event_id, ref_pubkey, \
         ref_created_at, ref_kind) values ($event_id, $ref_event_id, $ref_pubkey, \
         $ref_created_at, $ref_kind)"]

(* {1 Zap helpers} (Julia zap_sender / parse_bolt11) *)

let zap_sender (e : Nostr.t) : string option =
  List.find_map
    (fun tg ->
      match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
      | Some "description", Some desc -> (
          try
            let j = Yojson.Safe.from_string desc in
            decode32 (Yojson.Safe.Util.(j |> member "pubkey" |> to_string))
          with _ -> None)
      | _ -> None)
    e.tags

let parse_bolt11 (b : string) : int option =
  if starts_with b "lnbc" then begin
    let n = String.length b in
    let buf = Buffer.create 16 in
    let unit = ref None in
    (try
       for i = 4 to n - 1 do
         let c = b.[i] in
         if c >= '0' && c <= '9' then Buffer.add_char buf c
         else begin unit := Some c; raise Exit end
       done
     with Exit -> ());
    match int_of_string_opt (Buffer.contents buf) with
    | None -> None
    | Some amount ->
        let amount = amount * 100_000_000 in
        Some
          (match !unit with
          | Some 'm' -> amount / 1_000
          | Some 'u' -> amount / 1_000_000
          | Some 'n' -> amount / 1_000_000_000
          | Some 'p' -> amount / 1_000_000_000_000
          | _ -> amount)
  end
  else None

(* {1 Parametrized replaceable lookup / parent eid} (Julia lookup_* / parse_parent_eid) *)

let lookup_parametrized_replaceable_event (est : est) ~kind ~pubkey ~identifier : string option =
  let q () =
    let dbh = est.dbh in
    let k = i64 kind in
    match
      [%pgsql dbh "select event_id from parametrized_replaceable_events_1_cbe75c8d53 where pubkey = $pubkey and kind = $k and identifier = $identifier limit 1"]
    with
    | x :: _ -> Some x
    | [] -> None
  in
  (* lean: an event's mentions/parents are resolved several times per import; once is enough *)
  match current_scope () with
  | Some s -> (
      let key = (kind, pubkey, identifier) in
      match Hashtbl.find_opt s.pre key with
      | Some r -> r
      | None ->
          let r = q () in
          Hashtbl.replace s.pre key r;
          r)
  | None -> q ()

(* Julia parse_eid (inner of parse_parent_eid): requires >= 4 fields. *)
let parse_eid_of_tag (est : est) (tg : Nostr.tag) : string option =
  if Nostr.tag_len tg < 4 then None
  else
    match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
    | Some "e", Some h -> decode32 h
    | Some "a", Some s -> (
        match parse_a_tag s with
        | Some (kind, pubkey, identifier) ->
            lookup_parametrized_replaceable_event est ~kind ~pubkey ~identifier
        | None -> None)
    | _ -> None

let rec parse_parent_eid (est : est) (e : Nostr.t) : string option =
  match current_scope () with
  | Some s -> (
      match Hashtbl.find_opt s.parents e.id with
      | Some r -> r
      | None ->
          let r = parse_parent_eid_uncached est e in
          Hashtbl.replace s.parents e.id r;
          r)
  | None -> parse_parent_eid_uncached est e

and parse_parent_eid_uncached (est : est) (e : Nostr.t) : string option =
  let last_with f =
    List.fold_left
      (fun acc tg -> if f tg then match parse_eid_of_tag est tg with Some _ as r -> r | None -> acc else acc)
      None e.tags
  in
  let by_marker m = last_with (fun tg -> Nostr.tag_len tg >= 4 && Nostr.tag_field tg 3 = Some m) in
  match by_marker "reply" with
  | Some _ as r -> r
  | None -> (
      (* root: first match wins *)
      let first_root =
        List.fold_left
          (fun acc tg ->
            match acc with
            | Some _ -> acc
            | None ->
                if Nostr.tag_len tg >= 4 && Nostr.tag_field tg 3 = Some "root" then
                  parse_eid_of_tag est tg
                else None)
          None e.tags
      in
      match first_root with
      | Some _ as r -> r
      | None ->
          last_with (fun tg ->
              (match Nostr.tag_name tg with Some ("e" | "a") -> true | _ -> false)
              && (Nostr.tag_len tg < 4 || Nostr.tag_field tg 3 <> Some "mention")))

(* {1 Core storage operations} *)

(* Atomically claim and store the event. Returns true iff THIS call inserted the row, i.e. we own
   the event and must run its side effects; false if it already existed (another worker domain or
   an earlier delivery owns it), in which case the caller must NOT dispatch.

   This is the OCaml stand-in for Julia's already_imported_check_lock (cache_storage.jl:1062): the
   existence check and the claim are a single atomic DB op, so two concurrent worker domains
   processing the same event cannot both dispatch it — which would double-count likes/reposts/zaps
   and duplicate event_pubkey_action_refs. The id is the event's content hash, so a conflicting row
   is byte-identical and needs no update (do nothing). *)
let store_event (est : est) (e : Nostr.t) : bool =
  let dbh = est.dbh in
  let id = e.id and pubkey = e.pubkey and sig_ = e.sig_ and content = e.content in
  let created_at = i64 e.created_at and kind = i64 e.kind in
  let imported_at = i64 (Utils.current_time ()) in
  let tags = Yojson.Safe.to_string (`List (List.map (fun (t : Nostr.tag) -> `List t) e.tags)) in
  match
    [%pgsql
      dbh
        "insert into event (id, pubkey, created_at, kind, tags, content, sig, \
         imported_at) values ($id, $pubkey, $created_at, $kind, $tags, $content, $sig_, \
         $imported_at) on conflict (id) do nothing returning id"]
  with
  | [] -> false
  | _ -> true

let set_event_created_at (est : est) (e : Nostr.t) : unit =
  let dbh = est.dbh in
  let event_id = e.id and created_at = i64 e.created_at in
  ignore
    [%pgsql dbh "insert into event_created_at_1_7a51e16c5c (event_id, created_at) values ($event_id, $created_at) on conflict (event_id) do update set created_at = excluded.created_at"]

let pubkey_known (est : est) (pubkey : string) : bool =
  let dbh = est.dbh in
  match [%pgsql dbh "select 1 from pubkey_ids_1_54b55dd09c where key = $pubkey limit 1"] with
  | [] -> false
  | _ -> true

(* Julia get(est.pubkey_followers_cnt, pubkey, 0). *)
let pubkey_followers_cnt (est : est) (pubkey : string) : int =
  let dbh = est.dbh in
  match [%pgsql dbh "select value from pubkey_followers_cnt_1_a6f7e200e7 where key = $pubkey"] with
  | v :: _ -> Int64.to_int v
  | [] -> 0

let track_pubkey (est : est) (pubkey : string) : unit =
  if not (pubkey_known est pubkey) then begin
    let dbh = est.dbh in
    (* pubkey_ids is a DBSet in Julia (PGDict{_,Bool}); push! stores value = Int(true) = 1 into
       the bigint value column (db.jl push!/setindex!, psql2.jl:114). The reference schema had
       value boolean; live primal1 has value bigint, so write the integer, not a boolean. *)
    ignore [%pgsql dbh "insert into pubkey_ids_1_54b55dd09c (key, value) values ($pubkey, 1) on conflict (key) do nothing"];
    ignore [%pgsql dbh "insert into pubkey_followers_cnt_1_a6f7e200e7 (key, value) values ($pubkey, 0) on conflict (key) do nothing"];
    if est.cfg.disable_trustrank then begin
      let rank = 1.0 in
      ignore [%pgsql dbh "insert into pubkey_trustrank (pubkey, rank) values ($pubkey, $rank) on conflict (pubkey) do nothing"]
    end;
    (!ext).ext_pubkey est pubkey
  end

(* Lean variant of [track_pubkey]. What a new pubkey triggers: the pubkey_ids row, the zero rows of
   pubkey_followers_cnt and (ext_pubkey) pubkey_zapped, and with disable_trustrank a rank-1.0 row.
   - lazy_counters: no zero rows;
   - no_pubkey_ids: no pubkey_ids; without lazy_counters the follower-count seed itself (insert ..
     on conflict do nothing returning) tells whether the pubkey is new; with lazy_counters nothing
     needs "new pubkey" but the disable_trustrank seed, which is idempotent anyway. *)
let track_pubkey_lean (est : est) (pubkey : string) : unit =
  let l = est.cfg.lean in
  let dbh = est.dbh in
  let seed_trustrank () =
    if est.cfg.disable_trustrank then begin
      let rank = 1.0 in
      ignore [%pgsql dbh "insert into pubkey_trustrank (pubkey, rank) values ($pubkey, $rank) on conflict (pubkey) do nothing"]
    end
  in
  if not l.no_pubkey_ids then begin
    if not (pubkey_known est pubkey) then begin
      ignore [%pgsql dbh "insert into pubkey_ids_1_54b55dd09c (key, value) values ($pubkey, 1) on conflict (key) do nothing"];
      if not l.lazy_counters then
        ignore [%pgsql dbh "insert into pubkey_followers_cnt_1_a6f7e200e7 (key, value) values ($pubkey, 0) on conflict (key) do nothing"];
      seed_trustrank ();
      if not l.lazy_counters then (!ext).ext_pubkey est pubkey
    end
  end
  else if not l.lazy_counters then begin
    match
      [%pgsql dbh "insert into pubkey_followers_cnt_1_a6f7e200e7 (key, value) values ($pubkey, 0) on conflict (key) do nothing returning key"]
    with
    | [] -> ()
    | _ ->
        seed_trustrank ();
        (!ext).ext_pubkey est pubkey
  end
  else seed_trustrank ()

let insert_pubkey_event ?kind (est : est) ~pubkey ~event_id ~created_at ~is_reply : unit =
  let dbh = est.dbh in
  match kind with
  | None ->
      ignore
        [%pgsql dbh "insert into pubkey_events_1_1dcbfe1466 (pubkey, event_id, created_at, is_reply) values ($pubkey, $event_id, $created_at, $is_reply)"]
  | Some kind ->
      (* lean.pubkey_events_kind (the column exists on lean hosts only) *)
      ignore
        [%pgsql dbh "insert into pubkey_events_1_1dcbfe1466 (pubkey, event_id, created_at, is_reply, kind) values ($pubkey, $event_id, $created_at, $is_reply, $kind)"]

let event_stats_init (est : est) (e : Nostr.t) : unit =
  let dbh = est.dbh in
  let event_id = e.id and author_pubkey = e.pubkey and created_at = i64 e.created_at in
  (* Plain insert, matching Julia's event_stats_insert_q (cache_storage.jl:1018) which has no ON
     CONFLICT: this runs exactly once per new event because import_event gates it behind the
     atomic store_event claim. Live primal1's event_stats is a view whose base table has no unique
     constraint on event_id, so an ON CONFLICT (event_id) arbiter has nothing to match (42P10). *)
  ignore
    [%pgsql
      dbh
        "insert into event_stats_1_1b380f4869 (event_id, author_pubkey, created_at, likes, replies, \
         mentions, reposts, zaps, satszapped, score, score24h) values ($event_id, \
         $author_pubkey, $created_at, 0, 0, 0, 0, 0, 0, 0, 0)"]

let insert_event_reply (est : est) ~parent ~reply ~reply_created_at : unit =
  let dbh = est.dbh in
  ignore
    [%pgsql dbh "insert into event_replies_1_9d033b5bb3 (event_id, reply_event_id, reply_created_at) values ($parent, $reply, $reply_created_at)"]

let set_event_thread_parent (est : est) ~event_id ~parent : unit =
  let dbh = est.dbh in
  ignore
    [%pgsql dbh "insert into event_thread_parents_1_e17bf16c98 (key, value) values ($event_id, $parent) on conflict (key) do update set value = excluded.value"]

(* {1 Replaceable / parametrized replaceable} (Julia 1399-1422) *)

let store_replaceable_event (est : est) (e : Nostr.t) : unit =
  let dbh = est.dbh in
  let pubkey = e.pubkey and kind = i64 e.kind and event_id = e.id in
  ignore
    [%pgsql dbh "insert into replaceable_events (pubkey, kind, event_id) values ($pubkey, $kind, $event_id) on conflict (pubkey, kind) do update set event_id = excluded.event_id"]

let first_d_tag (e : Nostr.t) : string option =
  List.find_map
    (fun tg -> match (Nostr.tag_name tg, Nostr.tag_field tg 1) with Some "d", Some d -> Some d | _ -> None)
    e.tags

let store_parametrized_replaceable_event (est : est) (e : Nostr.t) : unit =
  (* find the first d tag *)
  match first_d_tag e with
  | None -> ()
  | Some identifier ->
      let dbh = est.dbh in
      let pubkey = e.pubkey and kind = i64 e.kind and event_id = e.id and created_at = i64 e.created_at in
      ignore [%pgsql dbh "delete from parametrized_replaceable_events_1_cbe75c8d53 where pubkey = $pubkey and kind = $kind and identifier = $identifier"];
      ignore
        [%pgsql dbh "insert into parametrized_replaceable_events_1_cbe75c8d53 (pubkey, kind, identifier, event_id, created_at) values ($pubkey, $kind, $identifier, $event_id, $created_at)"]

(* {1 Lean: superseded versions} (lean.delete_superseded)

   The current version of a replaceable/addressable event is the one its pointer names: meta_data
   (kind 0), contact_lists (3), replaceable_events (10000-19999), parametrized_replaceable_events
   (30000-39999 with a d tag). Its created_at decides (NIP-01: greater created_at, or equal and the
   lower id): an older incoming version is deleted again and changes nothing, a newer one moves the
   pointers and then the previous version's row is deleted (not its derived rows), except for the
   kinds in keep_versions_kinds. *)
type version_check =
  | No_pointer (* no pointer for this event (3xxxx without d tag, regular kinds) *)
  | Newest of string option (* the previous version's id, if any *)
  | Older

let version_check (est : est) (e : Nostr.t) : version_check =
  let dbh = est.dbh and pubkey = e.pubkey and k = e.kind in
  let decide = function
    | [] -> Newest None
    | (old_id, _) :: _ when old_id = e.id -> Newest None
    | (old_id, old_created_at) :: _ ->
        if Lean.newer ~created_at:e.created_at ~id:e.id ~old_created_at:(Int64.to_int old_created_at) ~old_id then
          Newest (Some old_id)
        else Older
  in
  if k = Nostr.kind_set_metadata then
    decide
      [%pgsql dbh "select m.value, ev.created_at from meta_data_1_323bc43167 m, event ev where m.key = $pubkey and ev.id = m.value"]
  else if k = Nostr.kind_contact_list then
    decide
      [%pgsql dbh "select c.value, ev.created_at from contact_lists_1_1abdf474bd c, event ev where c.key = $pubkey and ev.id = c.value"]
  else if 10000 <= k && k < 20000 then
    let kind = i64 k in
    decide
      [%pgsql dbh "select r.event_id, ev.created_at from replaceable_events r, event ev where r.pubkey = $pubkey and r.kind = $kind and ev.id = r.event_id"]
  else if 30000 <= k && k < 40000 then
    match first_d_tag e with
    | None -> No_pointer
    | Some identifier ->
        let kind = i64 k in
        decide
          [%pgsql dbh "select event_id, created_at from parametrized_replaceable_events_1_cbe75c8d53 where pubkey = $pubkey and kind = $kind and identifier = $identifier limit 1"]
  else No_pointer

(* the pointer move of a newer addressable version when its predecessor's row is known: one
   UPDATE instead of DELETE + INSERT *)
let move_parametrized_replaceable_pointer (est : est) (e : Nostr.t) ~(exists : bool) : unit =
  match first_d_tag e with
  | None -> ()
  | Some identifier ->
      if not exists then store_parametrized_replaceable_event est e
      else begin
        let dbh = est.dbh in
        let pubkey = e.pubkey and kind = i64 e.kind and event_id = e.id and created_at = i64 e.created_at in
        ignore
          [%pgsql dbh "update parametrized_replaceable_events_1_cbe75c8d53 set event_id = $event_id, created_at = $created_at where pubkey = $pubkey and kind = $kind and identifier = $identifier"]
      end

let delete_superseded_row (est : est) (id : string) : unit =
  let dbh = est.dbh in
  ignore [%pgsql dbh "delete from event where id = $id"];
  memo_forget id;
  Lean.Superseded.add id;
  Atomic.incr Lean.superseded_deleted

(* {1 Replaceable single-event dict writes (meta_data, mute lists, contact_lists)} *)

let upsert_pubkey_event_id (est : est) ~(table : [ `Meta_data | `Contact_lists | `Mute_list | `Mute_list_2 | `Mute_lists | `Allow_list ]) ~key ~value : unit =
  let dbh = est.dbh in
  match table with
  | `Meta_data -> ignore [%pgsql dbh "insert into meta_data_1_323bc43167 (key, value) values ($key, $value) on conflict (key) do update set value = excluded.value"]
  | `Contact_lists -> ignore [%pgsql dbh "insert into contact_lists_1_1abdf474bd (key, value) values ($key, $value) on conflict (key) do update set value = excluded.value"]
  | `Mute_list -> ignore [%pgsql dbh "insert into mute_list_1_f693a878b9 (key, value) values ($key, $value) on conflict (key) do update set value = excluded.value"]
  | `Mute_list_2 -> ignore [%pgsql dbh "insert into mute_list_2_1_949b3d746b (key, value) values ($key, $value) on conflict (key) do update set value = excluded.value"]
  | `Mute_lists -> ignore [%pgsql dbh "insert into mute_lists_1_d90e559628 (key, value) values ($key, $value) on conflict (key) do update set value = excluded.value"]
  | `Allow_list -> ignore [%pgsql dbh "insert into allow_list_1_f1da08e9c8 (key, value) values ($key, $value) on conflict (key) do update set value = excluded.value"]

let meta_data_should_update (est : est) ~pubkey ~created_at : bool =
  let dbh = est.dbh in
  let key = pubkey in
  match [%pgsql dbh "select e.created_at from meta_data_1_323bc43167 m, event e where m.key = $key and e.id = m.value"] with
  | [] -> true
  | old :: _ -> i64 created_at > old

let contact_list_should_update (est : est) ~pubkey ~created_at : bool =
  let dbh = est.dbh in
  let key = pubkey in
  match [%pgsql dbh "select e.created_at from contact_lists_1_1abdf474bd c, event e where c.key = $key and e.id = c.value"] with
  | [] -> true
  | old :: _ -> i64 created_at > old

(* Julia update_pubkey_ln_address: parse lud16 out of the pubkey's current metadata event. *)
let get_meta_data_event (est : est) (pubkey : string) : Nostr.t option =
  let dbh = est.dbh in
  match [%pgsql dbh "select value from meta_data_1_323bc43167 where key = $pubkey"] with
  | mid :: _ -> get_event est mid
  | [] -> None

let rec update_pubkey_ln_address (est : est) (pubkey : string) : unit =
  match get_meta_data_event est pubkey with
  | None -> ()
  | Some me -> update_pubkey_ln_address_from est pubkey me

(* [me] = the pubkey's current metadata event (lean: the kind 0 just imported, no re-read) *)
and update_pubkey_ln_address_from (est : est) (pubkey : string) (me : Nostr.t) : unit =
  match Yojson.Safe.from_string me.content with
  | `Assoc kv -> (
      match List.assoc_opt "lud16" kv with
      | Some (`String lud16) when lud16 <> "" ->
          let dbh = est.dbh in
          ignore
            [%pgsql dbh "insert into pubkey_ln_address_1_d3649b2898 (pubkey, ln_address) values ($pubkey, $lud16) on conflict (pubkey) do update set ln_address = excluded.ln_address"]
      | _ -> ())
  | _ -> ()
  | exception _ -> ()

(* {1 Contact list import} (Julia import_contact_list) *)

let contact_list_follows (e : Nostr.t) : string list =
  List.filter_map
    (fun tg -> match (Nostr.tag_name tg, Nostr.tag_field tg 1) with Some "p", Some h -> decode32 h | _ -> None)
    e.tags

let get_contact_list_event (est : est) (pubkey : string) : Nostr.t option =
  let dbh = est.dbh in
  match [%pgsql dbh "select value from contact_lists_1_1abdf474bd where key = $pubkey"] with
  | clid :: _ -> get_event est clid
  | [] -> None

module SS = Set.Make (String)

let rec import_contact_list (est : est) (e : Nostr.t) : unit =
  let old_follows =
    match get_contact_list_event est e.pubkey with Some old_e -> contact_list_follows old_e | None -> []
  in
  import_contact_list_diff est e ~old_follows

(* Lean (enabled): one read of the previous contact list (its id, created_at and tags) serves both
   the "is it newer" check and the follow diff (the classic path reads it three times). *)
and import_contact_list_lean (est : est) (e : Nostr.t) ~(newer_known : bool) : unit =
  let dbh = est.dbh and key = e.pubkey in
  let old = [%pgsql dbh "select ev.created_at, ev.tags from contact_lists_1_1abdf474bd c, event ev where c.key = $key and ev.id = c.value"] in
  let newer = newer_known || (match old with [] -> true | (oc, _) :: _ -> i64 e.created_at > oc) in
  if newer then begin
    let old_follows =
      match old with (_, tags) :: _ -> contact_list_follows { e with tags = parse_tags_json tags } | [] -> []
    in
    import_contact_list_diff est e ~old_follows
  end

and import_contact_list_diff (est : est) (e : Nostr.t) ~(old_follows : string list) : unit =
  let dbh = est.dbh in
  upsert_pubkey_event_id est ~table:`Contact_lists ~key:e.pubkey ~value:e.id;
  let news = SS.of_list (contact_list_follows e) and olds = SS.of_list old_follows in
  let trusted = is_trusted_user est e.pubkey in
  SS.iter
    (fun follow_pubkey ->
      if not (SS.mem follow_pubkey olds) then begin
        let follower_pubkey = e.pubkey and follower_contact_list_event_id = e.id in
        ignore [%pgsql dbh "insert into pubkey_followers_1_d52305fb47 (pubkey, follower_pubkey, follower_contact_list_event_id) values ($follow_pubkey, $follower_pubkey, $follower_contact_list_event_id)"];
        if trusted then begin
          if est.cfg.lean.lazy_counters then
            (* lean: the first follower creates the row (no zero row per pubkey) *)
            ignore [%pgsql dbh "insert into pubkey_followers_cnt_1_a6f7e200e7 (key, value) values ($follow_pubkey, 1) on conflict (key) do update set value = pubkey_followers_cnt_1_a6f7e200e7.value + 1"]
          else
          ignore [%pgsql dbh "update pubkey_followers_cnt_1_a6f7e200e7 set value = value + 1 where key = $follow_pubkey"];
          (!ext).notification est follow_pubkey e.created_at Notif.new_user_followed_you [ Apk e.pubkey ]
        end
      end)
    news;
  SS.iter
    (fun follow_pubkey ->
      if not (SS.mem follow_pubkey news) then begin
        let follower_pubkey = e.pubkey in
        ignore [%pgsql dbh "delete from pubkey_followers_1_d52305fb47 where pubkey = $follow_pubkey and follower_pubkey = $follower_pubkey"];
        if trusted then begin
          ignore [%pgsql dbh "update pubkey_followers_cnt_1_a6f7e200e7 set value = greatest(0, value - 1) where key = $follow_pubkey"];
          (* notification() drops USER_UNFOLLOWED_YOU (cache_storage_ext.jl:630); kept for fidelity. *)
          (!ext).notification est follow_pubkey e.created_at Notif.user_unfollowed_you [ Apk e.pubkey ]
        end
      end)
    olds

(* {1 Direct messages} (Julia import_directmsg) *)

let import_directmsg (est : est) (e : Nostr.t) : unit =
  match
    List.find_map
      (fun tg -> match (Nostr.tag_name tg, Nostr.tag_field tg 1) with Some "p", Some h -> decode32 h | _ -> None)
      e.tags
  with
  | Some _ when ext_is_hidden_pubkey est e.pubkey -> () (* Julia: ext_is_hidden(sender) -> skip *)
  | None -> ()
  | Some receiver ->
      (* App.is_hidden(receiver, :content, sender) is an App-layer per-user check — out of scope;
         the ext_is_hidden(sender) part above is honoured via the filterlist. *)
      let dbh = est.dbh in
      let sender = e.pubkey and created_at = i64 e.created_at and event_id = e.id in
      let exists =
        (* lean: the event claim already makes this insert once-only *)
        if est.cfg.lean.enabled then false
        else
        match [%pgsql dbh "select 1 from pubkey_directmsgs_1_c794110a2c where receiver = $receiver and event_id = $event_id limit 1"] with
        | [] -> false
        | _ -> true
      in
      if not exists then
        ignore [%pgsql dbh "insert into pubkey_directmsgs_1_c794110a2c (receiver, sender, created_at, event_id) values ($receiver, $sender, $created_at, $event_id)"];
      (* pubkey_directmsgs_cnt: one row per (receiver, null) and (receiver, sender), kept with a
         single upsert over the unique index (receiver, sender) NULLS NOT DISTINCT. The former
         select-then-insert dance raced between workers (7,490 duplicate rows on the stage host by
         2026-10-06) and its multi-row updates then deadlocked, stalling every worker on one hot
         receiver during the backfill. *)
      let bump (sender : string option) =
        ignore
          [%pgsql dbh
            "insert into pubkey_directmsgs_cnt_1_efdf9742a6 (receiver, sender, cnt, latest_at, latest_event_id) \
             values ($receiver, $?sender, 1, $created_at, $event_id) \
             on conflict (receiver, sender) do update set cnt = pubkey_directmsgs_cnt_1_efdf9742a6.cnt + 1, \
               latest_at = greatest(pubkey_directmsgs_cnt_1_efdf9742a6.latest_at, excluded.latest_at), \
               latest_event_id = case when excluded.latest_at >= pubkey_directmsgs_cnt_1_efdf9742a6.latest_at then excluded.latest_event_id else pubkey_directmsgs_cnt_1_efdf9742a6.latest_event_id end"]
      in
      bump None;
      bump (Some sender)

(* {1 Deletions} (Julia import_delete_event; reads cleanup deferred to ext) *)

let import_delete_event (est : est) (e : Nostr.t) : unit =
  let dbh = est.dbh in
  let delete_event eid =
    let deletion_event_id = e.id in
    ignore [%pgsql dbh "insert into deleted_events_1_0249f47b16 (event_id, deletion_event_id) values ($eid, $deletion_event_id) on conflict (event_id) do update set deletion_event_id = excluded.deletion_event_id"];
    ignore [%pgsql dbh "delete from event where id = $eid"];
    memo_forget eid
  in
  (* lean: the author check needs pubkey and kind only; the tags only for a repost *)
  let get_deleted eid =
    if est.cfg.lean.enabled then
      match get_event_meta est eid with
      | Some (_, _, kind) when kind = Nostr.kind_repost -> get_event est eid
      | Some (pubkey, created_at, kind) -> Some { Nostr.id = eid; pubkey; created_at; kind; tags = []; content = ""; sig_ = "" }
      | None -> None
    else get_event est eid
  in
  List.iter
    (fun tg ->
      match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
      | Some "e", Some h -> (
          match decode32 h with
          | None -> ()
          | Some eid -> (
              (* only delete if it belongs to the same author *)
              match get_deleted eid with
              | Some de when de.pubkey = e.pubkey ->
                  delete_event eid;
                  if de.kind = Nostr.kind_repost then
                    List.iter
                      (fun tg2 ->
                        match (Nostr.tag_name tg2, Nostr.tag_field tg2 1) with
                        | Some "e", Some h2 -> (
                            match decode32 h2 with
                            | None -> ()
                            | Some reid ->
                                let depk = de.pubkey and deid = de.id in
                                ignore [%pgsql dbh "update event_pubkey_actions_1_d62afee35d set reposted = 0 where event_id = $reid and pubkey = $depk"];
                                ignore [%pgsql dbh "delete from event_pubkey_action_refs_1_f32e1ff589 where ref_event_id = $deid and ref_pubkey = $depk"];
                                if lean_stats est then stats_add est reid (fun d -> d.reposts <- d.reposts - 1)
                                else
                                ignore [%pgsql dbh "update event_stats_1_1b380f4869 set reposts = reposts - 1 where event_id = $reid"])
                        | _ -> ())
                      de.tags
              | _ -> ()))
      | Some "a", Some s -> (
          match parse_a_tag s with
          | None -> ()
          (* only the author may delete their addressable events *)
          | Some (_, pk, _) when pk <> e.pubkey -> ()
          | Some (kind, pk, identifier) ->
              let k = i64 kind in
              (match [%pgsql dbh "select event_id from parametrized_replaceable_events_1_cbe75c8d53 where pubkey = $pk and kind = $k and identifier = $identifier limit 1"] with
               | eid :: _ -> delete_event eid
               | [] -> ());
              ignore [%pgsql dbh "delete from parametrized_replaceable_events_1_cbe75c8d53 where pubkey = $pk and kind = $k and identifier = $identifier"];
              (* long-form: also drop the serving-layer reads / reads_versions rows *)
              if kind = Nostr.kind_long_form_content then begin
                List.iter (fun reid -> delete_event reid)
                  [%pgsql dbh "select eid from reads_versions_12_b537d4df66 where pubkey = $pk and identifier = $identifier"];
                ignore [%pgsql dbh "delete from reads_12_68c6bbfccd where pubkey = $pk and identifier = $identifier"];
                ignore [%pgsql dbh "delete from reads_versions_12_b537d4df66 where pubkey = $pk and identifier = $identifier"]
              end)
      | _ -> ())
    e.tags

(* {1 Per-kind dispatch} (Julia import_event 1159-1396) *)

let like_content c =
  c = ""
  || (String.length c >= 1 && c.[0] = '+')
  || starts_with c "\xF0\x9F\xA4\x99" (* call-me-hand *)
  || starts_with c "\xE2\x9D\xA4" (* heart *)
  || starts_with c "\xEF\xB8\x8F" (* variation selector *)

let handle_note_reply (est : est) (e : Nostr.t) : unit =
  (!ext).ext_text_note est e;
  (match parse_parent_eid est e with
  | Some parent ->
      if (not (ext_is_hidden_event est e.id)) && is_trusted_user est e.pubkey then
        event_hook est parent (Event_stats_cb ("replies", 1));
      insert_event_reply est ~parent ~reply:e.id ~reply_created_at:(i64 e.created_at);
      event_pubkey_action est ~eid:parent ~re:e ~action:"replied";
      if not est.cfg.lean.no_thread_parents then set_event_thread_parent est ~event_id:e.id ~parent;
      (!ext).ext_reply est e parent
  | None -> ());
  (!ext).import_reply_notifications est e
  (* Julia's fetch_missing_events (a relay fetcher) is not done by the importer. *)

let handle_reaction (est : est) (e : Nostr.t) : unit =
  List.iter
    (fun tg ->
      match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
      | Some "e", Some h -> (
          match decode32 h with
          | None -> ()
          | Some eid ->
              if like_content e.content then begin
                if not (ext_is_hidden_event est e.id) then
                  event_hook est eid (Event_stats_cb ("likes", 1));
                event_pubkey_action est ~eid ~re:e ~action:"liked";
                (!ext).ext_reaction est e eid
              end;
              (* Julia fires the YOUR_POST_WAS_LIKED hook for every reacted-to event, regardless
                 of like_content (cache_storage.jl:1193); args: (reaction event id, content). *)
              event_hook est eid
                (Notifications_cb
                   (Notif.your_post_was_liked,
                    [ `String (Hex_util.encode e.id); `String e.content ])))
      | _ -> ())
    e.tags
  (* fetch_missing_events: gated by auto_fetch_missing_events (default off in Julia) and needs a
     relay fetcher (out of importer scope) — faithful no-op. *)

let handle_repost (est : est) (e : Nostr.t) : unit =
  let rec first_e = function
    | [] -> ()
    | tg :: rest -> (
        match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
        | Some "e", Some h -> (
            match decode32 h with
            | None -> first_e rest
            | Some eid ->
                if not (ext_is_hidden_event est e.id) then
                  event_hook est eid (Event_stats_cb ("reposts", 1));
                event_pubkey_action est ~eid ~re:e ~action:"reposted";
                (!ext).ext_repost est e eid)
        | _ -> first_e rest)
  in
  first_e e.tags
  (* fetch_missing_events: gated by auto_fetch_missing_events (default off in Julia) and needs a
     relay fetcher (out of importer scope) — faithful no-op. *)

(* A zap receipt that passed the cheap gates (positive amount, description, 'p' tag), plus
   everything needed to apply its import effects once the zapper is verified. *)
type zap_job = {
  zj_receipt : Nostr.t;
  zj_parent_eid : string option;
  zj_zapped_pk : string;
  zj_amount_sats : int;
}

(* {1 Lean: the event transaction runner} (lean.transaction_per_event)

   [f] (an event's side effects, after its claim committed) runs between BEGIN and COMMIT on
   [est.dbh]. A deadlock or serialization failure rolls back and retries the whole of [f] (up to
   [tx_max_attempts], with a random pause). Any other error rolls back and runs [f] once more
   without a transaction: the classic autocommit path, so a statement that always fails costs what
   it costs today (the rest still applies) instead of dropping the event's effects. Before COMMIT a
   probe statement checks the transaction is still alive: a failed statement whose error was
   swallowed somewhere would otherwise turn the COMMIT into a silent ROLLBACK. Work queued with
   [after_commit] runs once the commit succeeded. Connection errors and cancellation propagate (the
   worker reconnects). Nested calls just run [f]. *)
let tx_max_attempts = 4

let run_event_tx (est : est) (f : unit -> unit) : unit =
  let st = Domain.DLS.get tx_key in
  if st.tx_dbh <> None then f ()
  else begin
    let reset () =
      st.tx_dbh <- None;
      st.post_commit <- []
    in
    let rec attempt n =
      let dbh = est.dbh in
      match
        PGOCaml.begin_work dbh;
        st.tx_dbh <- Some dbh;
        st.post_commit <- [];
        f ();
        ignore [%pgsql dbh "select 1"];
        PGOCaml.commit dbh
      with
      | () ->
          let post = List.rev st.post_commit in
          reset ();
          List.iter
            (fun g ->
              try g () with
              | Eio.Cancel.Cancelled _ as ex -> raise ex
              | exn -> Printf.eprintf "import_event: after commit: %s\n%!" (Printexc.to_string exn))
            post
      | exception (Eio.Cancel.Cancelled _ as ex) ->
          reset ();
          (try PGOCaml.rollback dbh with _ -> ());
          raise ex
      | exception ex when Postgres.is_connection_error ex ->
          reset ();
          raise ex
      | exception ex ->
          reset ();
          (try PGOCaml.rollback dbh with _ -> ());
          if is_retryable_tx_error ex && n < tx_max_attempts then begin
            Atomic.incr Lean.tx_retries;
            Eio_unix.sleep (0.005 +. Random.float (0.02 *. float_of_int n));
            attempt (n + 1)
          end
          else begin
            Atomic.incr Lean.tx_fallbacks;
            Printf.eprintf "import_event: transaction abandoned after %d attempt(s) (%s); applying without one\n%!" n
              (Printexc.to_string ex);
            f ()
          end
    in
    attempt 1
  end

(* The zap receipt's import side effects (event/pubkey zap stats, actions, ext hooks). Runs
   inline when no verification is needed, or later on a Zap_verifier domain (with that domain's
   own est) once the LNURL endpoint confirms the zapper. *)
let rec apply_zap_effects (est : est) (j : zap_job) : unit =
  let l = est.cfg.lean in
  if (l.enabled || l.transaction_per_event) && current_scope () = None && not (in_event_tx ()) then begin
    (* lean: a verified zap applied later is its own little event: scope and transaction *)
    let run () = with_scope est j.zj_receipt (fun () -> apply_zap_effects_now est j) in
    if l.transaction_per_event then run_event_tx est run else run ()
  end
  else apply_zap_effects_now est j

and apply_zap_effects_now (est : est) (j : zap_job) : unit =
  let e = j.zj_receipt in
  (match j.zj_parent_eid with
  | Some parent ->
      event_hook est parent (Event_stats_cb ("zaps", 1));
      (match zap_sender e with
      | Some sender ->
          event_pubkey_action est ~eid:parent ~re:{ e with pubkey = sender } ~action:"zapped"
      | None -> ());
      (!ext).ext_zap est e parent j.zj_amount_sats
  | None -> ());
  (!ext).ext_pubkey_zap est e j.zj_zapped_pk j.zj_amount_sats

(* When wired (bin/main.ml -> Zap_verifier), zap receipts needing LNURL verification are handed
   off here — the import worker moves on immediately and the verifier pool fetches the endpoint
   and applies the effects. Unwired (dev tools), verification falls back to the synchronous
   [zapper_verifier]. *)
let zap_verifier_submit : (zap_job -> unit) option ref = ref None
let set_zap_verifier_submit f = zap_verifier_submit := Some f

let handle_zap_receipt (est : est) (e : Nostr.t) : unit =
  (* ws-importer's zap_receipt_invoices row (invoice text per receipt), independent of zapper
     verification. *)
  (!ext).ext_zap_receipt_invoice est e;
  let parent_eid = ref None and zapped_pk = ref None in
  let amount_sats = ref 0 and has_description = ref false in
  List.iter
    (fun tg ->
      if Nostr.tag_len tg >= 2 then
        match Nostr.tag_name tg with
        | Some "e" -> ( match Nostr.tag_field tg 1 with Some h -> parent_eid := decode32 h | None -> ())
        | Some "p" -> ( match Nostr.tag_field tg 1 with Some h -> zapped_pk := decode32 h | None -> ())
        | Some "bolt11" -> (
            match Nostr.tag_field tg 1 with
            | Some b -> ( match parse_bolt11 b with Some a when a <= max_satszapped -> amount_sats := a | _ -> ())
            | None -> ())
        | Some "description" -> has_description := true
        | _ -> ())
    e.tags;
  if !amount_sats > 0 && !has_description then
    match !zapped_pk with
    | None -> ()
    | Some zp ->
        let job =
          { zj_receipt = e; zj_parent_eid = !parent_eid; zj_zapped_pk = zp;
            zj_amount_sats = !amount_sats }
        in
        if (not est.cfg.verify_zappers) || List.mem e.pubkey est.cfg.trusted_zappers then
          apply_zap_effects est job
        else (
          match !zap_verifier_submit with
          | Some submit -> submit job
          | None ->
              if (!zapper_verifier) est ~zapped_pk:zp ~zap_receipt:e then
                apply_zap_effects est job)

let handle_categorized_people (est : est) (e : Nostr.t) : unit =
  let rec go = function
    | [] -> ()
    | tg :: rest -> (
        if Nostr.tag_len tg >= 2 && Nostr.tag_name tg = Some "d" then
          match Nostr.tag_field tg 1 with
          | Some "mute" ->
              upsert_pubkey_event_id est ~table:`Mute_list_2 ~key:e.pubkey ~value:e.id;
              (!ext).update_content_moderation_rules est e.pubkey
          | Some "mutelists" ->
              upsert_pubkey_event_id est ~table:`Mute_lists ~key:e.pubkey ~value:e.id;
              (!ext).update_content_moderation_rules est e.pubkey
          | Some "allowlist" ->
              upsert_pubkey_event_id est ~table:`Allow_list ~key:e.pubkey ~value:e.id;
              (!ext).update_content_moderation_rules est e.pubkey
          | Some identifier ->
              let dbh = est.dbh in
              let pubkey = e.pubkey and created_at = i64 e.created_at and event_id = e.id in
              ignore [%pgsql dbh "delete from parameterized_replaceable_list_1_d02d7ecc62 where pubkey = $pubkey and identifier = $identifier"];
              ignore [%pgsql dbh "insert into parameterized_replaceable_list_1_d02d7ecc62 (pubkey, identifier, created_at, event_id) values ($pubkey, $identifier, $created_at, $event_id)"]
          | None -> go rest
        else go rest)
  in
  go e.tags

(* {1 Relay list metadata / bookmarks} (Julia 1338-1353) *)

let store_relay_list_metadata ?(force = false) (est : est) (e : Nostr.t) : unit =
  let dbh = est.dbh in
  let pubkey = e.pubkey and event_id = e.id in
  let newer =
    force (* lean.delete_superseded: already decided against replaceable_events *)
    ||
    match
      [%pgsql dbh "select ev.created_at from relay_list_metadata_1_801a17fc93 r, event ev where r.pubkey = $pubkey and ev.id = r.event_id"]
    with
    | [] -> true
    | old :: _ -> i64 e.created_at > old
  in
  if newer then
    ignore
      [%pgsql dbh "insert into relay_list_metadata_1_801a17fc93 (pubkey, event_id) values ($pubkey, $event_id) on conflict (pubkey) do update set event_id = excluded.event_id"]

(* Julia App.get_user_relays: a user's relay URLs — from their kind-10002 relay list ('r' tags)
   or, failing that, the legacy relay map in their kind-3 contact-list content. *)
let user_relay_urls (est : est) (pubkey : string) : string list =
  let dbh = est.dbh in
  let from_relay_list =
    match
      (match [%pgsql dbh "select event_id from relay_list_metadata_1_801a17fc93 where pubkey = $pubkey"] with
       | eid :: _ -> get_event est eid
       | [] -> None)
    with
    | Some e ->
        List.filter_map
          (fun tg ->
            match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
            | Some "r", Some url when url <> "" -> Some url
            | _ -> None)
          e.tags
    | None -> []
  in
  if from_relay_list <> [] then from_relay_list
  else
    match get_contact_list_event est pubkey with
    | None -> []
    | Some e -> (
        match Yojson.Safe.from_string e.content with
        | `Assoc kv ->
            List.filter_map
              (fun (url, v) ->
                if url = "" then None
                else
                  match v with
                  | `Assoc markers when List.exists (fun (_, b) -> b = `Bool true) markers -> Some url
                  | _ -> None)
              kv
        | _ -> []
        | exception _ -> [])

(* Julia update_fetcher_relays: publish the user's relays to fetcher_relays for the (separate)
   fetcher process. Called from the contact-list and relay-list-metadata branches. *)
(* Lean (enabled): the same relay URLs with one read each, selecting only what is parsed (the
   relay list's tags; the contact list's content, not its large tags). *)
let user_relay_urls_lean (est : est) (pubkey : string) : string list =
  let dbh = est.dbh in
  let from_relay_list =
    match
      [%pgsql dbh "select ev.tags from relay_list_metadata_1_801a17fc93 r, event ev where r.pubkey = $pubkey and ev.id = r.event_id"]
    with
    | tags :: _ ->
        List.filter_map
          (fun tg ->
            match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
            | Some "r", Some url when url <> "" -> Some url
            | _ -> None)
          (parse_tags_json tags)
    | [] -> []
  in
  if from_relay_list <> [] then from_relay_list
  else
    match [%pgsql dbh "select ev.content from contact_lists_1_1abdf474bd c, event ev where c.key = $pubkey and ev.id = c.value"] with
    | [] -> []
    | content :: _ -> (
        match Yojson.Safe.from_string content with
        | `Assoc kv ->
            List.filter_map
              (fun (url, v) ->
                if url = "" then None
                else
                  match v with
                  | `Assoc markers when List.exists (fun (_, b) -> b = `Bool true) markers -> Some url
                  | _ -> None)
              kv
        | _ -> []
        | exception _ -> [])

let update_fetcher_relays (est : est) ~(pubkey : string) ~(source_event_id : string option) : unit =
  let dbh = est.dbh in
  if est.cfg.lean.enabled then
    (* The fetcher polls updated_at for URLs it doesn't know yet and never forgets one, so bumping
       known URLs (11 M non-HOT updates a month on the production cache host) told it nothing. *)
    List.iter
      (fun relay_url ->
        ignore
          [%pgsql dbh "insert into fetcher_relays (relay_url, updated_at, source_event_id) values ($relay_url, now(), $?source_event_id) on conflict (relay_url) do nothing"])
      (user_relay_urls_lean est pubkey)
  else
  List.iter
    (fun relay_url ->
      ignore
        [%pgsql dbh "insert into fetcher_relays (relay_url, updated_at, source_event_id) values ($relay_url, now(), $?source_event_id) on conflict (relay_url) do update set updated_at = excluded.updated_at"])
    (user_relay_urls est pubkey)

let rec import_pubkey_bookmarks (est : est) (e : Nostr.t) : unit =
  if est.cfg.lean.enabled then import_pubkey_bookmarks_diff est e else
  let dbh = est.dbh in
  let pubkey = e.pubkey in
  ignore [%pgsql dbh "delete from pubkey_bookmarks where pubkey = $pubkey"];
  List.iter
    (fun tg ->
      match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
      | Some "e", Some h -> (
          match decode32 h with
          | Some ref_event_id ->
              ignore
                [%pgsql dbh "insert into pubkey_bookmarks (pubkey, ref_event_id, ref_kind, ref_pubkey, ref_identifier) values ($pubkey, $ref_event_id, null, null, null)"]
          | None -> ())
      | _ -> ())
    e.tags

(* Lean (enabled): the same rows as delete-all + reinsert, by diff (Lean.bookmark_diff): usually one
   statement for the one bookmark added or removed. *)
and import_pubkey_bookmarks_diff (est : est) (e : Nostr.t) : unit =
  let dbh = est.dbh in
  let pubkey = e.pubkey in
  let existing =
    List.map
      (fun (id, plain) -> (id, plain = Some true))
      [%pgsql dbh
        "select ref_event_id, (ref_kind is null and ref_pubkey is null and ref_identifier is null) from pubkey_bookmarks where pubkey = $pubkey"]
  in
  let desired =
    List.filter_map
      (fun tg -> match (Nostr.tag_name tg, Nostr.tag_field tg 1) with Some "e", Some h -> decode32 h | _ -> None)
      e.tags
  in
  let d = Lean.bookmark_diff ~existing ~desired in
  if d.Lean.del_nonplain then
    ignore
      [%pgsql dbh
        "delete from pubkey_bookmarks where pubkey = $pubkey and (ref_event_id is null or ref_kind is not null or ref_pubkey is not null or ref_identifier is not null)"];
  List.iter
    (fun ref_event_id -> ignore [%pgsql dbh "delete from pubkey_bookmarks where pubkey = $pubkey and ref_event_id = $ref_event_id"])
    d.Lean.del_ids;
  List.iter
    (fun ref_event_id ->
      ignore
        [%pgsql dbh "insert into pubkey_bookmarks (pubkey, ref_event_id, ref_kind, ref_pubkey, ref_identifier) values ($pubkey, $ref_event_id, null, null, null)"])
    d.Lean.ins

let bookmark_eids (e : Nostr.t) : string list =
  List.filter_map
    (fun tg -> match (Nostr.tag_name tg, Nostr.tag_field tg 1) with Some "e", Some h -> decode32 h | _ -> None)
    e.tags

let store_bookmarks ?(force = false) (est : est) (e : Nostr.t) : unit =
  let dbh = est.dbh in
  let pubkey = e.pubkey and event_id = e.id in
  (* Julia compares against the previous bookmark event and only notifies newly-added eids
     (cache_storage.jl:1343-1353). *)
  let old_be =
    match [%pgsql dbh "select event_id from bookmarks_1_43f5248b56 where pubkey = $pubkey"] with
    | beid :: _ -> get_event est beid
    | [] -> None
  in
  let newer = force || match old_be with None -> true | Some be -> e.created_at > be.created_at in
  if newer then begin
    ignore
      [%pgsql dbh "insert into bookmarks_1_43f5248b56 (pubkey, event_id) values ($pubkey, $event_id) on conflict (pubkey) do update set event_id = excluded.event_id"];
    import_pubkey_bookmarks est e;
    let olds = SS.of_list (match old_be with Some be -> bookmark_eids be | None -> []) in
    List.iter
      (fun eid ->
        if not (SS.mem eid olds) then
          event_hook est eid
            (Notifications_cb (Notif.your_post_was_bookmarked, [ `String (Hex_util.encode e.id) ])))
      (bookmark_eids e)
  end

(* Julia HIGHLIGHT branch (cache_storage.jl:1354-1367): each e/a tag highlights a target event;
   fire YOUR_POST_WAS_HIGHLIGHTED on the highlighted event. *)
let handle_highlight (est : est) (e : Nostr.t) : unit =
  let notify eid =
    event_hook est eid
      (Notifications_cb (Notif.your_post_was_highlighted, [ `String (Hex_util.encode e.id) ]))
  in
  List.iter
    (fun tg ->
      if Nostr.tag_len tg >= 2 then
        match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
        | Some "e", Some h -> ( match decode32 h with Some eid -> notify eid | None -> ())
        | Some "a", Some s -> (
            match parse_a_tag s with
            | Some (kind, pubkey, identifier) -> (
                match lookup_parametrized_replaceable_event est ~kind ~pubkey ~identifier with
                | Some eid -> notify eid
                | None -> ())
            | None -> ())
        | _ -> ())
    e.tags

(* [newer_known] (lean.delete_superseded): import_event already found this version newer than the
   current one (NIP-01 order), so the per-kind "is it newer" checks are skipped. *)
let dispatch_kind ?(newer_known = false) (est : est) (e : Nostr.t) : unit =
  let k = e.kind in
  if k = Nostr.kind_set_metadata then begin
    if newer_known || meta_data_should_update est ~pubkey:e.pubkey ~created_at:e.created_at then begin
      upsert_pubkey_event_id est ~table:`Meta_data ~key:e.pubkey ~value:e.id;
      (!ext).ext_metadata_changed est e;
      (* lean: the event in hand is now the current metadata; no re-read *)
      if est.cfg.lean.enabled then update_pubkey_ln_address_from est e.pubkey e
      else update_pubkey_ln_address est e.pubkey
    end
  end
  else if k = Nostr.kind_contact_list then begin
    if est.cfg.lean.enabled then import_contact_list_lean est e ~newer_known
    else if newer_known || contact_list_should_update est ~pubkey:e.pubkey ~created_at:e.created_at then
      import_contact_list est e;
    update_fetcher_relays est ~pubkey:e.pubkey ~source_event_id:(Some e.id)
  end
  else if k = Nostr.kind_reaction then handle_reaction est e
  else if is_text_note_branch k then handle_note_reply est e
  else if k = Nostr.kind_direct_message then begin
    import_directmsg est e;
    (* NEW_DIRECT_MESSAGE: hook on the DM event itself; notifications_cb reads its 'p' tag for the
       receiver (cache_storage.jl:1221). *)
    event_hook est e.id (Notifications_cb (Notif.new_direct_message, []))
  end
  else if k = Nostr.kind_event_deletion then import_delete_event est e
  else if k = Nostr.kind_repost then handle_repost est e
  else if k = Nostr.kind_zap_receipt then handle_zap_receipt est e
  else if k = Nostr.kind_mute_list then begin
    upsert_pubkey_event_id est ~table:`Mute_list ~key:e.pubkey ~value:e.id;
    (!ext).update_content_moderation_rules est e.pubkey
  end
  else if k = Nostr.kind_categorized_people then handle_categorized_people est e
  else if k = Nostr.kind_comment then handle_note_reply est e
  else if k = Nostr.kind_long_form_content then (!ext).ext_long_form_note est e
  else if k = Nostr.kind_live_event then (!ext).ext_live_event est e
  else if k = Nostr.kind_follow_pack then (!ext).ext_follow_pack est e
  else if k = Nostr.kind_live_event_mutelist then (!ext).ext_live_event_mutelist est e
  else if k = Nostr.kind_video_long_form || k = Nostr.kind_video_short_form then
    (!ext).ext_video_note est e
  else if k = Nostr.kind_relay_list_metadata then begin
    store_relay_list_metadata ~force:newer_known est e;
    update_fetcher_relays est ~pubkey:e.pubkey ~source_event_id:(Some e.id)
  end
  else if k = Nostr.kind_bookmarks then store_bookmarks ~force:newer_known est e
  else if k = Nostr.kind_highlight then handle_highlight est e
  else if k = Nostr.kind_reporting then begin
    if est.cfg.import_reporting then (!ext).import_reporting est e
  end
  (* Julia also queued a follow pack's image tags for media import (import_follow_list_media,
     with DOWNLOAD_MEDIA); not ported. *)

(* {1 import_event} (Julia 1046-1434) *)

(* Julia DB.verify: reject far-future events, then check the signature. *)
let verify_event (e : Nostr.t) : bool =
  e.created_at < Utils.current_time () + 300 && Nostr.verify e

let blocked_kinds = [ 29333 ]

(* Outcome of importing one event/message, for stats. [Rejected] = refused before storage
   (failed verification, blocked/unaccepted kind, already-deleted, ext_preimport_check, or an
   unparseable message); [Duplicate] = lost the atomic store_event claim (already imported);
   [Imported] = newly stored and dispatched. *)
type import_result = Imported | Duplicate | Rejected

(* The lean import path (any lean flag set). Each flag-off branch is the classic statement. *)
let import_event_lean (est : est) (e : Nostr.t) : import_result =
  let l = est.cfg.lean in
  if est.cfg.verification_enabled && not (verify_event e) then Rejected
  (* the kind checks cost nothing: before the deleted_events probe *)
  else if (not (accepted_kind e.kind)) || List.mem e.kind blocked_kinds then Rejected
  else if not (Lean.kind_allowed l e.kind) then begin
    Atomic.incr Lean.kind_rejected;
    Rejected
  end
  else if l.delete_superseded && Lean.Superseded.mem e.id then Duplicate
  else if event_deleted est e.id then Rejected
  else if not ((!ext).ext_preimport_check est e) then Rejected
  else if not (store_event est e) then Duplicate
  else begin
    let side_effects () =
      with_scope est e (fun () ->
          let keep = Lean.keeps_versions l e.kind in
          let check =
            if not l.delete_superseded then No_pointer
            else
              try version_check est e with
              | ex when not (in_event_tx () || Postgres.is_connection_error ex) ->
                  (* undecided: the classic path (pointer moves, nothing deleted) *)
                  Printf.eprintf "import_event: version_check: %s\n%!" (Printexc.to_string ex);
                  No_pointer
          in
          if check = Older && not keep then
            (* an older version than the current one changes nothing: its row goes again, before any
               derived row is written *)
            guard "superseded" (fun () -> delete_superseded_row est e.id)
          else begin
            if not l.no_event_created_at then set_event_created_at est e;
            if l.no_pubkey_ids || l.lazy_counters then track_pubkey_lean est e.pubkey else track_pubkey est e.pubkey;
            if is_pubkey_event_kind e.kind then
              insert_pubkey_event ?kind:(if l.pubkey_events_kind then Some (i64 e.kind) else None) est ~pubkey:e.pubkey
                ~event_id:e.id ~created_at:(i64 e.created_at)
                ~is_reply:(if is_reply_event e then 1L else 0L);
            if is_note_kind e.kind && not l.lazy_counters then event_stats_init est e;
            match check with
            | Older -> () (* a kept kind (keep_versions_kinds): the row stays, nothing moves *)
            | No_pointer | Newest _ ->
                let newer_known = check <> No_pointer in
                guard "dispatch" (fun () -> dispatch_kind ~newer_known est e);
                if 10000 <= e.kind && e.kind < 20000 then guard "replaceable" (fun () -> store_replaceable_event est e);
                if 30000 <= e.kind && e.kind < 40000 then
                  guard "parametrized_replaceable" (fun () ->
                      match check with
                      | Newest prev -> move_parametrized_replaceable_pointer est e ~exists:(prev <> None)
                      | _ -> store_parametrized_replaceable_event est e);
                (match check with
                | Newest (Some old_id) when not keep ->
                    (* after dispatch: kind 3's follow diff has read the previous list *)
                    guard "superseded" (fun () -> delete_superseded_row est old_id)
                | _ -> ())
          end;
          guard "event_hooks" (fun () -> fire_event_hooks est e))
    in
    if l.transaction_per_event then run_event_tx est side_effects else side_effects ();
    Imported
  end

let import_event (est : est) (e : Nostr.t) : import_result =
  if Lean.active est.cfg.lean then import_event_lean est e else
  if est.cfg.verification_enabled && not (verify_event e) then Rejected
  else if event_deleted est e.id then Rejected
  else if not (accepted_kind e.kind) then Rejected
  else if List.mem e.kind blocked_kinds then Rejected
  else if not ((!ext).ext_preimport_check est e) then Rejected
  (* store_event is the atomic claim (Julia's already_imported_check_lock): it both inserts the
     event and reports whether we won the race. A losing concurrent delivery returns false here and
     skips dispatch, so side effects (likes/reposts/zaps, action refs) run exactly once. *)
  else if not (store_event est e) then Duplicate
  else begin
    set_event_created_at est e;
    track_pubkey est e.pubkey;
    if is_pubkey_event_kind e.kind then
      insert_pubkey_event est ~pubkey:e.pubkey ~event_id:e.id ~created_at:(i64 e.created_at)
        ~is_reply:(if is_reply_event e then 1L else 0L);
    if is_note_kind e.kind then event_stats_init est e;
    guard "dispatch" (fun () -> dispatch_kind est e);
    if 10000 <= e.kind && e.kind < 20000 then guard "replaceable" (fun () -> store_replaceable_event est e);
    if 30000 <= e.kind && e.kind < 40000 then
      guard "parametrized_replaceable" (fun () -> store_parametrized_replaceable_event est e);
    guard "event_hooks" (fun () -> fire_event_hooks est e);
    (* (Julia's ext_event, called here, is a no-op.) *)
    Imported
  end

let count_events (est : est) : int64 =
  let dbh = est.dbh in
  match [%pgsql dbh "select count(*) from event"] with Some n :: _ -> n | _ -> 0L

(* Julia: DB.import_msg_into_storage(msg, est) *)
let import_msg_into_storage (est : est) (msg : string) : import_result =
  if String.length msg > max_message_size then Rejected
  else
    match Nostr.event_from_msg (Yojson.Safe.from_string msg) with
    | Some (_relay, e) -> import_event est e
    | None -> Rejected
    | exception _ -> Rejected

(* {1 Periodic: expire_scores} (Julia cache_storage_ext.jl:984, run by CacheStorage.periodic every
   60 s). Each scoring action schedules a score_expiry row to take its score24h contribution back
   24 h later. Julia loops row by row; here one set-based update (summed per event, so several due
   rows for one event are all applied) followed by the same delete. Returns the expired row count. *)
let expire_scores (est : est) : int =
  let dbh = est.dbh in
  let tnow = i64 (Utils.current_time ()) in
  ignore
    [%pgsql dbh
      "update event_stats_1_1b380f4869 es set score24h = es.score24h - d.change \
       from (select event_id, sum(change) as change from score_expiry where expire_at <= $tnow group by event_id) d \
       where es.event_id = d.event_id"];
  List.length [%pgsql dbh "delete from score_expiry where expire_at <= $tnow returning event_id"]

(* Julia DB.add_human_override (cache_storage_ext.jl:1053): the API marks the author of every
   event imported through import_events as human. In the membership DB, like Julia's
   MembershipDBDict: the caches get human_override by logical replication, and a cache-side row would
   collide with the replicated insert of the same pubkey (the subscription then stops). *)
let add_human_override (est : est) ~(pubkey : string) ~(is_human : bool) ~(source : string) : unit =
  let dbh = est.mem_dbh in
  ignore
    [%pgsql dbh
      "insert into human_override (pubkey, is_human, added_at, source) values ($pubkey, $is_human, now(), $source) \
       on conflict (pubkey) do update set is_human = excluded.is_human, source = excluded.source"]

(* Julia DB.get_trusted_followers_count (cache_storage_ext.jl:1083). *)
let get_trusted_followers_count (est : est) (pubkey : string) : int64 =
  let dbh = est.dbh in
  match
    [%pgsql dbh
      "select count(1) from pubkey_followers_1_d52305fb47 pf, pubkey_trustrank tr \
       where pf.pubkey = $pubkey and pf.follower_pubkey = tr.pubkey and tr.rank > 0"]
  with
  | Some n :: _ -> n
  | _ -> 0L
