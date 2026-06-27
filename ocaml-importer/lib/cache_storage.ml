(* Core event-import pipeline, mirroring Julia src/cache_storage.jl (module DB). SQL is
   inline with [%pgsql] exactly where the Julia code calls [exe(est.table, @sql("..."), ...)].
   The connection [est.dbh] is leased once per event by the caller (Worker_pool / main).

   Phase 1 = core storage path; Phase 2 (this) = full per-kind dispatch + helpers.
   ext_* hooks, notifications, the dyn tables (relay_list_metadata / bookmarks / ...),
   LNURL zapper verification and relay fetching are stubbed here and land in Phase 3-5
   (each marked with a TODO). *)

module PGOCaml = Postgres.PGOCaml

type config = {
  verification_enabled : bool;
  verify_zappers : bool;
  trusted_zappers : string list; (* raw 32-byte pubkeys *)
  disable_trustrank : bool;
      (* Julia est.disable_trustrank: when set, seed pubkey_trustrank=1.0 for every new
         pubkey so ext_is_human is true for everyone (used when no TrustRankMaker runs). *)
}

let default_config =
  { verification_enabled = true; verify_zappers = true; trusted_zappers = []; disable_trustrank = false }

(* [dbh] is the cache DB (Julia :p0); [mem_dbh] is the membership DB (Julia :membership),
   where the filterlist / human_override tables live. At compile time both type-check against
   the same reference DB. *)
type est = { cfg : config; dbh : Postgres.dbh; mem_dbh : Postgres.dbh }

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
  ext_is_hidden_event : est -> string -> bool;           (* eid *)
  score_event_cb : est -> Nostr.t -> string -> int -> string -> int -> unit;
      (* parent event, initiator pubkey, scored_at, action, increment *)
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
    ext_is_hidden_event = (fun _ _ -> false);
    score_event_cb = (fun _ _ _ _ _ _ -> ());
  }

let ext = ref no_ext
let set_ext h = ext := h

(* LNURL zapper verification (Julia cache_storage.jl:1265-1294). Provided by [Lnurl] and wired
   in main.ml (it needs Eio net/clock/proxy, not available in [est]). Default: reject — so when
   no verifier is wired and VERIFY_ZAPPERS is on, only trusted_zappers pass. *)
let zapper_verifier : (est -> zapped_pk:string -> zap_receipt:Nostr.t -> bool) ref =
  ref (fun _ ~zapped_pk:_ ~zap_receipt:_ -> false)

let set_zapper_verifier f = zapper_verifier := f

(* Julia ext_is_hidden(est, e.id); routed through the registry. *)
let ext_is_hidden_event (est : est) (id : string) : bool = (!ext).ext_is_hidden_event est id

let max_message_size = 2_000_000
let max_satszapped = 1_100_000
let i64 = Int64.of_int

let guard label f = try f () with exn ->
  Printf.eprintf "import_event: %s: %s\n%!" label (Printexc.to_string exn)

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
  match [%pgsql dbh "select 1 from events where id = $id limit 1"] with
  | [] -> false
  | _ -> true

let already_imported (est : est) (e : Nostr.t) = already_imported_id est e.id

let event_deleted (est : est) (id : string) : bool =
  let dbh = est.dbh in
  match [%pgsql dbh "select 1 from deleted_events where event_id = $id limit 1"] with
  | [] -> false
  | _ -> true

let parse_tags_json (s : string) : Nostr.tag list =
  match Yojson.Safe.from_string s with
  | `List ts -> List.map (function `List f -> f | other -> [ other ]) ts
  | _ -> []

(* Julia: est.events[eid] -> Nostr.Event (reconstructed from the row). *)
let get_event (est : est) (id : string) : Nostr.t option =
  let dbh = est.dbh in
  match
    [%pgsql dbh "select pubkey, created_at, kind, tags, content, sig from events where id = $id"]
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

(* Julia is_trusted_user -> ext_is_human(threshold=0) -> pubkey_trustrank.rank > 0 *)
let is_trusted_user (est : est) (pubkey : string) : bool =
  let dbh = est.dbh in
  match [%pgsql dbh "select 1 from pubkey_trustrank where pubkey = $pubkey and rank > 0 limit 1"] with
  | [] -> false
  | _ -> true

