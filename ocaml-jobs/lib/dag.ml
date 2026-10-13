(* dag_runner.jl + the live DAG_20240803_1 pipeline of dag.jl: every [dag_period_s] the window
   [since, until=now] is pushed through the nodes in pipeline order; each node splits its window
   into segments of imported_at (1 day or 90 days) that coverages_1_8656fc443b has not covered yet,
   runs every segment in its own transaction (up to [dag_tasks] in parallel, some nodes
   sequentially), and records the coverage. An exception in a segment ends this run (the next run
   retries). The hashed output tables are the live ones (public.<name> views are the API contract);
   their presence is asserted at startup. [dag_dry_run] rolls every segment back and records no
   coverage, so the whole pipeline can be exercised while Julia's runner still owns the tables. *)

open Eio.Std
module CS = Importer.Cache_storage
module CSE = Importer.Cache_storage_ext
module DI = Importer.Dag_index
module PGOCaml = Postgres.PGOCaml

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [dag] %s\n%!" (Procinfo.timestamp ()) s) fmt
let i64 = Int64.of_int
let day = 24 * 3600

module T = struct
  let basic_tags = "basic_tags_6_62c3d17c2f"
  let zap_receipts = "zap_receipts_1_9fe40119b2"
  let poll_stats = "poll_stats_1_d8de047040"
  let poll_user_votes = "poll_user_votes_1_5fa4d82e64"
  let a_tags = "a_tags_1_7d98c5333f"
  let reads = "reads_12_68c6bbfccd"
  let reads_versions = "reads_versions_12_b537d4df66"
  let pubkey_media_cnt = "pubkey_media_cnt_1_b5e2a488b1"
  let pubkey_content_zap_cnt = "pubkey_content_zap_cnt_1_236df2f369"
  let advsearch = "advsearch_5_d7da6f551e"
  let event_mentions = "event_mentions_1_a056fb6737"
  let note_length = "note_length_1_15d66ffae6"
  let note_stats = "note_stats_1_07d205f278"
  let coverages = "coverages_1_8656fc443b"
  let all = [ basic_tags; zap_receipts; poll_stats; poll_user_votes; a_tags; reads; reads_versions; pubkey_media_cnt; pubkey_content_zap_cnt; advsearch; event_mentions; note_length; note_stats; coverages ]
  let cov t = "postgres-p0-" ^ t
end

type pools = { cache : Postgres.pool; mem : Postgres.pool }

let with_est (p : pools) (f : CS.est -> 'a) : 'a =
  Postgres.use p.cache (fun dbh -> Postgres.use p.mem (fun mem_dbh -> f { CS.cfg = CS.default_config; dbh; mem_dbh }))

type run = { since : int; until : int; running : bool Atomic.t; dry_run : bool; ignore_coverage : bool; tasks : int; stop : unit Promise.t; pools : pools; poll_votes : bool; verbose : bool }

let coverages (dbh : Postgres.dbh) ~(cov : string) : (int * int) list =
  [%pgsql dbh "select t, t2 from coverages_1_8656fc443b where name = $cov"] |> List.map (fun (t, t2) -> (Int64.to_int t, Int64.to_int t2))

(* The end of the contiguous coverage of every current node (every name under T.cov of a table in
   T.all), the smallest of them: nothing is uncovered before it, so a restarted runner can begin
   there instead of walking from dag_since through years of covered segments. A hole in a node's
   coverage (a failed segment behind covered ones) stops that node's frontier at the hole; the
   nodes with a bounded lookback are left out, and so is poll_stats when poll votes are off (it
   writes no coverage then, so its old coverage would pin the frontier where it was disabled). *)
let coverage_frontier ~(poll_votes : bool) (dbh : Postgres.dbh) : int option =
  let rows = [%pgsql dbh "select name, t, t2 from coverages_1_8656fc443b order by name, t"] in
  (* nodes with their own lookback (advsearch 30 d, note_length 15 d, note_stats 30 d, update_user_search
     3 d) never cover history contiguously and bound themselves anyway *)
  let full_history =
    List.filter (fun t -> t <> T.advsearch && t <> T.note_length && t <> T.note_stats && t <> T.coverages && (poll_votes || t <> T.poll_stats)) T.all
  in
  let current name = List.exists (fun t -> String.starts_with ~prefix:(T.cov t) name) full_history in
  let by_name = Hashtbl.create 32 in
  List.iter (fun (name, t, t2) -> if current name then Hashtbl.replace by_name name ((Int64.to_int t, Int64.to_int t2) :: (try Hashtbl.find by_name name with Not_found -> []))) rows;
  Hashtbl.fold
    (fun _ segs acc ->
      let segs = List.rev segs in
      let rec walk frontier = function (t, t2) :: rest when t <= frontier -> walk (max frontier t2) rest | _ -> frontier in
      let f = match segs with (t, t2) :: rest -> walk t2 rest | [] -> 0 in
      Some (match acc with Some a -> min a f | None -> f))
    by_name None

let set_coverage (dbh : Postgres.dbh) ~(cov : string) ~t ~t2 : unit =
  let t = i64 t and t2 = i64 t2 in
  ignore [%pgsql dbh "insert into coverages_1_8656fc443b (name, t, t2) values ($cov, $t, $t2) on conflict (name, t) do update set t = $t, t2 = $t2"]

(* process_segments: the uncovered pieces of [since, until] in steps of [step] (one segment when
   [step] is None), each run by [f] inside a transaction on its own connections *)
let process_segments (r : run) ~(cov : string) ?since ?until ?step ?(sequential = false) ?(parallel_workers = 0) (f : CS.est -> int -> int -> unit) : unit =
  let since = Option.value since ~default:r.since and until = Option.value until ~default:r.until in
  if not (since = 0 && until = 0) && Atomic.get r.running then begin
    let segs =
      match step with
      | None -> [ (-1, since, until) ]
      | Some step ->
          let done_ = if r.ignore_coverage then [] else with_est r.pools (fun est -> coverages est.CS.dbh ~cov) in
          let rec go t acc =
            if t > until then acc
            else
              let acc =
                match List.assoc_opt t done_ with
                | None -> (t, max t since, min (t + step) until) :: acc
                (* a piece already covered past [until] is skipped: running it would write [until] as
                   the segment's end, moving its coverage back *)
                | Some t2 when t2 - t < step && max t2 since < min (t + step) until -> (t, max t2 since, min (t + step) until) :: acc
                | Some _ -> acc
              in
              go (t + step) acc
          in
          List.rev (go (since / step * step) [])
    in
    let run_one (t, t1, t2) =
      if Atomic.get r.running && not (Promise.is_resolved r.stop) then
        try
          if r.verbose then log "%s: %d .. %d" cov t1 t2;
          with_est r.pools (fun est ->
              let dbh = est.CS.dbh in
              Postgres.exec dbh "begin";
              (try
                 Postgres.exec dbh (Printf.sprintf "set local max_parallel_workers_per_gather = %d" parallel_workers);
                 f est t1 t2;
                 if r.dry_run then Postgres.exec dbh "rollback" else Postgres.exec dbh "commit"
               with e ->
                 (try Postgres.exec dbh "rollback" with _ -> ());
                 raise e);
              if Atomic.get r.running && t >= 0 && not r.dry_run then set_coverage dbh ~cov ~t ~t2)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            Atomic.set r.running false;
            log "%s [%d .. %d]: %s" cov t1 t2 (Printexc.to_string exn)
    in
    if sequential then List.iter run_one segs
    else begin
      let a = Array.of_list segs in
      for i = Array.length a - 1 downto 1 do
        let j = Random.int (i + 1) in
        let x = a.(i) in
        a.(i) <- a.(j);
        a.(j) <- x
      done;
      Fiber.List.iter ~max_fibers:r.tasks run_one (Array.to_list a)
    end
  end

(* {1 Row helpers} *)

let event_of_row (id, pubkey, created_at, kind, tags, content, sig_) : Nostr.t =
  { Nostr.id; pubkey; created_at = Int64.to_int created_at; kind = Int64.to_int kind; tags = CSE.tags_of_json (Option.value tags ~default:"[]"); content; sig_ }

let kinds_json (ks : int list) = Yojson.Safe.to_string (`List (List.map (fun k -> `Int k) ks))

(* the window's events of the given kinds, in id order *)
let events_in_window (dbh : Postgres.dbh) ~t1 ~t2 ~(kinds : int list) : Nostr.t list =
  let t1 = i64 t1 and t2 = i64 t2 and kinds_json = kinds_json kinds in
  [%pgsql dbh
    "select id, pubkey, created_at, kind, tags::text, content, sig from event \
     where imported_at >= $t1 and imported_at <= $t2 \
       and kind = any(array(select (a::text)::int8 from jsonb_array_elements_text($kinds_json::jsonb) x(a))) order by id"]
  |> List.map event_of_row

let utf8_length (s : string) : int =
  let n = ref 0 in
  String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr n) s;
  !n

(* {1 Nodes} *)

let basic_tags_node (r : run) =
  process_segments r ~cov:(T.cov T.basic_tags) ~step:day (fun est t1 t2 ->
      let dbh = est.CS.dbh in
      let t1 = i64 t1 and t2 = i64 t2 in
      (* the new kind 1/6/7 `e` tags that point at a stored article version also go to
         reads_interactions (migration 2007; the reads feed's candidate set) *)
      ignore
        [%pgsql dbh
          "with ins as ( \
             insert into basic_tags_6_62c3d17c2f (id, pubkey, created_at, kind, tag, arg1, arg3, imported_at) \
             select * from ( \
               select id, pubkey, created_at, kind, t->>0 as tag, decode(t->>1, 'hex') as arg1, coalesce(t->>3, '') as arg3, imported_at from ( \
                 select id, pubkey, created_at, kind, jsonb_array_elements(tags) as t, imported_at from event \
                 where imported_at >= $t1 and imported_at <= $t2 and jsonb_array_length(tags) < 50 \
               ) a where t->>0 in ('p', 'P', 'e') and length(t->>1) = 64 and t->>1 ~* '^[0-9a-f]{64}' \
             ) b on conflict do nothing \
             returning pubkey, kind, tag, arg1) \
           insert into reads_interactions (pubkey, eid) \
           select distinct ins.pubkey, ins.arg1 from ins \
           where ins.tag = 'e' and ins.kind in (1, 6, 7) and exists (select 1 from reads_versions_12_b537d4df66 rv where rv.eid = ins.arg1) \
           on conflict do nothing"])

let zap_receipts_node (r : run) =
  process_segments r ~cov:(T.cov T.zap_receipts) ~step:day (fun est t1 t2 ->
      List.iter (fun e -> try DI.import_zap_receipt est e with Eio.Cancel.Cancelled _ as ex -> raise ex | exn -> log "zap receipt %s: %s" (Nostr.id_hex e) (Printexc.to_string exn)) (events_in_window est.CS.dbh ~t1 ~t2 ~kinds:[ 9735 ]))

let poll_stats_node (r : run) =
  if r.poll_votes then
    process_segments r ~cov:(T.cov T.poll_stats ^ "/1") ~step:day (fun est t1 t2 ->
        let dbh = est.CS.dbh in
        let t1 = i64 t1 and t2 = i64 t2 in
        let polls = [%pgsql dbh "select distinct bt.arg1 from basic_tags_6_62c3d17c2f bt where bt.imported_at >= $t1 and bt.imported_at <= $t2 and bt.tag = 'e' and bt.kind in (1018, 9735)"] in
        List.iter (fun poll_id -> ignore (DI.update_single_poll_stats est poll_id)) polls)

let a_tags_node (r : run) =
  process_segments r ~cov:(T.cov T.a_tags) ~step:(90 * day) ~sequential:true ~parallel_workers:8 (fun est t1 t2 ->
      let dbh = est.CS.dbh in
      ignore
        (Postgres.query dbh
           "create temp table dag_a_tags_t on commit drop as \
            select id, kind, created_at, split_part(t->>1, ':', 1)::int8 as ref_kind, decode(split_part(t->>1, ':', 2), 'hex') as ref_pubkey, \
                   split_part(t->>1, ':', 3) as ref_identifier, coalesce(t->>4, '') as ref_arg4, imported_at \
            from (select id, kind, created_at, jsonb_array_elements(tags) as t, imported_at from event \
                  where imported_at >= $1 and imported_at <= $2 and jsonb_array_length(tags) < 50) a \
            where t->>0 = 'a' and split_part(t->>1, ':', 1) ~* '^[0-9]+$' and split_part(t->>1, ':', 2) ~* '^[0-9a-f]{64}$'"
           [ Some (string_of_int t1); Some (string_of_int t2) ]);
      Postgres.exec dbh ("insert into " ^ T.a_tags ^ " (eid, kind, created_at, ref_kind, ref_pubkey, ref_identifier, ref_arg4, imported_at) select * from dag_a_tags_t on conflict do nothing"))

let words (s : string) : int =
  let n = ref 0 and inword = ref false in
  String.iter (fun c -> let ws = c = ' ' || c = '\t' || c = '\n' || c = '\r' || c = '\012' || c = '\011' in if ws then inword := false else if not !inword then (inword := true; incr n)) s;
  !n

let reads_node (r : run) =
  let step = 90 * day in
  (* phase 1: the articles themselves *)
  process_segments r ~cov:(T.cov T.reads ^ "/1") ~step (fun est t1 t2 ->
      let dbh = est.CS.dbh in
      let rows =
        List.filter_map
          (fun (e : Nostr.t) ->
            let identifier = ref None and topics = ref [] and published_at = ref None and image = ref "" and summary = ref "" in
            List.iter
              (fun tg ->
                match tg with
                | `String "d" :: `String v :: _ -> identifier := Some v
                | `String "t" :: `String v :: _ -> topics := String.map (fun c -> if c = ' ' then '-' else c) v :: !topics
                | `String "published_at" :: `String v :: _ -> ( match int_of_string_opt (String.trim v) with Some p -> published_at := Some p | None -> ())
                | `String "image" :: `String v :: _ -> image := v
                | `String "summary" :: `String v :: _ -> summary := v
                | _ -> ())
              e.tags;
            match (!identifier, !published_at) with
            | Some identifier, Some published_at ->
                let lang, lang_prob = if e.content = "" then ("", 0.0) else match Langid.detect e.content with Some (c, p) -> (c, p) | None -> ("", 0.0) in
                Some (e, identifier, published_at, String.concat " " (List.rev !topics), words e.content, lang, lang_prob, !image, !summary)
            | _ -> None)
          (events_in_window dbh ~t1 ~t2 ~kinds:[ 30023 ])
      in
      let rows = List.stable_sort (fun ((a : Nostr.t), ia, _, _, _, _, _, _, _) ((b : Nostr.t), ib, _, _, _, _, _, _, _) -> compare (a.pubkey, ia) (b.pubkey, ib)) rows in
      List.iter
        (fun ((e : Nostr.t), identifier, published_at, topics, words, lang, lang_prob, image, summary) ->
          let pubkey = e.pubkey and eid = e.id and created_at = i64 e.created_at and published_at = i64 published_at and words = i64 words in
          (match [%pgsql dbh "select latest_created_at from reads_12_68c6bbfccd where pubkey = $pubkey and identifier = $identifier for update"] with
          | [] ->
              ignore
                [%pgsql dbh
                  "insert into reads_12_68c6bbfccd (pubkey, identifier, published_at, latest_eid, latest_created_at, likes, zaps, satszapped, replies, reposts, topics, words, lang, lang_prob, image, summary) \
                   values ($pubkey, $identifier, $published_at, $eid, $created_at, 0, 0, 0, 0, 0, to_tsvector('simple', $topics), $words, $lang, $lang_prob, $image, $summary)"]
          | latest :: _ ->
              if created_at > latest then
                ignore
                  [%pgsql dbh
                    "update reads_12_68c6bbfccd set latest_created_at = $created_at, latest_eid = $eid, words = $words, lang = $lang, lang_prob = $lang_prob, image = $image, summary = $summary \
                     where pubkey = $pubkey and identifier = $identifier"]);
          ignore [%pgsql dbh "insert into reads_versions_12_b537d4df66 (pubkey, identifier, eid) values ($pubkey, $identifier, $eid) on conflict do nothing"];
          (* the kind 1/6/7 `e` tags that reached this version before it was stored (migration 2007) *)
          ignore
            [%pgsql dbh
              "insert into reads_interactions (pubkey, eid) \
               select distinct bt.pubkey, bt.arg1 from basic_tags_6_62c3d17c2f bt \
               where bt.arg1 = $eid and bt.tag = 'e' and bt.kind in (1, 6, 7) \
               on conflict do nothing"])
        rows);
  (* phase 2: zaps *)
  process_segments r ~cov:(T.cov T.reads ^ "/2") ~step (fun est t1 t2 ->
      let dbh = est.CS.dbh in
      let t1 = i64 t1 and t2 = i64 t2 in
      ignore
        [%pgsql dbh
          "with a as (select rv.pubkey, rv.identifier, count(1) as zaps, sum(zr.satszapped) as satszapped from reads_versions_12_b537d4df66 rv, zap_receipts_1_9fe40119b2 zr \
                      where zr.imported_at >= $t1 and zr.imported_at <= $t2 and zr.target_eid = rv.eid group by (rv.pubkey, rv.identifier)) \
           update reads_12_68c6bbfccd set zaps = reads_12_68c6bbfccd.zaps + a.zaps, satszapped = reads_12_68c6bbfccd.satszapped + a.satszapped from a \
           where reads_12_68c6bbfccd.pubkey = a.pubkey and reads_12_68c6bbfccd.identifier = a.identifier"]);
  (* phase 3: likes *)
  process_segments r ~cov:(T.cov T.reads ^ "/3") ~step (fun est t1 t2 ->
      let dbh = est.CS.dbh in
      let t1 = i64 t1 and t2 = i64 t2 in
      ignore
        [%pgsql dbh
          "with a as (select rv.pubkey, rv.identifier, count(1) as cnt from reads_versions_12_b537d4df66 rv, basic_tags_6_62c3d17c2f bt \
                      where bt.imported_at >= $t1 and bt.imported_at <= $t2 and bt.kind = 7 and bt.arg1 = rv.eid group by (rv.pubkey, rv.identifier)) \
           update reads_12_68c6bbfccd set likes = likes + a.cnt from a where reads_12_68c6bbfccd.pubkey = a.pubkey and reads_12_68c6bbfccd.identifier = a.identifier"]);
  (* phase 4: replies (direct ones: every e/a tag of the reply marked root) *)
  process_segments r ~cov:(T.cov T.reads ^ "/4") ~step (fun est t1 t2 ->
      let dbh = est.CS.dbh in
      let t1 = i64 t1 and t2 = i64 t2 in
      let rows =
        [%pgsql dbh
          "with a as (select rv.pubkey, rv.identifier, er.reply_event_id from reads_versions_12_b537d4df66 rv, event_replies er \
                      where rv.eid = er.event_id and er.reply_created_at >= $t1 and er.reply_created_at <= $t2), \
                b as (select at.ref_pubkey as pubkey, at.ref_identifier as identifier, at.eid as reply_event_id from a_tags_1_7d98c5333f at \
                      where at.kind = 1 and at.ref_kind = 30023 and at.created_at >= $t1 and at.created_at <= $t2) \
           select * from ((select * from a) union all (select * from b)) c order by (c.pubkey, c.identifier)"]
      in
      let seen = Hashtbl.create 64 in
      List.iter
        (fun row ->
          match row with
          | Some pubkey, Some identifier, Some reid when not (Hashtbl.mem seen reid) -> (
              Hashtbl.replace seen reid ();
              match [%pgsql dbh "select tags::text from event where id = $reid"] with
              | tags :: _ ->
                  let tags = CSE.tags_of_json (Option.value tags ~default:"[]") in
                  let indirect = List.exists (fun tg -> match tg with `String ("e" | "a") :: _ -> Nostr.tag_len tg < 4 || Nostr.tag_field tg 3 <> Some "root" | _ -> false) tags in
                  if not indirect then ignore [%pgsql dbh "update reads_12_68c6bbfccd set replies = replies + 1 where pubkey = $pubkey and identifier = $identifier"]
              | [] -> ())
          | _ -> ())
        rows);
  (* phase 5: reposts *)
  process_segments r ~cov:(T.cov T.reads ^ "/5") ~step (fun est t1 t2 ->
      let dbh = est.CS.dbh in
      let t1 = i64 t1 and t2 = i64 t2 in
      ignore
        [%pgsql dbh
          "with a as (select rv.pubkey, rv.identifier, count(1) as cnt from reads_versions_12_b537d4df66 rv, basic_tags_6_62c3d17c2f bt \
                      where bt.imported_at >= $t1 and bt.imported_at <= $t2 and bt.kind = 6 and bt.arg1 = rv.eid group by (rv.pubkey, rv.identifier)) \
           update reads_12_68c6bbfccd set reposts = reposts + a.cnt from a where reads_12_68c6bbfccd.pubkey = a.pubkey and reads_12_68c6bbfccd.identifier = a.identifier"])

let pubkey_media_cnt_node (r : run) =
  process_segments r ~cov:(T.cov T.pubkey_media_cnt ^ "/1") ~step:(90 * day) (fun est t1 t2 ->
      let dbh = est.CS.dbh in
      let t1 = i64 t1 and t2 = i64 t2 in
      ignore
        [%pgsql dbh
          "with a as (select es.pubkey, count(distinct es.id) as cnt from event es, event_media em \
                      where es.imported_at >= $t1 and es.imported_at <= $t2 and es.id = em.event_id and es.kind = 1 group by (es.pubkey)) \
           insert into pubkey_media_cnt_1_b5e2a488b1 (pubkey, cnt) select pubkey, cnt from a \
           on conflict (pubkey) do update set cnt = pubkey_media_cnt_1_b5e2a488b1.cnt + excluded.cnt"])

let pubkey_content_zap_cnt_node (r : run) =
  process_segments r ~cov:(T.cov T.pubkey_content_zap_cnt ^ "/1") ~step:(90 * day) (fun est t1 t2 ->
      let dbh = est.CS.dbh in
      let t1 = i64 t1 and t2 = i64 t2 in
      ignore
        [%pgsql dbh
          "with a as (select zr.sender, count(1) as cnt from zap_receipts_1_9fe40119b2 zr where zr.imported_at >= $t1 and zr.imported_at <= $t2 group by (zr.sender)) \
           insert into pubkey_content_zap_cnt_1_236df2f369 (pubkey, cnt) select sender, cnt from a \
           on conflict (pubkey) do update set cnt = pubkey_content_zap_cnt_1_236df2f369.cnt + excluded.cnt"])

let image_exts = [ ".png"; ".gif"; ".jpg"; ".jpeg"; ".webp" ]
let video_exts = [ ".mp4"; ".mov"; ".3gp" ]
let audio_exts = [ ".wav"; ".mp3"; ".aac"; ".flac"; ".ogg" ]
let re_url = Str.regexp {|https?://\(www\.\)?[-a-zA-Z0-9@:%._+~#=\128-\255]+\.[a-zA-Z0-9]+[-a-zA-Z0-9@:%_+.~#?&/=\128-\255]*|}

let urls_of (content : string) : string list =
  let rec go pos acc = match Str.search_forward re_url content pos with i -> let u = Str.matched_string content in go (i + String.length u) (u :: acc) | exception Not_found -> List.rev acc in
  go 0 []

let ext_of (url : string) : string =
  let u = String.lowercase_ascii url in
  let path = match String.index_opt u '?' with Some i -> String.sub u 0 i | None -> u in
  let base = match String.rindex_opt path '/' with Some i -> String.sub path (i + 1) (String.length path - i - 1) | None -> path in
  match String.rindex_opt base '.' with Some i -> String.sub base i (String.length base - i) | None -> ""

let advsearch_node (r : run) ~now =
  let max_size = 200_000 in
  process_segments r ~cov:(T.cov T.advsearch) ~step:day ~since:(max r.since (now - (30 * day))) (fun est t1 t2 ->
      let dbh = est.CS.dbh in
      let kinds = [ 1; 1068; 6969; 30023; 20; 34235; 34236; 1111 ] in
      let t1_ = i64 t1 and t2_ = i64 t2 and kinds_json = kinds_json kinds in
      let replies = Hashtbl.create 1024 in
      List.iter
        (fun (id, pk) -> Hashtbl.replace replies id (Hex_util.encode pk))
        [%pgsql dbh
          "select ev1.id, ev2.pubkey from (select es.id from event es where es.imported_at >= $t1_ and es.imported_at <= $t2_ \
                    and es.kind = any(array(select (a::text)::int8 from jsonb_array_elements_text($kinds_json::jsonb) x(a)))) ev1, event ev2, basic_tags_6_62c3d17c2f bt1 \
           where ev1.id = bt1.id and bt1.arg3 in ('reply', 'root') and bt1.arg1 = ev2.id"];
      List.iter
        (fun (e : Nostr.t) ->
          if String.length e.content <= max_size then begin
            let hashtags = ref [] in
            CSE.for_hashtags e (fun h -> hashtags := h :: !hashtags);
            List.iter (fun tg -> match tg with `String "t" :: `String v :: _ -> hashtags := String.lowercase_ascii v :: !hashtags | _ -> ()) e.tags;
            let hashtags_c = String.concat " " (List.sort_uniq compare !hashtags) in
            let reply = Option.value (Hashtbl.find_opt replies e.id) ~default:"" in
            let mentions = ref [] in
            CSE.for_mentiones est e (fun tg -> match tg with `String "p" :: `String h :: _ when String.length h = 64 && Hex_util.decode_opt h <> None -> mentions := h :: !mentions | _ -> ());
            let mentions_c = String.concat " " (List.sort_uniq compare !mentions) in
            let filters = ref [] and urls = ref [] in
            List.iter
              (fun url ->
                let ext = ext_of url in
                let has l = List.exists (fun x -> String.starts_with ~prefix:x ext) l in
                if has image_exts then filters := "image" :: !filters
                else if has video_exts then filters := "video" :: !filters
                else if has audio_exts then filters := "audio" :: !filters
                else begin
                  filters := "link" :: !filters;
                  urls := String.map (fun c -> if c = '/' || c = '.' || c = ':' || c = '?' || c = '=' || c = '&' then ' ' else c) url :: !urls
                end)
              (urls_of e.content);
            let filters_c = String.concat " " (List.sort_uniq compare !filters) and urls_c = String.concat " " (List.rev !urls) in
            if String.length hashtags_c <= max_size && String.length mentions_c <= max_size && String.length urls_c <= max_size then begin
              let id = e.id and pubkey = e.pubkey and created_at = i64 e.created_at and kind = i64 e.kind and content = e.content in
              ignore
                [%pgsql dbh
                  "insert into advsearch_5_d7da6f551e (id, pubkey, created_at, kind, content_tsv, hashtag_tsv, reply_tsv, mention_tsv, filter_tsv, url_tsv) \
                   values ($id, $pubkey, $created_at, $kind, to_tsvector('simple', $content), to_tsvector('simple', $hashtags_c), to_tsvector('simple', $reply), \
                           to_tsvector('simple', $mentions_c), to_tsvector('simple', $filters_c), to_tsvector('simple', $urls_c)) on conflict do nothing"]
            end
          end)
        (events_in_window dbh ~t1 ~t2 ~kinds))

let event_mentions_node (r : run) =
  process_segments r ~cov:(T.cov T.event_mentions ^ "/1") ~step:day (fun est t1 t2 ->
      List.iter (fun e -> DI.import_event_mentions est e) (events_in_window est.CS.dbh ~t1 ~t2 ~kinds:[ 1; 30023; 6 ]))

let note_length_node (r : run) ~now =
  process_segments r ~cov:(T.cov T.note_length ^ "/1") ~step:day ~since:(max r.since (now - (15 * day))) (fun est t1 t2 ->
      let dbh = est.CS.dbh in
      let t1 = i64 t1 and t2 = i64 t2 in
      ignore
        [%pgsql dbh
          "insert into note_length_1_15d66ffae6 (eid, length) select id as eid, length(content) from event \
           where imported_at >= $t1 and imported_at <= $t2 and (kind = 1 or kind = 30023 or kind = 6) on conflict do nothing"])

let note_stats_node (r : run) ~now =
  process_segments r ~cov:(T.cov T.note_stats ^ "/1") ~step:day ~since:(max r.since (now - (30 * day))) (fun est t1 t2 ->
      let dbh = est.CS.dbh in
      let rank = match [%pgsql dbh "select humaness_threshold_trustrank()"] with Some r :: _ -> r | _ -> 0.0 in
      let peids = ref [] in
      List.iter
        (fun (e : Nostr.t) ->
          let pubkey = e.pubkey in
          match [%pgsql dbh "select 1 from pubkey_trustrank where pubkey = $pubkey and rank >= $rank"] with
          | [] -> ()
          | _ -> ( match CS.parse_parent_eid est e with Some parent when utf8_length e.content >= 600 -> peids := parent :: !peids | _ -> ()))
        (events_in_window dbh ~t1 ~t2 ~kinds:[ 1 ]);
      List.iter
        (fun peid ->
          ignore [%pgsql dbh "insert into note_stats_1_07d205f278 (eid, long_replies) values ($peid, 0) on conflict do nothing"];
          ignore [%pgsql dbh "update note_stats_1_07d205f278 set long_replies = long_replies + 1 where eid = $peid"])
        (List.sort compare !peids))

let update_user_search_node (r : run) ~now =
  process_segments r ~cov:"update_user_search/1/postgres-p0-human_override" ~step:day ~since:(max r.since (now - (3 * day))) (fun est t1 t2 ->
      let dbh = est.CS.dbh in
      let t1 = float_of_int t1 and t2 = float_of_int t2 in
      let pks = [%pgsql dbh "select ho.pubkey from human_override ho where ho.added_at >= to_timestamp($t1) and ho.added_at <= to_timestamp($t2) order by ho.pubkey"] in
      List.iter (fun pk -> ignore (CSE.update_user_search est pk)) pks)

(* default_pipeline order *)
let run_pipeline (r : run) : unit =
  let now = Utils.current_time () in
  List.iter
    (fun (name, f) ->
      if Atomic.get r.running && not (Promise.is_resolved r.stop) then begin
        let t0 = Unix.gettimeofday () in
        f ();
        if r.verbose then log "%s: %.1fs" name (Unix.gettimeofday () -. t0)
      end)
    [ ("basic_tags", fun () -> basic_tags_node r); ("zap_receipts", fun () -> zap_receipts_node r); ("poll_stats", fun () -> poll_stats_node r); ("a_tags", fun () -> a_tags_node r);
      ("reads", fun () -> reads_node r); ("pubkey_media_cnt", fun () -> pubkey_media_cnt_node r); ("pubkey_content_zap_cnt", fun () -> pubkey_content_zap_cnt_node r);
      ("advsearch", fun () -> advsearch_node r ~now); ("event_mentions", fun () -> event_mentions_node r); ("note_length", fun () -> note_length_node r ~now);
      ("note_stats", fun () -> note_stats_node r ~now); ("update_user_search", fun () -> update_user_search_node r ~now) ]

let assert_tables (dbh : Postgres.dbh) : unit =
  List.iter
    (fun t -> match [%pgsql dbh "select 1 from information_schema.tables where table_schema::text = 'public' and table_name::text = $t"] with [] -> failwith ("dag: output table missing: " ^ t) | _ -> ())
    T.all

let run ~(cfg : Config.t) ~net ~clock ~(stop : unit Promise.t) : unit =
  let statement_timeout_ms = cfg.dag_statement_timeout_s * 1000 in
  let pools = { cache = Postgres.make_pool ~statement_timeout_ms ~size:(cfg.dag_tasks + 2) cfg.cache_db; mem = Postgres.make_pool ~statement_timeout_ms ~size:(cfg.dag_tasks + 2) cfg.membership_db } in
  with_est pools (fun est ->
      assert_tables est.CS.dbh;
      (match [%pgsql (est.CS.dbh) "select humaness_threshold_trustrank()::float8"] with Some t :: _ -> CSE.humaness_threshold := t | _ -> ());
      log "humaness threshold %g" !CSE.humaness_threshold);
  let frontier = if cfg.dag_dry_run then None else with_est pools (fun est -> coverage_frontier ~poll_votes:cfg.dag_poll_votes_enabled est.CS.dbh) in
  let since = ref (match frontier with Some f when f > cfg.dag_since -> f | _ -> cfg.dag_since) in
  log "runner: since %d (config %d, coverage frontier %s), period %.0fs, tasks %d%s" !since cfg.dag_since
    (match frontier with Some f -> string_of_int f | None -> "none") cfg.dag_period_s cfg.dag_tasks
    (if cfg.dag_dry_run then ", DRY RUN (every segment rolled back, no coverage written)" else "");
  if cfg.dag_dry_run && cfg.dag_dry_run_window_s > 0 then begin
    (* one exercise of every node over the last [dag_dry_run_window_s] seconds, coverage ignored, all rolled back *)
    let until = Utils.current_time () in
    let r = { since = until - cfg.dag_dry_run_window_s; until; running = Atomic.make true; dry_run = true; ignore_coverage = true; tasks = cfg.dag_tasks; stop; pools; poll_votes = cfg.dag_poll_votes_enabled; verbose = true } in
    let t0 = Unix.gettimeofday () in
    run_pipeline r;
    log "dry run over %d s %s in %.1fs; idling" cfg.dag_dry_run_window_s (if Atomic.get r.running then "ok" else "FAILED") (Unix.gettimeofday () -. t0);
    Promise.await stop
  end
  else
    (* The run window is [since, min now (since + span)]. span follows the last run's cost (a run
       over w seconds that took d seconds sets it to w * target / d, target 30 s, at most doubling,
       halved on failure, 10 s .. 1 h), and the window is then shrunk until it holds at most
       [max_events] events (an indexed count on event.imported_at): the nodes load a window's events
       into memory and handle them one by one, so an import burst (the stage host's backfill, 4,000
       events/s) must not hand them millions at once. Runs that finish within a second repeat
       back-to-back (up to 500 per tick) so covered history after a restart is skipped quickly. The
       lag behind now is logged; it shrinks whenever the nodes outrun the importer. *)
    let span = ref 60 and target = 30.0 and max_span = 3600 and max_events = 200_000L in
    let count_events a b =
      with_est pools (fun est ->
          let a = i64 a and b = i64 b in
          match [%pgsql (est.CS.dbh) "select count(*) from event where imported_at >= $a and imported_at < $b"] with
          | Some n :: _ -> n
          | _ -> 0L)
    in
    let one_run () =
      let now = Utils.current_time () in
      let since_ = max !since 1672531200 in
      let rec fit sp = if sp <= 10 || count_events since_ (since_ + sp) <= max_events then sp else fit (sp / 2) in
      let sp = if since_ + !span >= now then !span else fit !span in
      let until = min now (since_ + sp) in
      let r = { since = since_; until; running = Atomic.make true; dry_run = cfg.dag_dry_run; ignore_coverage = false; tasks = cfg.dag_tasks; stop; pools; poll_votes = cfg.dag_poll_votes_enabled; verbose = cfg.dag_log } in
      let t0 = Unix.gettimeofday () in
      run_pipeline r;
      let ok = Atomic.get r.running in
      if ok && not cfg.dag_dry_run then since := until;
      let dur = Unix.gettimeofday () -. t0 in
      let w = max 1 (until - since_) in
      (span :=
         if ok then max 10 (min max_span (min (sp * 2) (int_of_float (float_of_int w *. target /. Float.max dur 0.5))))
         else max 10 (w / 2));
      if dur >= 1.0 || now - until <= 0 || not ok then
        log "run %s in %.1fs (window %d .. %d, next span %ds%s)" (if ok then "ok" else "FAILED") dur r.since until !span
          (if now - until > 0 then Printf.sprintf ", lag %ds" (now - until) else "");
      (ok, dur, now - until)
    in
    Periodic.run ~clock ~stop ~period:cfg.dag_period_s ~label:"dag" (fun () ->
        let rec go i =
          let ok, dur, lag = one_run () in
          if ok && dur < 1.0 && lag > 0 && i < 500 && not (Promise.is_resolved stop) then go (i + 1) else (ok, dur)
        in
        let ok, dur = go 0 in
        match cfg.pushgateway with
        | Some (host, port, job) -> (
            try Pushgateway.set_values ~net ~clock ~timeout:5.0 ~host ~port ~job [ ("dag_runner_duration", "gauge", Printf.sprintf "%.3f" dur); ("dag_runner_all_ok", "gauge", if ok then "1" else "0") ]
            with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log "pushgateway: %s" (Printexc.to_string exn))
        | None -> ())
