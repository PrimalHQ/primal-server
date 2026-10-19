(* The moderation HTTP port (internal_services.jl media_moderation_handler): /purge-media
   (purge_media_) and /pre-sign-urls. Media files live under the configured media paths — local
   roots moved aside into cdn-hidden/, S3 providers backed up to bucket2 and deleted, the
   Cloudflare cache purged when configured — and every table that points at a purged file gets
   the media_block id. Without media paths and S3 providers (as on an API-only node, where Julia's
   MEDIA_PATHS held bare strings) a purge records the block and marks the rows. *)

open Http_server

type ctx = Handlers.ctx

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [moderation] %s\n%!" (Procinfo.timestamp ()) s) fmt
let api_headers = [ ("content-type", "application/json") ]
let provider (cfg : Config.t) (name : string) : S3.provider option = List.find_opt (fun (p : S3.provider) -> p.S3.name = name) cfg.s3_providers

let uuid4 () : string =
  let st = Random.State.make_self_init () in
  Uuidm.to_string (Uuidm.v4_gen st ())

let splitext (s : string) : string * string =
  let base = match String.rindex_opt s '/' with Some i -> String.sub s (i + 1) (String.length s - i - 1) | None -> s in
  match String.rindex_opt base '.' with
  | Some i -> let cut = String.length s - (String.length base - i) in (String.sub s 0 cut, String.sub s cut (String.length s - cut))
  | None -> (s, "")

let url_path (u : string) : string = match Http.parse_url u with Some p -> p.Http.path | None -> ""

(* A path a purge may act on: a file name below the media root. Never empty, "/", ending in "/"
   or with a ".." segment: root ^ "" is the media root itself, which an empty URL (a profile's
   "picture": "") once tried to move into cdn-hidden/, and "/uploads2/0" names a whole shard. *)
let file_path_ok (p : string) : bool =
  let n = String.length p in
  n > 1 && p.[0] = '/' && p.[n - 1] <> '/' && not (List.mem ".." (String.split_on_char '/' p))

let url_host (u : string) : string = match Http.parse_url u with Some p -> p.Http.host | None -> ""

type mb = {
  surl : string;
  mutable files : Yojson.Safe.t list;
  mutable media_urls : string list;
  mutable thumbnail_urls : string list;
  mutable short_urls : string list;
  mutable blossom_urls : string list;
  mutable upload_urls : string list;
  extra : (string * Yojson.Safe.t) list;
  reason : string option;
  pubkey : string option; (* hex *)
}

let mb_json (m : mb) : string =
  let strs l = `List (List.map (fun s -> `String s) (List.rev l)) in
  Yojson.Safe.to_string
    (`Assoc
      ([ ("surl", `String m.surl); ("files", `List (List.rev m.files)); ("media_urls", strs m.media_urls); ("thumbnail_urls", strs m.thumbnail_urls); ("short_urls", strs m.short_urls);
         ("blossom_urls", strs m.blossom_urls); ("upload_urls", strs m.upload_urls) ]
      @ m.extra
      @ (match m.reason with Some r -> [ ("reason", `String r) ] | None -> [])
      @ match m.pubkey with Some p -> [ ("pubkey", `String p) ] | None -> []))

let cloudflare_purge (ctx : ctx) ~(zone_id : string) ~(api_key : string) (file_url : string) : unit =
  match !Handlers.net_ref with
  | None -> ()
  | Some net -> (
      let body = Yojson.Safe.to_string (`Assoc [ ("files", `List [ `String file_url ]) ]) in
      match
        Http.request ~net ~clock:ctx.clock ~timeout:20.0 ~meth:"POST" ~headers:[ ("Authorization", "Bearer " ^ api_key); ("Content-Type", "application/json") ] ~body
          ("https://api.cloudflare.com/client/v4/zones/" ^ zone_id ^ "/purge_cache")
      with
      | Some r when r.Http.status = 200 -> log "cloudflare purge %s ok" file_url
      | Some r -> log "cloudflare purge %s: HTTP %d" file_url r.Http.status
      | None -> log "cloudflare purge %s failed" file_url)