(* {1 event_stats counters} (Julia event_stats_cb; dynamic column -> one query each) *)

let incr_event_stat (est : est) (event_id : string) (prop : string) (increment : int) : unit =
  let dbh = est.dbh in
  let d = i64 increment in
  match prop with
  | "likes" -> ignore [%pgsql dbh "update event_stats set likes = likes + $d where event_id = $event_id"]
  | "replies" -> ignore [%pgsql dbh "update event_stats set replies = replies + $d where event_id = $event_id"]
  | "mentions" -> ignore [%pgsql dbh "update event_stats set mentions = mentions + $d where event_id = $event_id"]
  | "reposts" -> ignore [%pgsql dbh "update event_stats set reposts = reposts + $d where event_id = $event_id"]
  | "zaps" -> ignore [%pgsql dbh "update event_stats set zaps = zaps + $d where event_id = $event_id"]
  | "satszapped" -> ignore [%pgsql dbh "update event_stats set satszapped = satszapped + $d where event_id = $event_id"]
  | "score" -> ignore [%pgsql dbh "update event_stats set score = score + $d where event_id = $event_id"]
  | "score24h" -> ignore [%pgsql dbh "update event_stats set score24h = score24h + $d where event_id = $event_id"]
  | _ -> ()

(* {1 event_hooks} (Julia event_hook / event_hook_execute; funcall stored as JSON)

   Typed deferred call. event_stats_cb is executed; notifications_cb is stored only and
   fired in Phase 3 (kept as raw JSON so nothing is lost). *)
type hook_call =
  | Event_stats_cb of string * int
  | Score_event_cb of { initiator : string; scored_at : int; action : string; increment : int }
  | Other of Yojson.Safe.t list

