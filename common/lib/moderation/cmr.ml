(* Content moderation rules — Julia App.compile_content_moderation_rules /
   import_content_moderation_rules (app.jl:358/488). Shared by the importer (recompute when a
   user's mute/allow lists change, cache_storage.jl:1775) and the API (set_app_settings,
   search_filterlist). Parameterized by the cache and membership connections and an event lookup. *)

open Pg_types
module PGOCaml = Postgres.PGOCaml

let default_settings_cache : (string * float * Yojson.Safe.t) option ref = ref None
let default_settings_lock = Mutex.create ()

(* Julia parsed_default_settings: the content-moderation repo's default-settings.json, re-read when
   its mtime changes. *)
let default_settings (path : string option) : Yojson.Safe.t =
  match path with
  | None -> `Assoc []
  | Some path -> (
      let mtime = try (Unix.stat path).Unix.st_mtime with _ -> 0. in
      Mutex.lock default_settings_lock;
      Fun.protect ~finally:(fun () -> Mutex.unlock default_settings_lock) (fun () ->
          match !default_settings_cache with
          | Some (p, m, j) when p = path && m = mtime -> j
          | _ ->
              let j = try Yojson.Safe.from_file path with _ -> `Assoc [] in
              default_settings_cache := Some (path, mtime, j);
              j))

let rec deepmerge (a : Yojson.Safe.t) (b : Yojson.Safe.t) : Yojson.Safe.t =
  match (a, b) with
  | `Assoc fa, `Assoc fb ->
      let merged = List.map (fun (k, va) -> match List.assoc_opt k fb with Some vb -> (k, deepmerge va vb) | None -> (k, va)) fa in
      let extra = List.filter (fun (k, _) -> not (List.mem_assoc k fa)) fb in
      `Assoc (merged @ extra)
  | _, b -> b

(* Julia App.ext_user_get_settings: defaults deep-merged with the user's app_settings content. *)
let user_settings ~(mem_dbh : Postgres.dbh) ~(defaults : Yojson.Safe.t) (pubkey : string) : Yojson.Safe.t =
  match Postgres.query mem_dbh "select value from app_settings where key = decode($1,'hex') limit 1" [ Some (Hex_util.encode pubkey) ] with
  | (Some value :: _) :: _ -> (
      try
        let content = match Yojson.Safe.Util.member "content" (Yojson.Safe.from_string value) with `String s -> Yojson.Safe.from_string s | other -> other in
        deepmerge defaults content
      with _ -> defaults)
  | _ -> defaults

type t = {
  cmr_pubkeys : (string, string * string list) Hashtbl.t; (* pubkey -> (parent, scopes) *)
  cmr_groups : (string * string list) list; (* group name -> scopes *)
  cmr_pubkeys_allowed : string list;
  cmr_threads : string list;
  cmr_hashtags : string list;
  cmr_words : string list;
}

let empty () = { cmr_pubkeys = Hashtbl.create 1; cmr_groups = []; cmr_pubkeys_allowed = []; cmr_threads = []; cmr_hashtags = []; cmr_words = [] }

(* est.mute_list / mute_list_2 / mute_lists / allow_list: the latest list event of a pubkey *)
let list_event_id ~(dbh : Postgres.dbh) table (key : string) : string option =
  let r =
    match table with
    | `Mute_list -> [%pgsql dbh "select value from mute_list_1_f693a878b9 where key = $key"]
    | `Mute_list_2 -> [%pgsql dbh "select value from mute_list_2_1_949b3d746b where key = $key"]
    | `Mute_lists -> [%pgsql dbh "select value from mute_lists_1_d90e559628 where key = $key"]
    | `Allow_list -> [%pgsql dbh "select value from allow_list_1_f1da08e9c8 where key = $key"]
  in
  match r with v :: _ -> Some v | [] -> None

let decode32 h = if String.length h = 64 then Hex_util.decode_opt h else None

let uniq (l : string list) : string list =
  let seen = Hashtbl.create 16 in
  List.filter (fun x -> if Hashtbl.mem seen x then false else (Hashtbl.add seen x (); true)) (List.rev l)

