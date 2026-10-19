(* internal_services.jl purge_media_ and the MediaAnalysis moderation nodes that are primal-server
   code: block_media, inc_counter (bytea_props), purge_user_content (a POST to the private purger). *)

open Procgraph

let url_parts (u : string) : string * string = match Http.parse_url u with Some p -> (p.Http.host, (match String.index_opt p.path '?' with Some i -> String.sub p.path 0 i | None -> p.path)) | None -> ("", u)
let splitext (p : string) : string * string = let base = match String.rindex_opt p '/' with Some i -> String.sub p (i + 1) (String.length p - i - 1) | None -> p in match String.rindex_opt base '.' with Some i -> (String.sub p 0 (String.length p - (String.length base - i)), String.sub base i (String.length base - i)) | None -> (p, "")
let uuid4 () = let h = Hex_util.encode (String.init 16 (fun _ -> Char.chr (Random.int 256))) in Printf.sprintf "%s-%s-4%s-%x%s-%s" (String.sub h 0 8) (String.sub h 8 4) (String.sub h 13 3) (8 + Random.int 4) (String.sub h 17 3) (String.sub h 20 12)
let all_path_entries (cfg : Media_config.t) : Media_config.path_entry list = List.concat_map (fun (p : Media_config.paths) -> p.uploadfast @ p.upload @ p.cache) [ cfg.media_paths; cfg.media_paths_2 ]
let parent_dir (p : string) = match String.rindex_opt p '/' with Some i when i > 0 -> String.sub p 0 i | _ -> p

(* A path a purge may act on: a file name below the media root (as in the API's Moderation_http):
   never empty, "/", ending in "/" or with a ".." segment, which would name the root or a
   directory. *)
let file_path_ok (p : string) : bool =
  let n = String.length p in
  n > 1 && p.[0] = '/' && p.[n - 1] <> '/' && not (List.mem ".." (String.split_on_char '/' p))

type mb = { surl : string; mutable files : Pgj.t list; mutable media_urls : string list; mutable thumbnail_urls : string list; mutable short_urls : string list; mutable blossom_urls : string list; mutable upload_urls : string list; extra : (string * Pgj.t) list; reason : string option; pubkey : string option }

let mb_json (m : mb) : Pgj.t =
  let strs l = `List (List.rev_map (fun s -> `String s) l) in
  `Assoc ([ ("surl", `String m.surl); ("files", `List (List.rev m.files)); ("media_urls", strs m.media_urls); ("thumbnail_urls", strs m.thumbnail_urls); ("short_urls", strs m.short_urls); ("blossom_urls", strs m.blossom_urls); ("upload_urls", strs m.upload_urls) ] @ m.extra @ (match m.reason with Some r -> [ ("reason", `String r) ] | None -> []) @ (match m.pubkey with Some p -> [ ("pubkey", `String p) ] | None -> []))

(* files per purge_cache request: the single-file purge limit below Enterprise plans *)
let cloudflare_batch = 30

let rec chunks n l =
  let rec take k acc = function x :: r when k > 0 -> take (k - 1) (x :: acc) r | r -> (List.rev acc, r) in
  match l with [] -> [] | _ -> let c, r = take n [] l in c :: chunks n r

(* the Cloudflare cache of these file URLs, cloudflare_batch per request *)
let cloudflare_purge (ctx : ctx) ~zone_id ~api_key (file_urls : string list) : unit =
  List.iter
    (fun files ->
      let n = List.length files and all = String.concat " " files in
      match Http.request ~net:ctx.net ~clock:ctx.clock ~timeout:20.0 ~meth:"POST" ~headers:[ ("Authorization", "Bearer " ^ api_key); ("Content-Type", "application/json") ] ~body:(Yojson.Safe.to_string (`Assoc [ ("files", `List (List.map (fun f -> `String f) files)) ])) ("https://api.cloudflare.com/client/v4/zones/" ^ zone_id ^ "/purge_cache") with
      | Some r when r.status = 200 -> ()
      | Some r -> log "cloudflare purge (%d): HTTP %d: %s" n r.status all
      | None -> log "cloudflare purge (%d) failed: %s" n all)
    (chunks cloudflare_batch file_urls)

