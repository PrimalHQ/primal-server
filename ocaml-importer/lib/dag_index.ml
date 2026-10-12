(* "Instant" DAG indexers for a single just-imported event, mirroring what the Julia API's
   import_events path runs inside the importer node right after import (app.jl:1954-1965):
   DAG.import_basic_tags, import_zap_receipts, import_poll_votes and import_event_mentions for
   that event's imported_at window. The periodic DAG runner (dag_runner.jl, Phase 6 in OCaml)
   covers the same tables for everything else; these per-event versions exist so an event a user
   just posted through the API is searchable/threaded immediately instead of after the next
   DAG segment.

   Table names are the live hashed DAG outputs (public.basic_tags etc. are views on them); the
   SQL is [%pgsql]-checked against them. *)

module CS = Cache_storage
module CSE = Cache_storage_ext
module PGOCaml = Postgres.PGOCaml

let i64 = Int64.of_int

(* DAG.import_basic_tags (dag.jl:865), restricted to one event id. Julia filters hex ids with
   `~* '^[0-9a-f]{64}$'`; the `$` would read as a ppx parameter here, so the same test is
   written as a length check plus an anchored prefix match. *)
let import_basic_tags (est : CS.est) (e : Nostr.t) : unit =
  let dbh = est.CS.dbh in
  let id = e.id in
  (* the new kind 1/6/7 `e` tags that point at a stored article version also go to
     reads_interactions (migration 2007; the reads feed's candidate set) *)
  ignore
    [%pgsql dbh
      "with ins as ( \
         insert into basic_tags_6_62c3d17c2f (id, pubkey, created_at, kind, tag, arg1, arg3, imported_at) \
         select * from ( \
           select id, pubkey, created_at, kind, t->>0 as tag, decode(t->>1, 'hex') as arg1, \
                  coalesce(t->>3, '') as arg3, imported_at from ( \
             select id, pubkey, created_at, kind, jsonb_array_elements(tags) as t, imported_at \
             from event where id = $id and jsonb_array_length(tags) < 50 \
           ) a where t->>0 in ('p', 'P', 'e') and length(t->>1) = 64 and t->>1 ~* '^[0-9a-f]{64}' \
         ) b on conflict do nothing \
         returning pubkey, kind, tag, arg1) \
       insert into reads_interactions (pubkey, eid) \
       select distinct ins.pubkey, ins.arg1 from ins \
       where ins.tag = 'e' and ins.kind in (1, 6, 7) and exists (select 1 from reads_versions_12_b537d4df66 rv where rv.eid = ins.arg1) \
       on conflict do nothing"]

(* DAG.parse_zap_receipt (dag.jl:1847) + import_zap_receipts insert for one receipt. *)
let import_zap_receipt (est : CS.est) (e : Nostr.t) : unit =
  if e.kind = Nostr.kind_zap_receipt then begin
    let eid = ref None and receiver = ref None and sender = ref None and amount = ref 0 in
    List.iter
      (fun tg ->
        if Nostr.tag_len tg >= 2 then
          match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
          | Some "e", Some h -> ( match CS.decode32 h with Some x -> eid := Some x | None -> ())
          | Some "p", Some h -> ( match CS.decode32 h with Some x -> receiver := Some x | None -> ())
          | Some "P", Some h -> ( match CS.decode32 h with Some x -> sender := Some x | None -> ())
          | Some "a", Some a -> (
              match CS.parse_a_tag a with
              | Some (kind, pubkey, identifier) -> (
                  match CS.lookup_parametrized_replaceable_event est ~kind ~pubkey ~identifier with
                  | Some x -> eid := Some x
                  | None -> ())
              | None -> ())
          | Some "bolt11", Some b -> (
              match CS.parse_bolt11 b with
              | Some a when a <= CS.max_satszapped -> amount := a
              | _ -> ())
          | _ -> ())
      e.tags;
    match (!eid, !receiver, !sender) with
    | Some target_eid, Some receiver, Some sender when !amount > 0 -> (
        let dbh = est.CS.dbh in
        let id = e.id and created_at = i64 e.created_at and satszapped = i64 !amount in
        match [%pgsql dbh "select imported_at from event where id = $id"] with
        | imported_at :: _ ->
            ignore
              [%pgsql dbh
                "insert into zap_receipts_1_9fe40119b2 (eid, created_at, target_eid, sender, receiver, satszapped, imported_at) \
                 values ($id, $created_at, $target_eid, $sender, $receiver, $satszapped, $imported_at) on conflict do nothing"]
        | [] -> ())
    | _ -> ()
  end

(* DAG.import_event_mentions (dag.jl:1875): mention tags WITHOUT resolving a-tags to event ids
   (the table keeps (argpubkey, argkind, argid) for those). *)
let import_event_mentions (est : CS.est) (e : Nostr.t) : unit =
  let dbh = est.CS.dbh in
  let eid = e.id in
  CSE.for_mentiones ~resolve_a:false est e (fun tg ->
      match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
      | Some ("e" as tag), Some h -> (
          match CS.decode32 h with
          | Some argeid ->
              ignore
                [%pgsql dbh
                  "insert into event_mentions_1_a056fb6737 (eid, tag, argeid, argpubkey, argkind, argid) \
                   values ($eid, $tag, $argeid, null, null, null) on conflict do nothing"]
          | None -> ())
      | Some ("p" as tag), Some h -> (
          match CS.decode32 h with
          | Some argpubkey ->
              ignore
                [%pgsql dbh
                  "insert into event_mentions_1_a056fb6737 (eid, tag, argeid, argpubkey, argkind, argid) \
                   values ($eid, $tag, null, $argpubkey, null, null) on conflict do nothing"]
          | None -> ())
      | Some ("a" as tag), Some a -> (
          match CS.parse_a_tag a with
          | Some (kind, argpubkey, identifier) ->
              (* Julia replaces invalid UTF-8 in the identifier with U+FFFD; Yojson already
                 rejected invalid UTF-8 at parse time, so the identifier is valid here. *)
              let argkind = i64 kind in
              ignore
                [%pgsql dbh
                  "insert into event_mentions_1_a056fb6737 (eid, tag, argeid, argpubkey, argkind, argid) \
                   values ($eid, $tag, null, $argpubkey, $argkind, $identifier) on conflict do nothing"]
          | None -> ())
      | _ -> ())

(* {1 Poll stats} (DAG.update_single_poll_stats, dag.jl:2048) *)

type opt_counts = { mutable votes : int; mutable satszapped : int }

let opts_to_json (opts : (string, opt_counts) Hashtbl.t) : string =
  let fields =
    Hashtbl.fold
      (fun k v acc ->
        (k, `Assoc [ ("votes", `Int v.votes); ("satszapped", `Int v.satszapped) ]) :: acc)
      opts []
  in
  Yojson.Safe.to_string (`Assoc (List.sort (fun (a, _) (b, _) -> compare a b) fields))

let upsert_user_vote (est : CS.est) ~poll_id ~pubkey ~option_id ~created_at ~vote_eid : unit =
  let dbh = est.CS.dbh in
  let created_at = i64 created_at in
  ignore
    [%pgsql dbh
      "insert into poll_user_votes_1_5fa4d82e64 (poll_id, pubkey, option_id, created_at, vote_eid) \
       values ($poll_id, $pubkey, $option_id, $created_at, $vote_eid) \
       on conflict (poll_id, pubkey) do update set option_id = excluded.option_id, created_at = excluded.created_at, vote_eid = excluded.vote_eid"]

(* Parse the zap receipt's description tag: (sender pubkey, amount msats, poll_option). *)
let parse_zap_description (d : string) : string option * int option * string option =
  try
    let desc = Yojson.Safe.from_string d in
    let sender =
      match Yojson.Safe.Util.member "pubkey" desc with `String p -> CS.decode32 p | _ -> None
    in
    let amount = ref None and option_id = ref None in
    (match Yojson.Safe.Util.member "tags" desc with
    | `List dtags ->
        List.iter
          (function
            | `List (`String "amount" :: `String a :: _) -> (
                match int_of_string_opt a with Some n -> amount := Some n | None -> ())
            | `List (`String "poll_option" :: `String o :: _) when !option_id = None ->
                option_id := Some o
            | _ -> ())
          dtags
    | _ -> ());
    (sender, !amount, !option_id)
  with _ -> (None, None, None)

let update_single_poll_stats (est : CS.est) (poll_id : string) : bool =
  let dbh = est.CS.dbh in
  let kpoll = i64 Nostr.kind_poll and kzap_poll = i64 Nostr.kind_zap_poll in
  match
    [%pgsql dbh "select kind, tags from event where id = $poll_id and kind in ($kpoll, $kzap_poll)"]
  with
  | [] -> false
  | (poll_kind, poll_tags) :: _ ->
      let poll_kind = Int64.to_int poll_kind in
      let poll_tags = CSE.tags_of_json poll_tags in
      let opts : (string, opt_counts) Hashtbl.t = Hashtbl.create 8 in
      let opt_tag = if poll_kind = Nostr.kind_poll then "option" else "poll_option" in
      List.iter
        (fun tg ->
          if Nostr.tag_len tg >= 2 && Nostr.tag_name tg = Some opt_tag then
            match Nostr.tag_field tg 1 with
            | Some o -> Hashtbl.replace opts o { votes = 0; satszapped = 0 }
            | None -> ())
        poll_tags;
      if Hashtbl.length opts = 0 then false
      else begin
        if poll_kind = Nostr.kind_poll then begin
          let kvote = i64 Nostr.kind_poll_vote in
          let votes =
            [%pgsql dbh
              "select e.id, e.pubkey, e.created_at, e.tags from basic_tags_6_62c3d17c2f bt join event e on e.id = bt.id \
               where bt.arg1 = $poll_id and bt.tag = 'e' and bt.kind = $kvote"]
          in
          (* latest vote per (human) pubkey *)
          let user_votes : (string, string * int * string) Hashtbl.t = Hashtbl.create 16 in
          List.iter
            (fun (vote_eid, pk, created_at, tags) ->
              if CSE.ext_is_human est pk then begin
                let created_at = Int64.to_int created_at in
                List.iter
                  (fun tg ->
                    if Nostr.tag_len tg >= 2 && Nostr.tag_name tg = Some "response" then
                      match Nostr.tag_field tg 1 with
                      | Some o when Hashtbl.mem opts o -> (
                          match Hashtbl.find_opt user_votes pk with
                          | Some (_, prev_at, _) when created_at <= prev_at -> ()
                          | _ -> Hashtbl.replace user_votes pk (vote_eid, created_at, o))
                      | _ -> ())
                  (CSE.tags_of_json tags)
              end)
            votes;
          Hashtbl.iter
            (fun pubkey (vote_eid, created_at, option_id) ->
              let o = Hashtbl.find opts option_id in
              o.votes <- o.votes + 1;
              upsert_user_vote est ~poll_id ~pubkey ~option_id ~created_at ~vote_eid)
            user_votes
        end
        else begin
          let tag_int name =
            List.find_map
              (fun tg ->
                if Nostr.tag_len tg >= 2 && Nostr.tag_name tg = Some name then
                  Option.bind (Nostr.tag_field tg 1) int_of_string_opt
                else None)
              poll_tags
          in
          let value_minimum = tag_int "value_minimum" and value_maximum = tag_int "value_maximum" in
          (* NIP-69: equal bounds -> one zap per option per participant *)
          let one_zap_per_option =
            match (value_minimum, value_maximum) with Some a, Some b -> a = b | _ -> false
          in
          let kzap = i64 Nostr.kind_zap_receipt in
          let zaps =
            [%pgsql dbh
              "select e.id, e.created_at, e.tags from basic_tags_6_62c3d17c2f bt join event e on e.id = bt.id \
               where bt.arg1 = $poll_id and bt.tag = 'e' and bt.kind = $kzap"]
          in
          let user_latest : (string, string * int * string) Hashtbl.t = Hashtbl.create 16 in
          let seen_user_option = Hashtbl.create 16 in
          List.iter
            (fun (zap_eid, zap_created_at, zap_tags) ->
              let zap_created_at = Int64.to_int zap_created_at in
              let option_id = ref None and amount_msats = ref 0 and zap_sender = ref None in
              List.iter
                (fun tg ->
                  if Nostr.tag_len tg >= 2 then
                    match (Nostr.tag_name tg, Nostr.tag_field tg 1) with
                    | Some "poll_option", Some o -> option_id := Some o
                    | Some "description", Some d ->
                        let sender, amount, opt = parse_zap_description d in
                        (match sender with Some s -> zap_sender := Some s | None -> ());
                        (match amount with Some a -> amount_msats := a | None -> ());
                        if !option_id = None then option_id := opt
                    | _ -> ())
                (CSE.tags_of_json zap_tags);
              (if !amount_msats = 0 then
                 match
                   [%pgsql dbh
                     "select amount_sats from og_zap_receipts_1_dc85307383 where zap_receipt_id = $zap_eid limit 1"]
                 with
                 | sats :: _ -> amount_msats := Int64.to_int sats * 1000
                 | [] -> ());
              match (!option_id, !zap_sender) with
              | Some option_id, Some sender_pk
                when Hashtbl.mem opts option_id && CSE.ext_is_human est sender_pk ->
                  let amount_sats = !amount_msats / 1000 in
                  let below = match value_minimum with Some m -> amount_sats < m | None -> false in
                  let above = match value_maximum with Some m -> amount_sats > m | None -> false in
                  let dup =
                    one_zap_per_option && Hashtbl.mem seen_user_option (sender_pk, option_id)
                  in
                  if not (below || above || dup) then begin
                    Hashtbl.replace seen_user_option (sender_pk, option_id) ();
                    let o = Hashtbl.find opts option_id in
                    o.votes <- o.votes + 1;
                    o.satszapped <- o.satszapped + amount_sats;
                    match Hashtbl.find_opt user_latest sender_pk with
                    | Some (_, prev_at, _) when zap_created_at <= prev_at -> ()
                    | _ -> Hashtbl.replace user_latest sender_pk (zap_eid, zap_created_at, option_id)
                  end
              | _ -> ())
            zaps;
          Hashtbl.iter
            (fun pubkey (zap_eid, created_at, option_id) ->
              upsert_user_vote est ~poll_id ~pubkey ~option_id ~created_at ~vote_eid:zap_eid)
            user_latest
        end;
        let options = opts_to_json opts in
        ignore
          [%pgsql dbh
            "insert into poll_stats_1_d8de047040 (event_id, options, updated_at) \
             values ($poll_id, $options, extract(epoch from now())::bigint) \
             on conflict (event_id) do update set options = excluded.options, updated_at = excluded.updated_at"];
        true
      end

(* DAG.import_poll_votes (dag.jl:2214) for one event: the polls this vote/zap references. *)
let import_poll_votes (est : CS.est) (e : Nostr.t) : unit =
  if e.kind = Nostr.kind_poll_vote || e.kind = Nostr.kind_zap_receipt then begin
    let dbh = est.CS.dbh in
    let id = e.id in
    let polls =
      [%pgsql dbh "select distinct arg1 from basic_tags_6_62c3d17c2f where id = $id and tag = 'e'"]
    in
    List.iter (fun poll_id -> ignore (update_single_poll_stats est poll_id)) polls
  end

(* Everything the Julia import_events path indexes for one event, each step isolated. *)
let index_event ?(poll_votes_enabled = true) (est : CS.est) (e : Nostr.t) : unit =
  let step name f =
    try f () with
    | Eio.Cancel.Cancelled _ as ex -> raise ex
    | exn -> Printf.eprintf "dag_index: %s: %s\n%!" name (Printexc.to_string exn)
  in
  step "basic_tags" (fun () -> import_basic_tags est e);
  step "zap_receipts" (fun () -> import_zap_receipt est e);
  if poll_votes_enabled then step "poll_votes" (fun () -> import_poll_votes est e);
  step "event_mentions" (fun () -> import_event_mentions est e)