let compile ~(dbh : Postgres.dbh) ~(mem_dbh : Postgres.dbh) ~(defaults : Yojson.Safe.t) ~(get_event : string -> Nostr.t option) (pubkey : string) : t =
  let event_tags eid = match get_event eid with Some e -> e.Nostr.tags | None -> [] in
  let settings = user_settings ~mem_dbh ~defaults pubkey in
  let member k j = try Yojson.Safe.Util.member k j with _ -> `Null in
  let apply = match member "applyContentModeration" settings with `Bool b -> b | _ -> false in
  if not apply then empty ()
  else begin
    let strings = function `List l -> List.filter_map (function `String s -> Some s | _ -> None) l | _ -> [] in
    (* mute_lists (kind 30000, d=mutelists): the mute lists of OTHER users this user applies, with
       per-entry scopes in the 5th tag field. *)
    let ml_pubkeys : (string, string list) Hashtbl.t = Hashtbl.create 8 in
    (match list_event_id ~dbh `Mute_lists pubkey with
    | Some mlseid ->
        List.iter
          (fun tg ->
            if Nostr.tag_len tg >= 2 && Nostr.tag_name tg = Some "p" then
              match Option.bind (Nostr.tag_field tg 1) decode32 with
              | Some pk ->
                  let scopes =
                    if Nostr.tag_len tg >= 5 then
                      match Nostr.tag_field tg 4 with Some s -> ( try strings (Yojson.Safe.from_string s) with _ -> []) | None -> []
                    else [ "content"; "trending" ]
                  in
                  if scopes <> [] then Hashtbl.replace ml_pubkeys pk scopes
              | None -> ())
          (event_tags mlseid)
    | None -> ());
    let pubkeys : (string, string * string list) Hashtbl.t = Hashtbl.create 64 in
    let threads = ref [] and hashtags = ref [] and words = ref [] in
    let ppks = pubkey :: Hashtbl.fold (fun k _ acc -> k :: acc) ml_pubkeys [] in
    List.iter
      (fun ppk ->
        List.iter
          (fun table ->
            match list_event_id ~dbh table ppk with
            | Some eid ->
                List.iter
                  (fun tg ->
                    if Nostr.tag_len tg >= 2 then
                      match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
                      | Some "p", Some h -> (
                          match decode32 h with
                          | Some pk -> Hashtbl.replace pubkeys pk (ppk, Option.value (Hashtbl.find_opt ml_pubkeys ppk) ~default:[])
                          | None -> ())
                      | Some "e", Some h -> ( match decode32 h with Some eid -> threads := eid :: !threads | None -> ())
                      | Some "t", Some ht -> hashtags := ht :: !hashtags
                      | Some "word", Some w -> words := w :: !words
                      | _ -> ())
                  (event_tags eid)
            | None -> ())
          [ `Mute_list; `Mute_list_2 ])
      ppks;
    let groups =
      match member "contentModeration" settings with
      | `List l ->
          List.filter_map
            (fun cm ->
              match (member "name" cm, member "scopes" cm) with
              | `String name, (`List _ as sc) ->
                  let scopes = strings sc in
                  if scopes <> [] then Some (name, scopes) else None
              | _ -> None)
            l
      | _ -> []
    in
    let allowed =
      match list_event_id ~dbh `Allow_list pubkey with
      | Some eid ->
          List.filter_map (fun tg -> if Nostr.tag_len tg >= 2 && Nostr.tag_name tg = Some "p" then Option.bind (Nostr.tag_field tg 1) decode32 else None) (event_tags eid)
      | None -> []
    in
    { cmr_pubkeys = pubkeys; cmr_groups = groups; cmr_pubkeys_allowed = uniq allowed; cmr_threads = uniq !threads; cmr_hashtags = uniq !hashtags; cmr_words = uniq !words }
  end

(* Julia make_tsquery (app.jl:532): each word with non-[a-zA-Z0-9_] replaced by spaces, whitespace
   collapsed and trimmed, quoted with escaped spaces; words OR-ed. *)
let make_tsquery (ws : string list) : string =
  let norm w =
    let b = Buffer.create (String.length w) in
    String.iter (fun c -> if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c = '_' then Buffer.add_char b c else Buffer.add_char b ' ') w;
    let parts = String.split_on_char ' ' (Buffer.contents b) |> List.filter (fun s -> s <> "") in
    "\"" ^ String.concat "\\ " parts ^ "\""
  in
  String.concat " | " (List.map norm ws)

let both_scopes = [ Content; Trending ]
let scopes_of (l : string list) = if l = [] then both_scopes else List.filter_map cmr_scope_of_string_opt l

(* Set by a daemon whose caller may already hold a transaction on [dbh] (the importer's
   lean.transaction_per_event): then [in_transaction] runs [f] inside that one. Default: never. *)
let already_in_transaction : (Postgres.dbh -> bool) ref = ref (fun _ -> false)

(* Run [f] inside a transaction on [dbh]; rollback on any exception (re-raised). *)
let in_transaction (dbh : Postgres.dbh) (f : unit -> unit) : unit =
  if !already_in_transaction dbh then f ()
  else begin
  PGOCaml.begin_work dbh;
  match f () with
  | () -> PGOCaml.commit dbh
  | exception e ->
      (try PGOCaml.rollback dbh with _ -> ());
      raise e
  end

(* [legacy] (default true): also write cmr_pubkeys_parent, cmr_words and cmr_hashtags, which nothing
   reads any more (the _2 tables replaced the last two); the importer's lean.no_cmr_legacy passes
   false. *)
let import ?(legacy = true) ~(dbh : Postgres.dbh) (user_pubkey : string) (cmr : t) : unit =
  in_transaction dbh (fun () ->
      ignore [%pgsql dbh "delete from cmr_pubkeys_scopes where user_pubkey = $user_pubkey"];
      if legacy then ignore [%pgsql dbh "delete from cmr_pubkeys_parent where user_pubkey = $user_pubkey"];
      ignore [%pgsql dbh "delete from cmr_groups where user_pubkey = $user_pubkey"];
      ignore [%pgsql dbh "delete from cmr_pubkeys_allowed where user_pubkey = $user_pubkey"];
      ignore [%pgsql dbh "delete from cmr_threads where user_pubkey = $user_pubkey"];
      if legacy then ignore [%pgsql dbh "delete from cmr_hashtags where user_pubkey = $user_pubkey"];
      if legacy then ignore [%pgsql dbh "delete from cmr_words where user_pubkey = $user_pubkey"];
      ignore [%pgsql dbh "delete from cmr_hashtags_2 where user_pubkey = $user_pubkey"];
      ignore [%pgsql dbh "delete from cmr_words_2 where user_pubkey = $user_pubkey"];
      Hashtbl.iter
        (fun pubkey (parent, scopes) ->
          List.iter
            (fun scope -> ignore [%pgsql dbh "insert into cmr_pubkeys_scopes (user_pubkey, pubkey, scope) values ($user_pubkey, $pubkey, $scope)"])
            (scopes_of scopes);
          if legacy then
            ignore [%pgsql dbh "insert into cmr_pubkeys_parent (user_pubkey, pubkey, parent) values ($user_pubkey, $pubkey, $parent)"])
        cmr.cmr_pubkeys;
      List.iter
        (fun (name, scopes) ->
          match cmr_grp_of_string_opt name with
          | None -> ()
          | Some grp ->
              List.iter (fun scope -> ignore [%pgsql dbh "insert into cmr_groups (user_pubkey, grp, scope) values ($user_pubkey, $grp, $scope)"]) (scopes_of scopes))
        cmr.cmr_groups;
      List.iter (fun pubkey -> ignore [%pgsql dbh "insert into cmr_pubkeys_allowed (user_pubkey, pubkey) values ($user_pubkey, $pubkey)"]) cmr.cmr_pubkeys_allowed;
      List.iter
        (fun scope ->
          List.iter (fun event_id -> ignore [%pgsql dbh "insert into cmr_threads (user_pubkey, event_id, scope) values ($user_pubkey, $event_id, $scope)"]) cmr.cmr_threads;
          if legacy then begin
            List.iter (fun hashtag -> ignore [%pgsql dbh "insert into cmr_hashtags (user_pubkey, hashtag, scope) values ($user_pubkey, $hashtag, $scope)"]) cmr.cmr_hashtags;
            List.iter (fun word -> ignore [%pgsql dbh "insert into cmr_words (user_pubkey, word, scope) values ($user_pubkey, $word, $scope)"]) cmr.cmr_words
          end;
          if cmr.cmr_hashtags <> [] then begin
            let q = make_tsquery cmr.cmr_hashtags in
            ignore [%pgsql dbh "insert into cmr_hashtags_2 (user_pubkey, scope, hashtags) values ($user_pubkey, $scope, to_tsquery('simple', $q))"]
          end;
          if cmr.cmr_words <> [] then begin
            let q = make_tsquery cmr.cmr_words in
            ignore [%pgsql dbh "insert into cmr_words_2 (user_pubkey, scope, words) values ($user_pubkey, $scope, to_tsquery('simple', $q))"]
          end)
        both_scopes)

(* Julia send_event_to_ws_connector for the user's live events hosted in the last hour: a synthetic
   kind-11000001 event on the primal_events channel tells live-feed subscribers that this user's
   moderation changed. (The 32-char zero id/pubkey are Julia's quirk, kept verbatim.) *)
let notify_user_live_events ~(dbh : Postgres.dbh) (pubkey : string) : unit =
  let kind = 30311L in
  List.iter
    (fun ej ->
      match ej with
      | None -> ()
      | Some ej -> (
          match Nostr.of_json (Yojson.Safe.from_string ej) with
          | exception _ -> ()
          | e ->
              let identifier = ref None and host = ref false in
              List.iter
                (fun tg ->
                  match Nostr.tag_name tg with
                  | Some "d" when Nostr.tag_len tg >= 2 -> identifier := Nostr.tag_field tg 1
                  | Some "p" when Nostr.tag_len tg >= 4 && Option.map String.lowercase_ascii (Nostr.tag_field tg 3) = Some "host" -> host := true
                  | _ -> ())
                e.tags;
              if !host then begin
                let a = Printf.sprintf "%Ld:%s:%s" kind (Hex_util.encode pubkey) (Option.value !identifier ~default:"") in
                let payload =
                  Yojson.Safe.to_string
                    (`Assoc
                      [ ("id", `String (String.make 32 '0')); ("pubkey", `String (String.make 32 '0')); ("sig", `String (String.make 64 '0'));
                        ("created_at", `Int (Utils.current_time ())); ("kind", `Int 11_000_001); ("content", `String "");
                        ("tags", `List [ `List [ `String "a"; `String a ] ]) ])
                in
                ignore [%pgsql dbh "select pg_notify('primal_events', $payload)"]
              end))
    [%pgsql dbh "select user_live_events($kind, $pubkey)"]