let hook_to_json = function
  | Event_stats_cb (prop, inc) -> `List [ `String "event_stats_cb"; `String prop; `Int inc ]
  | Score_event_cb { initiator; scored_at; action; increment } ->
      (* matches Julia's stored (:score_event_cb, e.pubkey, e.created_at, :action, inc):
         the pubkey JSON-lowers to hex, the symbol to a string. *)
      `List [ `String "score_event_cb"; `String (Hex_util.encode initiator);
              `Int scored_at; `String action; `Int increment ]
  | Other args -> `List args

let hook_of_json (j : Yojson.Safe.t) : hook_call =
  match j with
  | `List (`String "event_stats_cb" :: `String prop :: `Int inc :: _) ->
      Event_stats_cb (prop, inc)
  | `List (`String "score_event_cb" :: `String init_hex :: `Int scored_at :: `String action :: `Int increment :: _) -> (
      match Hex_util.decode_opt init_hex with
      | Some initiator -> Score_event_cb { initiator; scored_at; action; increment }
      | None -> Other [])
  | `List args -> Other args
  | _ -> Other []

(* event_hook_execute: Julia evals the funcall against the *event* whose hooks fired, so the
   executor receives the full parent event (needed by score_event_cb for content/pubkey). *)
let apply_hook (est : est) (e : Nostr.t) = function
  | Event_stats_cb (prop, inc) -> incr_event_stat est e.id prop inc
  | Score_event_cb { initiator; scored_at; action; increment } ->
      (!ext).score_event_cb est e initiator scored_at action increment
  | Other _ -> () (* notifications_cb etc. — the notifications subsystem is a TODO *)

let event_hook (est : est) (eid : string) (call : hook_call) : unit =
  if already_imported_id est eid then
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
  let rows = [%pgsql dbh "select funcall from event_hooks where event_id = $id"] in
  List.iter
    (fun funcall -> apply_hook est e (hook_of_json (Yojson.Safe.from_string funcall)))
    rows;
  ignore [%pgsql dbh "delete from event_hooks where event_id = $id"]

(* schedule_hook (Julia cache_storage.jl): defer a funcall to run after [execute_at]. Past-due
   hooks run their executor immediately (we have none wired yet) else are persisted; a separate
   periodic runner fires scheduled_hooks (TODO). *)
let schedule_hook (est : est) ~(execute_at : int) (funcall : Yojson.Safe.t) : unit =
  if execute_at <= Utils.current_time () then ()
  else begin
    let dbh = est.dbh in
    let execute_at = i64 execute_at and funcall = Yojson.Safe.to_string funcall in
    ignore [%pgsql dbh "insert into scheduled_hooks (execute_at, funcall) values ($execute_at, $funcall)"]
  end

(* {1 event_pubkey_actions} (Julia init_event_pubkey_action / event_pubkey_action) *)

let init_event_pubkey_action (est : est) ~(eid : string) ~(re : Nostr.t) : unit =
  let dbh = est.dbh in
  let event_id = eid and pubkey = re.pubkey and created_at = i64 re.created_at in
  ignore
    [%pgsql
      dbh
        "insert into event_pubkey_actions (event_id, pubkey, created_at, updated_at, \
         replied, liked, reposted, zapped) values ($event_id, $pubkey, $created_at, 0, 0, \
         0, 0, 0) on conflict (event_id, pubkey) do nothing"]

let event_pubkey_action (est : est) ~(eid : string) ~(re : Nostr.t) ~(action : string) : unit =
  init_event_pubkey_action est ~eid ~re;
  let dbh = est.dbh in
  let event_id = eid and pubkey = re.pubkey and updated_at = i64 re.created_at in
  (match action with
  | "replied" -> ignore [%pgsql dbh "update event_pubkey_actions set replied = 1, updated_at = $updated_at where event_id = $event_id and pubkey = $pubkey"]
  | "liked" -> ignore [%pgsql dbh "update event_pubkey_actions set liked = 1, updated_at = $updated_at where event_id = $event_id and pubkey = $pubkey"]
  | "reposted" -> ignore [%pgsql dbh "update event_pubkey_actions set reposted = 1, updated_at = $updated_at where event_id = $event_id and pubkey = $pubkey"]
  | "zapped" -> ignore [%pgsql dbh "update event_pubkey_actions set zapped = 1, updated_at = $updated_at where event_id = $event_id and pubkey = $pubkey"]
  | _ -> ());
  let event_id = eid and ref_event_id = re.id and ref_pubkey = re.pubkey in
  let ref_created_at = i64 re.created_at and ref_kind = i64 re.kind in
  ignore
    [%pgsql
      dbh
        "insert into event_pubkey_action_refs (event_id, ref_event_id, ref_pubkey, \
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
  let dbh = est.dbh in
  let k = i64 kind in
  match
    [%pgsql dbh "select event_id from parametrized_replaceable_events where pubkey = $pubkey and kind = $k and identifier = $identifier limit 1"]
  with
  | x :: _ -> Some x
  | [] -> None

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

let parse_parent_eid (est : est) (e : Nostr.t) : string option =
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

let store_event (est : est) (e : Nostr.t) : unit =
  let dbh = est.dbh in
  let id = e.id and pubkey = e.pubkey and sig_ = e.sig_ and content = e.content in
  let created_at = i64 e.created_at and kind = i64 e.kind in
  let imported_at = i64 (Utils.current_time ()) in
  let tags = Yojson.Safe.to_string (`List (List.map (fun (t : Nostr.tag) -> `List t) e.tags)) in
  ignore
    [%pgsql
      dbh
        "insert into events (id, pubkey, created_at, kind, tags, content, sig, \
         imported_at) values ($id, $pubkey, $created_at, $kind, $tags, $content, $sig_, \
         $imported_at) on conflict (id) do update set pubkey = excluded.pubkey, \
         created_at = excluded.created_at, kind = excluded.kind, tags = excluded.tags, \
         content = excluded.content, sig = excluded.sig, imported_at = \
         excluded.imported_at"]

let set_event_created_at (est : est) (e : Nostr.t) : unit =
  let dbh = est.dbh in
  let event_id = e.id and created_at = i64 e.created_at in
  ignore
    [%pgsql dbh "insert into event_created_at (event_id, created_at) values ($event_id, $created_at) on conflict (event_id) do update set created_at = excluded.created_at"]

let pubkey_known (est : est) (pubkey : string) : bool =
  let dbh = est.dbh in
  match [%pgsql dbh "select 1 from pubkey_ids where key = $pubkey limit 1"] with
  | [] -> false
  | _ -> true

(* Julia get(est.pubkey_followers_cnt, pubkey, 0). *)
let pubkey_followers_cnt (est : est) (pubkey : string) : int =
  let dbh = est.dbh in
  match [%pgsql dbh "select value from pubkey_followers_cnt where key = $pubkey"] with
  | v :: _ -> Int64.to_int v
  | [] -> 0

let track_pubkey (est : est) (pubkey : string) : unit =
  if not (pubkey_known est pubkey) then begin
    let dbh = est.dbh in
    ignore [%pgsql dbh "insert into pubkey_ids (key, value) values ($pubkey, true) on conflict (key) do nothing"];
    ignore [%pgsql dbh "insert into pubkey_followers_cnt (key, value) values ($pubkey, 0) on conflict (key) do nothing"];
    if est.cfg.disable_trustrank then begin
      let rank = 1.0 in
      ignore [%pgsql dbh "insert into pubkey_trustrank (pubkey, rank) values ($pubkey, $rank) on conflict (pubkey) do nothing"]
    end;
    (!ext).ext_pubkey est pubkey
  end

let insert_pubkey_event (est : est) ~pubkey ~event_id ~created_at ~is_reply : unit =
  let dbh = est.dbh in
  ignore
    [%pgsql dbh "insert into pubkey_events (pubkey, event_id, created_at, is_reply) values ($pubkey, $event_id, $created_at, $is_reply)"]

let event_stats_init (est : est) (e : Nostr.t) : unit =
  let dbh = est.dbh in
  let event_id = e.id and author_pubkey = e.pubkey and created_at = i64 e.created_at in
  ignore
    [%pgsql
      dbh
        "insert into event_stats (event_id, author_pubkey, created_at, likes, replies, \
         mentions, reposts, zaps, satszapped, score, score24h) values ($event_id, \
         $author_pubkey, $created_at, 0, 0, 0, 0, 0, 0, 0, 0) on conflict (event_id) do \
         nothing"]

let insert_event_reply (est : est) ~parent ~reply ~reply_created_at : unit =
  let dbh = est.dbh in
  ignore
    [%pgsql dbh "insert into event_replies (event_id, reply_event_id, reply_created_at) values ($parent, $reply, $reply_created_at)"]

let set_event_thread_parent (est : est) ~event_id ~parent : unit =
  let dbh = est.dbh in
  ignore
    [%pgsql dbh "insert into event_thread_parents (key, value) values ($event_id, $parent) on conflict (key) do update set value = excluded.value"]

(* {1 Replaceable / parametrized replaceable} (Julia 1399-1422) *)

let store_replaceable_event (est : est) (e : Nostr.t) : unit =
  let dbh = est.dbh in
  let pubkey = e.pubkey and kind = i64 e.kind and event_id = e.id in
  ignore
    [%pgsql dbh "insert into replaceable_events (pubkey, kind, event_id) values ($pubkey, $kind, $event_id) on conflict (pubkey, kind) do update set event_id = excluded.event_id"]

let store_parametrized_replaceable_event (est : est) (e : Nostr.t) : unit =
  (* find the first d tag *)
  match
    List.find_map
      (fun tg -> match (Nostr.tag_name tg, Nostr.tag_field tg 1) with Some "d", Some d -> Some d | _ -> None)
      e.tags
  with
  | None -> ()
  | Some identifier ->
      let dbh = est.dbh in
      let pubkey = e.pubkey and kind = i64 e.kind and event_id = e.id and created_at = i64 e.created_at in
      ignore [%pgsql dbh "delete from parametrized_replaceable_events where pubkey = $pubkey and kind = $kind and identifier = $identifier"];
      ignore
        [%pgsql dbh "insert into parametrized_replaceable_events (pubkey, kind, identifier, event_id, created_at) values ($pubkey, $kind, $identifier, $event_id, $created_at)"]

(* {1 Replaceable single-event dict writes (meta_data, mute lists, contact_lists)} *)

let upsert_pubkey_event_id (est : est) ~(table : [ `Meta_data | `Contact_lists | `Mute_list | `Mute_list_2 | `Mute_lists | `Allow_list ]) ~key ~value : unit =
  let dbh = est.dbh in
  match table with
  | `Meta_data -> ignore [%pgsql dbh "insert into meta_data (key, value) values ($key, $value) on conflict (key) do update set value = excluded.value"]
  | `Contact_lists -> ignore [%pgsql dbh "insert into contact_lists (key, value) values ($key, $value) on conflict (key) do update set value = excluded.value"]
  | `Mute_list -> ignore [%pgsql dbh "insert into mute_list (key, value) values ($key, $value) on conflict (key) do update set value = excluded.value"]
  | `Mute_list_2 -> ignore [%pgsql dbh "insert into mute_list_2 (key, value) values ($key, $value) on conflict (key) do update set value = excluded.value"]
  | `Mute_lists -> ignore [%pgsql dbh "insert into mute_lists (key, value) values ($key, $value) on conflict (key) do update set value = excluded.value"]
  | `Allow_list -> ignore [%pgsql dbh "insert into allow_list (key, value) values ($key, $value) on conflict (key) do update set value = excluded.value"]

let meta_data_should_update (est : est) ~pubkey ~created_at : bool =
  let dbh = est.dbh in
  let key = pubkey in
  match [%pgsql dbh "select e.created_at from meta_data m, events e where m.key = $key and e.id = m.value"] with
  | [] -> true
  | old :: _ -> i64 created_at > old

let contact_list_should_update (est : est) ~pubkey ~created_at : bool =
  let dbh = est.dbh in
  let key = pubkey in
  match [%pgsql dbh "select e.created_at from contact_lists c, events e where c.key = $key and e.id = c.value"] with
  | [] -> true
  | old :: _ -> i64 created_at > old

(* Julia update_pubkey_ln_address: parse lud16 out of the pubkey's current metadata event. *)
let get_meta_data_event (est : est) (pubkey : string) : Nostr.t option =
  let dbh = est.dbh in
  match [%pgsql dbh "select value from meta_data where key = $pubkey"] with
  | mid :: _ -> get_event est mid
  | [] -> None

let update_pubkey_ln_address (est : est) (pubkey : string) : unit =
  match get_meta_data_event est pubkey with
  | None -> ()
  | Some me -> (
      match Yojson.Safe.from_string me.content with
      | `Assoc kv -> (
          match List.assoc_opt "lud16" kv with
          | Some (`String lud16) when lud16 <> "" ->
              let dbh = est.dbh in
              ignore
                [%pgsql dbh "insert into pubkey_ln_address (pubkey, ln_address) values ($pubkey, $lud16) on conflict (pubkey) do update set ln_address = excluded.ln_address"]
          | _ -> ())
      | _ -> ()
      | exception _ -> ())