(* InternalServices.purge_media_ *)
(* storage lookups of one purged URL at a time *)
let purge_parallelism = 8

let purge_media (ctx : ctx) ~(pubkey_hex : string option) ~(surl : string) ~(reason : string option) ~(extra : (string * Pgj.t) list) ~(block_all_uploads : bool) ~(clear_cache : bool) ?(s3_backup = true) ?(late = false) () : unit =
  let cfg = ctx.cfg in
  (* the Cloudflare cache purges, collected (once per file URL) and sent in batches when the purge
     ends, also when it fails part way *)
  let cf_files = ref [] and cf_seen = Hashtbl.create 16 in
  let cf_add u = if not (Hashtbl.mem cf_seen u) then (Hashtbl.replace cf_seen u (); cf_files := u :: !cf_files) in
  let flush_cf () =
    match (cfg.cloudflare_cache, List.rev !cf_files) with
    | Some (zone_id, api_key), (_ :: _ as files) -> (
        cf_files := [];
        try cloudflare_purge ctx ~zone_id ~api_key files with Eio.Cancel.Cancelled _ as e -> raise e | e -> log "cloudflare purge: %s" (Printexc.to_string e))
    | _ -> ()
  in
  match
    let media_block_id = uuid4 () in
    let mb = { surl; files = []; media_urls = []; thumbnail_urls = []; short_urls = []; blossom_urls = []; upload_urls = []; extra; reason; pubkey = pubkey_hex } in
    ignore (qm ctx "insert into media_block values ($1::uuid, now(), $2::jsonb)" [ Some media_block_id; Some (Pgj.to_string (mb_json mb)) ]);
    let update_mb () = ignore (qm ctx "update media_block set d = $2::jsonb where id = $1::uuid" [ Some media_block_id; Some (Pgj.to_string (mb_json mb)) ]) in
    let purged = Hashtbl.create 16 in
    (* once per storage path: the work depends only on the URL's path, and one blob comes as several
       URLs with the same path (its upload path, its media_storage rows on each provider) *)
    let purge (url : string) =
      let _, path_ext = url_parts url in
      if not (file_path_ok path_ext) then log "purge %s: not a file path, skipped" url
      else if not (Hashtbl.mem purged path_ext) then begin
        Hashtbl.replace purged path_ext ();
        let path, _ = splitext path_ext in
        let kh = match String.rindex_opt path '/' with Some i -> String.sub path (i + 1) (String.length path - i - 1) | None -> path in
        (* Every distinct place the URL's file can be: each local file (the three forms; path
           entries with the same parent dir reach the same file) and each S3 provider, for <h><ext>
           only (the only form media_store puts on S3; the key is the URL path, whichever entry
           names the provider). Looked up concurrently: one at a time, the 33 S3 round trips per URL
           of the old entry x form loop took a 14-URL purge past 150 s. *)
        let targets = Hashtbl.create 16 in
        let order = ref [] in
        let add k t = if not (Hashtbl.mem targets k) then (Hashtbl.replace targets k (); order := t :: !order) in
        List.iter
          (fun (mp : Media_config.path_entry) ->
            match mp with
            | Media_config.Local { host; path = root } ->
                List.iter (fun p -> let filepath = parent_dir root ^ p in add ("local:" ^ filepath) (`Local (host, root, p, filepath))) (List.filter file_path_ok [ path; path ^ ".key"; path_ext ])
            | Media_config.S3 { provider = name; _ } -> add ("s3:" ^ name) (`S3 (name, path_ext)))
          (all_path_entries cfg);
        let purge_target = function
          | `Local (host, root, p, filepath) -> (
              try
                let kind = try Some (Unix.lstat filepath).Unix.st_kind with _ -> None in
                if kind = Some Unix.S_DIR then log "local purge %s: a directory, left in place" filepath
                else if kind <> None then begin
                  let parts = String.split_on_char '/' filepath in
                  let n = List.length parts in
                  let dst_root = String.concat "/" (List.filteri (fun i _ -> i < n - 6) parts) in
                  let dst_dir = dst_root ^ "/cdn-hidden" in
                  (try Unix.mkdir dst_dir 0o755 with _ -> ());
                  let dst = dst_dir ^ "/" ^ Filename.basename filepath in
                  mb.files <- `Assoc [ ("mp", `List [ `String "local"; `String host; `String root ]); ("p", `String p); ("filepath", `String filepath); ("dst", `String dst) ] :: mb.files;
                  Sys.rename filepath dst
                end
              with e -> log "local purge %s: %s" filepath (Printexc.to_string e))
          | `S3 (name, p) -> (
              match Media_config.find_s3 cfg name with
              | Some prov -> (
                  let key = if String.length p > 0 && p.[0] = '/' then String.sub p 1 (String.length p - 1) else p in
                  try
                    if S3.check ~net:ctx.net ~clock:ctx.clock prov key then begin
                      mb.files <- `Assoc [ ("mp", `List [ `String "s3"; `String name ]); ("p", `String p) ] :: mb.files;
                      (match (s3_backup, prov.S3.bucket2) with true, Some b2 -> ignore (S3.copy ~net:ctx.net ~clock:ctx.clock prov ~source_bucket:prov.bucket ~source_key:key ~destination_bucket:b2 ~destination_key:key) | _ -> ());
                      ignore (S3.delete ~net:ctx.net ~clock:ctx.clock prov key)
                    end;
                    match (cfg.cloudflare_cache, prov.S3.domain) with
                    | Some _, Some domain when name = "cloudflare" || name = "cloudflare2" -> cf_add ("https://" ^ domain ^ p)
                    | _ -> ()
                  with e -> log "s3 purge %s %s: %s" name p (Printexc.to_string e))
              | None -> log "purge: unknown s3 provider %s" name)
        in
        Eio.Fiber.List.iter ~max_fibers:purge_parallelism purge_target (List.rev !order);
        (* the media_storage rows of every storage the entries name *)
        let labels = List.sort_uniq compare (List.map (function Media_config.Local { host; _ } -> host | Media_config.S3 { provider; _ } -> provider) (all_path_entries cfg)) in
        Eio.Fiber.List.iter ~max_fibers:purge_parallelism
          (fun label -> ignore (q ctx "update media_storage set media_block_id = $3::uuid where storage_provider = $1 and h = $2" [ Some label; Some kh; Some media_block_id ]))
          labels;
        update_mb ()
      end
    in
    let host, upath = url_parts surl in
    let spath, ext = splitext (if String.length upath > 0 && upath.[0] = '/' then String.sub upath 1 (String.length upath - 1) else upath) in
    let col1 rows = List.filter_map (function Some s :: _ -> Some s | _ -> None) rows in
    if List.mem host cfg.blossom_hosts then begin
      mb.blossom_urls <- surl :: mb.blossom_urls;
      let sha_hex = match Hex_util.decode_opt spath with Some s when String.length s = 32 -> spath | _ -> fail "blossom url without a sha256 path: %s" surl in
      let clear_cache = ref clear_cache in
      (* late: the uploads are already blocked (their media_block stays); purged is what the upload's
         import has written since: its storage copies, variants and thumbnails *)
      if late then begin
        List.iter (fun path -> let u = cfg.upload_url_root ^ path in mb.upload_urls <- u :: mb.upload_urls; purge u) (col1 (qm ctx "select path from media_uploads where sha256 = decode($1,'hex') group by path" [ Some sha_hex ]));
        List.iter (fun u -> mb.media_urls <- u :: mb.media_urls; purge u) (col1 (q ctx "select media_url from media_storage where sha256 = decode($1,'hex')" [ Some sha_hex ]));
        ignore (q ctx "update media_storage set media_block_id = $1::uuid where sha256 = decode($2,'hex')" [ Some media_block_id; Some sha_hex ])
      end
      else
      (match pubkey_hex with
      | Some pk ->
          ignore (qm ctx "update media_uploads set media_block_id = $3::uuid where sha256 = decode($1,'hex') and pubkey = decode($2,'hex')" [ Some sha_hex; Some pk; Some media_block_id ]);
          let cnt sql params = match qm ctx sql params with [ Some c ] :: _ -> int_of_string c | _ -> 0 in
          let ulcnt = cnt "select count(1) from media_uploads where sha256 = decode($1,'hex') and pubkey = decode($2,'hex')" [ Some sha_hex; Some pk ] in
          let ulallcnt = cnt "select count(1) from media_uploads where sha256 = decode($1,'hex')" [ Some sha_hex ] in
          if ulcnt <> 0 && ulcnt = ulallcnt then begin
            List.iter (fun path -> let u = cfg.upload_url_root ^ path in mb.upload_urls <- u :: mb.upload_urls; purge u) (col1 (qm ctx "select path from media_uploads where sha256 = decode($1,'hex') and pubkey = decode($2,'hex') group by path" [ Some sha_hex; Some pk ]));
            List.iter (fun u -> mb.media_urls <- u :: mb.media_urls; purge u) (col1 (q ctx "select media_url from media_storage where sha256 = decode($1,'hex')" [ Some sha_hex ]));
            ignore (q ctx "update media_storage set media_block_id = $1::uuid where sha256 = decode($2,'hex')" [ Some media_block_id; Some sha_hex ]);
            clear_cache := true
          end
      | None ->
          List.iter (fun path -> let u = cfg.upload_url_root ^ path in mb.upload_urls <- u :: mb.upload_urls; purge u) (col1 (qm ctx "select path from media_uploads where sha256 = decode($1,'hex')" [ Some sha_hex ]));
          ignore (qm ctx "update media_uploads set media_block_id = $2::uuid where sha256 = decode($1,'hex')" [ Some sha_hex; Some media_block_id ]));
      if !clear_cache then begin
        List.iter (fun u -> mb.media_urls <- u :: mb.media_urls; purge u) (col1 (q ctx "select media_url from media_1_16fa35f2dc where orig_sha256 = decode($1,'hex') and media_url like '%/cache/%'" [ Some sha_hex ]));
        ignore (q ctx "update media_storage set media_block_id = $1::uuid where sha256 = decode($2,'hex') and media_url like '%/cache/%'" [ Some media_block_id; Some sha_hex ]);
        (* video thumbnails of the upload and of its variants *)
        List.iter
          (fun u -> mb.thumbnail_urls <- u :: mb.thumbnail_urls; purge u)
          (col1
             (q ctx
                "select distinct thumbnail_url from video_thumbnails where video_url = $1 \
                 or video_url in (select url from media_1_16fa35f2dc where orig_sha256 = decode($2,'hex')) \
                 or video_url in (select media_url from media_1_16fa35f2dc where orig_sha256 = decode($2,'hex'))"
                [ Some surl; Some sha_hex ]))
      end;
      if block_all_uploads then begin
        ignore (qm ctx "update media_uploads set media_block_id = $2::uuid where sha256 = decode($1,'hex')" [ Some sha_hex; Some media_block_id ]);
        List.iter (fun u -> mb.media_urls <- u :: mb.media_urls; purge u) (col1 (q ctx "select media_url from media_storage where sha256 = decode($1,'hex')" [ Some sha_hex ]));
        ignore (q ctx "update media_storage set media_block_id = $2::uuid where sha256 = decode($1,'hex')" [ Some sha_hex; Some media_block_id ])
      end
    end
    else if host = "m.primal.net" then
      List.iter
        (fun url ->
          mb.short_urls <- url :: mb.short_urls;
          purge url;
          ignore (qm ctx "update short_urls set media_block_id = $3::uuid where path = $1 and ext = $2" [ Some spath; Some ext; Some media_block_id ]);
          match pubkey_hex with Some pk -> ignore (qm ctx "update media_uploads set media_block_id = $3::uuid where pubkey = decode($1,'hex') and path = $2" [ Some pk; Some (snd (url_parts url)); Some media_block_id ]) | None -> ())
        (col1 (qm ctx "select url from short_urls where path = $1 and ext = $2" [ Some spath; Some ext ]))
    else begin
      purge surl;
      List.iter (fun u -> mb.media_urls <- u :: mb.media_urls; purge u) (col1 (q ctx "select media_url from media where url = $1" [ Some surl ]));
      List.iter (fun u -> mb.thumbnail_urls <- u :: mb.thumbnail_urls; purge u) (col1 (q ctx "select thumbnail_url from video_thumbnails where video_url = $1" [ Some surl ]))
    end;
    update_mb ()
  with
  | () -> flush_cf ()
  | exception e -> flush_cf (); raise e

(* Every upload of [sha_hex] is blocked (deleted by its uploader, or blocked by moderation). *)
let sha256_blocked (ctx : ctx) (sha_hex : string) : bool =
  match qm ctx "select bool_and(media_block_id is not null) from media_uploads where sha256 = decode($1,'hex')" [ Some sha_hex ] with
  | [ Some "t" ] :: _ -> true
  | _ -> false

(* What the import of an upload wrote after the upload was deleted or blocked: its copies on the
   upload providers, its variants, its video thumbnails. The import runs for seconds to minutes
   after the upload, and a purge only finds what exists when it looks. *)
let purge_late_writes (ctx : ctx) ~(sha_hex : string) ~(ext : string) : unit =
  match ctx.cfg.blossom_hosts with
  | host :: _ ->
      purge_media ctx ~pubkey_hex:None ~surl:(Printf.sprintf "https://%s/%s%s" host sha_hex ext) ~reason:(Some "written by the import after the block")
        ~extra:[] ~block_all_uploads:false ~clear_cache:true ~late:true ()
  | [] -> log "purge_late_writes %s: no blossom host configured" sha_hex

(* {1 nodes} *)
let pubkey_arg (v : Pgj.t) : string option = match Pgj.as_hex_id v with Some h -> Some h | None -> ( match v with `String s when String.length s = 64 -> Some s | _ -> ( match Pgj.read_vec_u8 ~dir:"/nonexistent" v with Some b when String.length b = 32 -> Some (Hex_util.encode b) | _ -> None))

let purge_media_pn (ctx : ctx) (n : node) : Pgj.t =
  let pubkey_hex, surl = match Pgj.as_tuple n.args with pk :: surl :: _ -> (pubkey_arg pk, Option.get (Pgj.as_string surl)) | _ -> fail "invalid args" in
  let kw k = Pgj.kw n.kwargs k in
  let reason = match kw "reason" with Some (`String r) -> Some r | _ -> None in
  let extra = match kw "extra" with Some e -> Pgj.namedtuple_fields e | None -> [] in
  let flag k = match kw k with Some (`Bool b) -> b | _ -> false in
  purge_media ctx ~pubkey_hex ~surl ~reason ~extra ~block_all_uploads:(flag "block_all_uploads") ~clear_cache:(flag "clear_cache") ();
  `Null

(* MediaAnalysis.inc_counter(key, prop; key_class, delta) over bytea_props *)
let inc_counter (ctx : ctx) ~(key_hex : string) ~(key_class : string) ~(prop : string) ~(delta : int) : int =
  match q ctx "insert into bytea_props values ($1, decode($2,'hex'), $3, $4::jsonb) on conflict (key_class, key, prop) do update set value = ((bytea_props.value)::int8 + (excluded.value)::int8)::varchar::jsonb returning value::text" [ Some key_class; Some key_hex; Some prop; Some (string_of_int delta) ] with
  | [ Some v ] :: _ -> ( try int_of_string (String.trim v) with _ -> 0)
  | _ -> 0

let inc_counter_pn (ctx : ctx) (n : node) : Pgj.t =
  let key, prop = match Pgj.as_tuple n.args with k :: p :: _ -> (k, Option.get (Pgj.as_string p)) | _ -> fail "invalid args" in
  let delta = match Pgj.kw n.kwargs "delta" with Some v -> Option.value (Pgj.as_int v) ~default:1 | None -> 1 in
  let key_class = match Pgj.kw n.kwargs "key_class" with Some (`String s) -> Some s | _ -> None in
  match (Pgj.ty key, key) with
  | Some "PubKeyId", _ -> `Int (inc_counter ctx ~key_hex:(Option.get (Pgj.as_hex_id key)) ~key_class:(Option.value key_class ~default:"pubkey") ~prop ~delta)
  | Some "Vector{UInt8}", _ -> `Int (inc_counter ctx ~key_hex:(Hex_util.encode (Option.get (Pgj.read_vec_u8 ~dir:ctx.cfg.binary_data_cache_dir key))) ~key_class:(Option.value key_class ~default:"") ~prop ~delta)
  | _ -> fail "unsupported key type"

(* MediaAnalysis.block_media(pubkey, surl; reason, extra) *)
let block_media_pn (ctx : ctx) (n : node) : Pgj.t =
  let pk_arg, surl = match Pgj.as_tuple n.args with pk :: surl :: _ -> (pk, Option.get (Pgj.as_string surl)) | _ -> fail "invalid args" in
  let reason = Option.value (Pgj.kw n.kwargs "reason") ~default:`Null and extra = Option.value (Pgj.kw n.kwargs "extra") ~default:(Pgj.namedtuple []) in
  ignore (pnd ctx ~mod_:"PrimalServer.InternalServices" ~func:"purge_media_" ~args:(Pgj.tuple [ pk_arg; `String surl ]) ~kwargs:(`Assoc [ ("reason", reason); ("extra", extra) ]));
  (match pubkey_arg pk_arg with
  | Some pk ->
      let _, r = pn ctx ~mod_:"Main.MediaAnalysis" ~func:"inc_counter" ~args:(Pgj.tuple [ Pgj.pubkey_id_hex pk; `String "csam_block_count" ]) ~kwargs:(`Assoc [ ("key_class", `Null); ("delta", `Int 1) ]) in
      let count = match r with Ok (`Int c) -> c | _ -> 0 in
      if count >= 3 && qm ctx "select 1 from filterlist where target_type = 'pubkey' and target = decode($1,'hex') and grp = 'csam' and blocked limit 1" [ Some pk ] = [] then
        ignore (pnd ctx ~mod_:"Main.MediaAnalysis" ~func:"purge_user_content" ~args:(Pgj.tuple [ Pgj.pubkey_id_hex pk ]) ~kwargs:(`Assoc [ ("reason", reason); ("extra", extra) ]))
  | None -> ());
  `Null

(* MediaAnalysis.purge_user_content: a POST to the private purger (configured URL) *)
let purge_user_content_pn (ctx : ctx) (n : node) : Pgj.t =
  let api = match ctx.cfg.user_content_purger_api with Some a -> a | None -> fail "user_content_purger_api not configured" in
  let pk = match Pgj.as_tuple n.args with pk :: _ -> Option.get (pubkey_arg pk) | _ -> fail "invalid args" in
  let reason = match Pgj.kw n.kwargs "reason" with Some (`String r) -> r | _ -> "" in
  let message = Printf.sprintf "reason: %s\npubkey: %s\n" reason (Bech32.encode_npub (Hex_util.decode_exn pk)) in
  match Http.request ~net:ctx.net ~clock:ctx.clock ~timeout:60.0 ~meth:"POST" ~body:(Yojson.Safe.to_string (`Assoc [ ("func", `String "purge_user_content"); ("message", `String message) ])) api with
  | Some r when r.status = 200 -> ( try Yojson.Safe.from_string r.body with _ -> `String r.body)
  | Some r -> fail "purger: HTTP %d" r.status
  | None -> fail "purger request failed"

let register () =
  register ~mod_:"PrimalServer.InternalServices" ~func:"purge_media_" purge_media_pn;
  register ~mod_:"Main.MediaAnalysis" ~func:"inc_counter" inc_counter_pn;
  register ~mod_:"Main.MediaAnalysis" ~func:"block_media" block_media_pn;
  register ~mod_:"Main.MediaAnalysis" ~func:"purge_user_content" purge_user_content_pn