(* purge_media_. The walk over the media paths runs 10 entries at a time (Julia: asyncmap ntasks=10)
   and no pooled connection is held across the S3 / file work: rows are read first, the files are
   purged, then the blocks are written (the membership pool has two connections). The hidden
   directory is the one Julia uses, cdn-hidden/ NEXT TO the root (root /mnt/ext/var/cdn ->
   /mnt/ext/var/cdn-hidden; Julia derives it from the file's depth). *)
let purge_media (ctx : ctx) ~(pubkey : string option) ~(surl : string) ~(reason : string option) ~(initiator_pubkey : Yojson.Safe.t) ~(block_all_uploads : bool) ~(clear_cache : bool) : unit =
  let cfg = ctx.cfg in
  let media_block_id = uuid4 () in
  let mb = { surl; files = []; media_urls = []; thumbnail_urls = []; short_urls = []; blossom_urls = []; upload_urls = []; extra = [ ("initiator_pubkey", initiator_pubkey) ]; reason; pubkey = Option.map Hex_util.encode pubkey } in
  Handlers.with_membership ctx (fun m -> Queries_mem.media_block_insert m ~id:media_block_id ~d:(mb_json mb));
  let update_mb () = Handlers.with_membership ctx (fun m -> Queries_mem.media_block_update m ~id:media_block_id ~d:(mb_json mb)) in
  let purged = Hashtbl.create 16 in
  let purge_entry ~kh (p, (mp : Config.media_path)) =
    (match mp with
    | Config.Local { root; _ } -> (
        let filepath = root ^ p in
        try
          if Sys.file_exists filepath && Sys.is_directory filepath then log "local purge %s: a directory, left in place" filepath
          else if Sys.file_exists filepath then begin
            let dst_dir = Filename.concat (Filename.dirname root) "cdn-hidden" in
            (try Sys.mkdir dst_dir 0o755 with Sys_error _ -> ());
            let dst = Filename.concat dst_dir (Filename.basename filepath) in
            mb.files <- `Assoc [ ("mp", `List [ `String "local"; `String (Config.media_path_label mp); `String root ]); ("p", `String p); ("filepath", `String filepath); ("dst", `String dst) ] :: mb.files;
            Sys.rename filepath dst
          end
        with e -> log "local purge %s: %s" filepath (Printexc.to_string e))
    | Config.S3_path { provider = name; _ } -> (
        match (provider cfg name, !Handlers.net_ref) with
        | Some prov, Some net -> (
            let key = String.sub p 1 (String.length p - 1) in
            try
              let present =
                match S3.check_opt ~net ~clock:ctx.clock ?proxy:cfg.relay_proxy prov key with
                | Some b -> b
                | None -> log "s3 check %s %s failed: object left in place" name p; false
              in
              if present then begin
                mb.files <- `Assoc [ ("mp", `List [ `String "s3"; `String name ]); ("p", `String p) ] :: mb.files;
                (match prov.S3.bucket2 with
                | Some b2 -> ignore (S3.copy ~net ~clock:ctx.clock ?proxy:cfg.relay_proxy prov ~source_bucket:prov.bucket ~source_key:key ~destination_bucket:b2 ~destination_key:key)
                | None -> ());
                ignore (S3.delete ~net ~clock:ctx.clock ?proxy:cfg.relay_proxy prov key)
              end;
              match (cfg.cloudflare, prov.S3.domain) with
              | Some (zone_id, api_key), Some domain when name = "cloudflare" || name = "cloudflare2" -> cloudflare_purge ctx ~zone_id ~api_key ("https://" ^ domain ^ p)
              | _ -> ()
            with e -> log "s3 purge %s %s: %s" name p (Printexc.to_string e))
        | _ -> ()));
    Handlers.with_cache ctx (fun c -> Queries.media_storage_set_block c ~storage_provider:(Config.media_path_label mp) ~h:kh ~block:media_block_id)
  in
  (* once per storage path: the work below depends only on the URL's path, and one blob comes as
     several URLs with the same path (the upload path, its media_storage rows on each provider),
     which each repeated every check and Cloudflare purge *)
  let purge (url : string) =
    let path_ext = url_path url in
    if not (file_path_ok path_ext) then log "purge %s: not a file path, skipped" url
    else if not (Hashtbl.mem purged path_ext) then begin
      Hashtbl.replace purged path_ext ();
      let path, _ = splitext path_ext in
      let kh = match String.rindex_opt path '/' with Some i -> String.sub path (i + 1) (String.length path - i - 1) | None -> path in
      let variants = List.filter file_path_ok (List.sort_uniq compare [ path; path ^ ".key"; path_ext ]) in
      let entries = List.concat_map (fun p -> List.map (fun mp -> (p, mp)) cfg.media_paths) variants in
      Eio.Fiber.List.iter ~max_fibers:10 (purge_entry ~kh) entries;
      update_mb ()
    end
  in
  let purge_media_urls urls = List.iter (fun u -> mb.media_urls <- u :: mb.media_urls; purge u) urls in
  let purge_upload_paths paths =
    List.iter
      (fun path ->
        let upload_url = "https://_media.primal.net" ^ path in
        mb.upload_urls <- upload_url :: mb.upload_urls;
        purge upload_url)
      paths
  in
  let host = url_host surl in
  let spath, ext = splitext (let p = url_path surl in if String.length p > 0 then String.sub p 1 (String.length p - 1) else p) in
  if host = "blossom.primal.net" || host = "blossom-dev.primal.net" then begin
    mb.blossom_urls <- surl :: mb.blossom_urls;
    let sha256 = match Hex_util.decode_opt spath with Some s when String.length s = 32 -> s | _ -> raise Not_found in
    let clear_cache = ref clear_cache in
    (match pubkey with
    | Some pk -> (
        (* the uploader's rows are blocked; the files go only when nobody else uploaded the same blob *)
        let paths =
          Handlers.with_membership ctx (fun m ->
              Queries_mem.media_uploads_set_block m ~sha256 ~pubkey:pk ~block:media_block_id;
              let ulcnt = Queries_mem.media_uploads_count m ~sha256 ~pubkey:(Some pk) and ulallcnt = Queries_mem.media_uploads_count m ~sha256 ~pubkey:None in
              if ulcnt <> 0L && ulcnt = ulallcnt then Some (Queries_mem.media_uploads_paths m ~sha256 ~pubkey:(Some pk)) else None)
        in
        match paths with
        | Some paths ->
            purge_upload_paths paths;
            purge_media_urls (Handlers.with_cache ctx (fun c -> Queries.media_storage_urls_by_sha256 c ~sha256));
            Handlers.with_cache ctx (fun c -> Queries.media_storage_set_block_by_sha256 c ~sha256 ~block:media_block_id ~cache_only:false);
            clear_cache := true
        | None -> ())
    | None ->
        purge_upload_paths (Handlers.with_membership ctx (fun m -> Queries_mem.media_uploads_paths m ~sha256 ~pubkey:None));
        Handlers.with_membership ctx (fun m -> Queries_mem.media_uploads_set_block_all m ~sha256 ~block:media_block_id));
    if !clear_cache then begin
      purge_media_urls (Handlers.with_cache ctx (fun c -> Queries.media_cache_urls_by_orig_sha256 c ~sha256));
      Handlers.with_cache ctx (fun c -> Queries.media_storage_set_block_by_sha256 c ~sha256 ~block:media_block_id ~cache_only:true)
    end;
    if block_all_uploads then begin
      Handlers.with_membership ctx (fun m -> Queries_mem.media_uploads_set_block_all m ~sha256 ~block:media_block_id);
      purge_media_urls (Handlers.with_cache ctx (fun c -> Queries.media_storage_urls_by_sha256 c ~sha256));
      Handlers.with_cache ctx (fun c -> Queries.media_storage_set_block_by_sha256 c ~sha256 ~block:media_block_id ~cache_only:false)
    end
  end
  else if host = "m.primal.net" then
    List.iter
      (fun url ->
        mb.short_urls <- url :: mb.short_urls;
        purge url;
        Handlers.with_membership ctx (fun m ->
            Queries_mem.short_urls_set_block m ~path:spath ~ext ~block:media_block_id;
            match pubkey with Some pk -> Queries_mem.media_uploads_set_block_by_path m ~pubkey:pk ~path:(url_path url) ~block:media_block_id | None -> ()))
      (Handlers.with_membership ctx (fun m -> Queries_mem.short_urls_by_path_ext m ~path:spath ~ext))
  else begin
    purge surl;
    let media_urls, thumbnails = Handlers.with_cache ctx (fun c -> (Queries.media_urls_for_url c ~url:surl, Queries.video_thumbnails_for_video c ~video_url:surl)) in
    purge_media_urls media_urls;
    List.iter (fun u -> mb.thumbnail_urls <- u :: mb.thumbnail_urls; purge u) thumbnails
  end;
  update_mb ()

let service ~(cfg : Config.t) ~clock : Http_server.service =
  let ctx = Internal_http.ctx_of cfg clock in
  let handler (r : req) : resp =
    Internal_http.guard (fun () ->
        let j = Yojson.Safe.from_string r.body in
        let field k = match j with `Assoc f -> ( match List.assoc_opt k f with Some v -> v | None -> `Null) | _ -> `Null in
        match r.path with
        | "/purge-media" ->
            let pubkey = match field "pubkey" with `String h -> ( match Hex_util.decode_opt h with Some p when String.length p = 32 -> Some p | _ -> raise Not_found) | `Null -> None | _ -> raise Not_found in
            let surl = match field "url" with `String u -> u | _ -> raise Not_found in
            let reason = match field "reason" with `String s -> Some s | _ -> None in
            let flag k = match field k with `Bool b -> b | _ -> false in
            purge_media ctx ~pubkey ~surl ~reason ~initiator_pubkey:(field "initiator_pubkey") ~block_all_uploads:(flag "block_all_uploads") ~clear_cache:(flag "clear_cache");
            Raw (200, api_headers, "ok")
        | "/pre-sign-urls" ->
            let bucket = match field "bucket" with `String b -> b | _ -> raise Not_found in
            let paths = match field "paths" with `List l -> List.filter_map (function `String s -> Some s | _ -> None) l | _ -> raise Not_found in
            let prov = match field "storage_provider" with `String n -> ( match provider cfg n with Some p -> p | None -> raise Not_found) | _ -> raise Not_found in
            let now = Unix.gettimeofday () in
            let res = List.map (fun path -> (path, `String (S3.presign_get ~now prov ~bucket ~key:(if String.length path > 0 && path.[0] = '/' then String.sub path 1 (String.length path - 1) else path)))) paths in
            Raw (200, api_headers, Yojson.Safe.to_string (`Assoc res))
        | _ -> Raw (404, api_headers, "not found"))
  in
  let routes = Extensions.routes `Moderation @ [ { meth = `POST; pattern = []; handler }; { meth = `POST; pattern = [ Rest "path" ]; handler }; { meth = `GET; pattern = [ Rest "path" ]; handler } ] in
  { (default_service "moderation" routes) with cors = true; max_body = 4 * 1024 * 1024 }