(* {1 Contact list import} (Julia import_contact_list) *)

let contact_list_follows (e : Nostr.t) : string list =
  List.filter_map
    (fun tg -> match (Nostr.tag_name tg, Nostr.tag_field tg 1) with Some "p", Some h -> decode32 h | _ -> None)
    e.tags

let get_contact_list_event (est : est) (pubkey : string) : Nostr.t option =
  let dbh = est.dbh in
  match [%pgsql dbh "select value from contact_lists where key = $pubkey"] with
  | clid :: _ -> get_event est clid
  | [] -> None

module SS = Set.Make (String)

let import_contact_list (est : est) (e : Nostr.t) : unit =
  let dbh = est.dbh in
  let old_follows =
    match get_contact_list_event est e.pubkey with Some old_e -> contact_list_follows old_e | None -> []
  in
  upsert_pubkey_event_id est ~table:`Contact_lists ~key:e.pubkey ~value:e.id;
  let news = SS.of_list (contact_list_follows e) and olds = SS.of_list old_follows in
  let trusted = is_trusted_user est e.pubkey in
  SS.iter
    (fun follow_pubkey ->
      if not (SS.mem follow_pubkey olds) then begin
        let follower_pubkey = e.pubkey and follower_contact_list_event_id = e.id in
        ignore [%pgsql dbh "insert into pubkey_followers (pubkey, follower_pubkey, follower_contact_list_event_id) values ($follow_pubkey, $follower_pubkey, $follower_contact_list_event_id)"];
        if trusted then
          ignore [%pgsql dbh "update pubkey_followers_cnt set value = value + 1 where key = $follow_pubkey"]
        (* TODO Phase 3: NEW_USER_FOLLOWED_YOU notification *)
      end)
    news;
  SS.iter
    (fun follow_pubkey ->
      if not (SS.mem follow_pubkey news) then begin
        let follower_pubkey = e.pubkey in
        ignore [%pgsql dbh "delete from pubkey_followers where pubkey = $follow_pubkey and follower_pubkey = $follower_pubkey"];
        if trusted then
          ignore [%pgsql dbh "update pubkey_followers_cnt set value = greatest(0, value - 1) where key = $follow_pubkey"]
        (* TODO Phase 3: USER_UNFOLLOWED_YOU notification *)
      end)
    olds

(* {1 Direct messages} (Julia import_directmsg) *)

let import_directmsg (est : est) (e : Nostr.t) : unit =
  match
    List.find_map
      (fun tg -> match (Nostr.tag_name tg, Nostr.tag_field tg 1) with Some "p", Some h -> decode32 h | _ -> None)
      e.tags
  with
  | None -> ()
  | Some receiver ->
      (* TODO Phase 3/4: hidden check via filterlist / App.is_hidden; assume visible *)
      let dbh = est.dbh in
      let sender = e.pubkey and created_at = i64 e.created_at and event_id = e.id in
      let exists =
        match [%pgsql dbh "select 1 from pubkey_directmsgs where receiver = $receiver and event_id = $event_id limit 1"] with
        | [] -> false
        | _ -> true
      in
      if not exists then
        ignore [%pgsql dbh "insert into pubkey_directmsgs (receiver, sender, created_at, event_id) values ($receiver, $sender, $created_at, $event_id)"];
      (* pubkey_directmsgs_cnt: maintain per (receiver, null) and (receiver, sender) *)
      let bump ~with_sender =
        if with_sender then begin
          (match [%pgsql dbh "select 1 from pubkey_directmsgs_cnt where receiver = $receiver and sender = $sender limit 1"] with
           | [] -> ignore [%pgsql dbh "insert into pubkey_directmsgs_cnt (receiver, sender, cnt, latest_at, latest_event_id) values ($receiver, $sender, 0, $created_at, $event_id)"]
           | _ -> ());
          ignore [%pgsql dbh "update pubkey_directmsgs_cnt set cnt = cnt + 1 where receiver = $receiver and sender = $sender"];
          (match [%pgsql dbh "select latest_at from pubkey_directmsgs_cnt where receiver = $receiver and sender = $sender limit 1"] with
           | prev :: _ when created_at >= prev ->
               ignore [%pgsql dbh "update pubkey_directmsgs_cnt set latest_at = $created_at, latest_event_id = $event_id where receiver = $receiver and sender = $sender"]
           | _ -> ())
        end
        else begin
          (match [%pgsql dbh "select 1 from pubkey_directmsgs_cnt where receiver = $receiver and sender is null limit 1"] with
           | [] -> ignore [%pgsql dbh "insert into pubkey_directmsgs_cnt (receiver, sender, cnt, latest_at, latest_event_id) values ($receiver, null, 0, $created_at, $event_id)"]
           | _ -> ());
          ignore [%pgsql dbh "update pubkey_directmsgs_cnt set cnt = cnt + 1 where receiver = $receiver and sender is null"];
          (match [%pgsql dbh "select latest_at from pubkey_directmsgs_cnt where receiver = $receiver and sender is null limit 1"] with
           | prev :: _ when created_at >= prev ->
               ignore [%pgsql dbh "update pubkey_directmsgs_cnt set latest_at = $created_at, latest_event_id = $event_id where receiver = $receiver and sender is null"]
           | _ -> ())
        end
      in
      bump ~with_sender:false;
      bump ~with_sender:true

(* {1 Deletions} (Julia import_delete_event; reads cleanup deferred to ext) *)

let import_delete_event (est : est) (e : Nostr.t) : unit =
  let dbh = est.dbh in
  let delete_event eid =
    let deletion_event_id = e.id in
    ignore [%pgsql dbh "insert into deleted_events (event_id, deletion_event_id) values ($eid, $deletion_event_id) on conflict (event_id) do update set deletion_event_id = excluded.deletion_event_id"];
    ignore [%pgsql dbh "delete from events where id = $eid"]
  in
  List.iter
    (fun tg ->
      match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
      | Some "e", Some h -> (
          match decode32 h with
          | None -> ()
          | Some eid -> (
              (* only delete if it belongs to the same author *)
              match get_event est eid with
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
                                ignore [%pgsql dbh "update event_pubkey_actions set reposted = 0 where event_id = $reid and pubkey = $depk"];
                                ignore [%pgsql dbh "delete from event_pubkey_action_refs where ref_event_id = $deid and ref_pubkey = $depk"];
                                ignore [%pgsql dbh "update event_stats set reposts = reposts - 1 where event_id = $reid"])
                        | _ -> ())
                      de.tags
              | _ -> ()))
      | Some "a", Some s -> (
          match parse_a_tag s with
          | None -> ()
          | Some (kind, pk, identifier) ->
              let k = i64 kind in
              (match [%pgsql dbh "select event_id from parametrized_replaceable_events where pubkey = $pk and kind = $k and identifier = $identifier limit 1"] with
               | eid :: _ -> delete_event eid
               | [] -> ());
              ignore [%pgsql dbh "delete from parametrized_replaceable_events where pubkey = $pk and kind = $k and identifier = $identifier"]
          (* TODO Phase 3: reads/reads_versions cleanup for long-form *))
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
      set_event_thread_parent est ~event_id:e.id ~parent;
      (!ext).ext_reply est e parent
  | None -> ());
  (* TODO: import_reply_notifications (notifications subsystem); Phase 5: fetch_missing_events *)
  ()

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
              end
              (* TODO: YOUR_POST_WAS_LIKED notification (notifications subsystem) *))
      | _ -> ())
    e.tags
  (* TODO Phase 5: fetch_missing_events *)

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
  (* TODO Phase 5: fetch_missing_events *)

let zapper_ok (est : est) (e : Nostr.t) ~(zapped_pk : string) : bool =
  if (not est.cfg.verify_zappers) || List.mem e.pubkey est.cfg.trusted_zappers then true
  else (!zapper_verifier) est ~zapped_pk ~zap_receipt:e

let handle_zap_receipt (est : est) (e : Nostr.t) : unit =
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
  let proceed =
    !amount_sats > 0 && !has_description
    && (match !zapped_pk with Some zp -> zapper_ok est e ~zapped_pk:zp | None -> false)
  in
  if proceed then begin
    (match !parent_eid with
    | Some parent ->
        event_hook est parent (Event_stats_cb ("zaps", 1));
        (match zap_sender e with
        | Some sender -> event_pubkey_action est ~eid:parent ~re:{ e with pubkey = sender } ~action:"zapped"
        | None -> ());
        (!ext).ext_zap est e parent !amount_sats
    | None -> ());
    (match !zapped_pk with Some zp -> (!ext).ext_pubkey_zap est e zp !amount_sats | None -> ())
  end

let handle_categorized_people (est : est) (e : Nostr.t) : unit =
  let rec go = function
    | [] -> ()
    | tg :: rest -> (
        if Nostr.tag_len tg >= 2 && Nostr.tag_name tg = Some "d" then
          match Nostr.tag_field tg 1 with
          | Some "mute" -> upsert_pubkey_event_id est ~table:`Mute_list_2 ~key:e.pubkey ~value:e.id (* TODO update_content_moderation_rules *)
          | Some "mutelists" -> upsert_pubkey_event_id est ~table:`Mute_lists ~key:e.pubkey ~value:e.id
          | Some "allowlist" -> upsert_pubkey_event_id est ~table:`Allow_list ~key:e.pubkey ~value:e.id
          | Some identifier ->
              let dbh = est.dbh in
              let pubkey = e.pubkey and created_at = i64 e.created_at and event_id = e.id in
              ignore [%pgsql dbh "delete from parameterized_replaceable_list where pubkey = $pubkey and identifier = $identifier"];
              ignore [%pgsql dbh "insert into parameterized_replaceable_list (pubkey, identifier, created_at, event_id) values ($pubkey, $identifier, $created_at, $event_id)"]
          | None -> go rest
        else go rest)
  in
  go e.tags

let dispatch_kind (est : est) (e : Nostr.t) : unit =
  let k = e.kind in
  if k = Nostr.kind_set_metadata then begin
    if meta_data_should_update est ~pubkey:e.pubkey ~created_at:e.created_at then begin
      upsert_pubkey_event_id est ~table:`Meta_data ~key:e.pubkey ~value:e.id;
      (!ext).ext_metadata_changed est e;
      update_pubkey_ln_address est e.pubkey
    end
  end
  else if k = Nostr.kind_contact_list then begin
    if contact_list_should_update est ~pubkey:e.pubkey ~created_at:e.created_at then
      import_contact_list est e
    (* TODO Phase 5: update_fetcher_relays *)
  end
  else if k = Nostr.kind_reaction then handle_reaction est e
  else if is_text_note_branch k then handle_note_reply est e
  else if k = Nostr.kind_direct_message then import_directmsg est e
  else if k = Nostr.kind_event_deletion then import_delete_event est e
  else if k = Nostr.kind_repost then handle_repost est e
  else if k = Nostr.kind_zap_receipt then handle_zap_receipt est e
  else if k = Nostr.kind_mute_list then
    upsert_pubkey_event_id est ~table:`Mute_list ~key:e.pubkey ~value:e.id
    (* TODO Phase 3: update_content_moderation_rules *)
  else if k = Nostr.kind_categorized_people then handle_categorized_people est e
  else if k = Nostr.kind_comment then handle_note_reply est e
  else if k = Nostr.kind_long_form_content then (!ext).ext_long_form_note est e
  else if k = Nostr.kind_live_event then (!ext).ext_live_event est e
  else if k = Nostr.kind_video_long_form || k = Nostr.kind_video_short_form then
    (!ext).ext_video_note est e
  (* relay_list_metadata / bookmarks / highlight / follow_pack / reporting: dyn-table /
     notification handling -> TODO (notifications subsystem, media import) *)

(* {1 import_event} (Julia 1046-1434) *)

(* Julia DB.verify: reject far-future events, then check the signature. *)
let verify_event (e : Nostr.t) : bool =
  e.created_at < Utils.current_time () + 300 && Nostr.verify e

let blocked_kinds = [ 29333 ]

let import_event (est : est) (e : Nostr.t) : bool =
  if est.cfg.verification_enabled && not (verify_event e) then false
  else if event_deleted est e.id then false
  else if not (accepted_kind e.kind) then false
  else if List.mem e.kind blocked_kinds then false
  else if already_imported est e then false
  else if not ((!ext).ext_preimport_check est e) then false
  else begin
    store_event est e;
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
    (* TODO Phase 3: ext_event *)
    true
  end

let count_events (est : est) : int64 =
  let dbh = est.dbh in
  match [%pgsql dbh "select count(*) from events"] with Some n :: _ -> n | _ -> 0L

(* Julia: DB.import_msg_into_storage(msg, est) *)
let import_msg_into_storage (est : est) (msg : string) : bool =
  if String.length msg > max_message_size then false
  else
    match Nostr.event_from_msg (Yojson.Safe.from_string msg) with
    | Some (_relay, e) -> import_event est e
    | None -> false
    | exception _ -> false
