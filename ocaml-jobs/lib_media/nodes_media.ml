(* The media nodes the Rust scheduler ran (cache_storage_media.rs / media.rs), with the Julia
   originals' extra/log entries: import_media_pn, import_media_variant_pn, import_media_fast_pn,
   import_preview_pn, import_media_hls_pn, media_variants_pn, media_variant_fast_pn. *)

open Procgraph
module T = Media_tools
module S = Media_store

let media_table = "media_1_16fa35f2dc"
let preview_table = "preview_1_44299731c7"
let event_preview_table = "event_preview_1_310cef356e"

let now_s () = string_of_int (Utils.current_time ())
let fl f = Pgj.julia_float f

(* cache_storage_media.jl low_trust_user *)
let low_trust_user (ctx : ctx) (pubkey_hex : string) : bool =
  if q ctx "select 1 from verified_users where pubkey = decode($1,'hex') limit 1" [ Some pubkey_hex ] <> [] then false
  else if q ctx "select 1 from pubkey_trustrank where pubkey = decode($1,'hex') and rank > 1e-6 limit 1" [ Some pubkey_hex ] <> [] then false
  else q ctx "select 1 from pn_time_for_pubkeys where pubkey = decode($1,'hex') and duration > 1800 limit 1" [ Some pubkey_hex ] <> []

let event_pubkey (ctx : ctx) (eid_hex : string) : string option =
  match q ctx "select encode(pubkey,'hex') from events where id = decode($1,'hex') limit 1" [ Some eid_hex ] with [ Some pk ] :: _ -> Some pk | _ -> None

let insert_media (ctx : ctx) ~url ~media_url ~size ~animated ~dldur ~width ~height ~mimetype ~duration ~orig_sha256 : unit =
  ignore
    (q ctx
       (Printf.sprintf "insert into %s (url, media_url, size, animated, imported_at, download_duration, width, height, mimetype, category, category_confidence, duration, rowid, orig_sha256) values ($1,$2,$3,$4::int8,$5::int8,$6::float8,$7::int8,$8::int8,$9,'',1.0,$10::float8,nextval('media_rowid_seq'),decode($11,'hex')) on conflict do nothing" media_table)
       [ Some url; Some media_url; Some size; Some (if animated then "1" else "0"); Some (now_s ()); Some (fl dldur); Some (string_of_int width); Some (string_of_int height); Some mimetype; Some (fl duration); Option.map Hex_util.encode orig_sha256 ])

let insert_event_media (ctx : ctx) ~eid_hex ~url : unit =
  ignore (q ctx "insert into event_media (event_id, url, rowid) values (decode($1,'hex'), $2, nextval('event_media_rowid_seq')) on conflict do nothing" [ Some eid_hex; Some url ])

let eid_json = function Some h -> Pgj.event_id_hex h | None -> `Null
let as_args (n : node) = Pgj.as_tuple n.args

(* {1 media_variants_pn (PrimalServer.Media)} *)
let media_variants_pn (ctx : ctx) (n : node) : Pgj.t =
  let url = match as_args n with _ :: u :: _ -> ( match Pgj.as_string u with Some u -> u | None -> fail "missing url") | _ -> fail "invalid args" in
  let specs = match Pgj.kw n.kwargs "variant_specs" with Some v -> ( match Pgj.variant_specs_of v with [] -> None | l -> Some l) | None -> None in
  let specs = Option.value specs ~default:(List.concat_map (fun s -> [ (s, true); (s, false) ]) [ "original"; "small"; "medium"; "large" ]) in
  let cleaned = T.clean_url url in
  let k_orig : S.key = [ ("url", `String cleaned); ("type", `String "original") ] in
  let h_orig = S.key_h k_orig in
  elog ctx n [ ("url", `String url); ("k", `Assoc k_orig); ("mi_h", `String h_orig); ("cleaned_url", `String cleaned) ];
  let orig_media_url, orig_ext, mimetype, orig_data =
    match q ctx "select ms.media_url, ms.ext, ms.content_type from media_storage ms join media_storage_priority msp on ms.storage_provider = msp.storage_provider where h = $1 order by msp.priority limit 1" [ Some h_orig ] with
    | [ Some murl; ext; ct ] :: _ ->
        let t0 = Unix.gettimeofday () in
        let data = T.download ctx murl in
        elog ctx n [ ("url", `String url); ("orig_media_url", `String murl); ("dldur", `Float (Unix.gettimeofday () -. t0)); ("dlsize", `Int (String.length data)) ];
        (murl, Option.value ext ~default:".bin", Option.value ct ~default:"application/octet-stream", data)
    | _ ->
        let t0 = Unix.gettimeofday () in
        let data = T.download ctx cleaned in
        let dldur = Unix.gettimeofday () -. t0 in
        elog ctx n [ ("url", `String url); ("cleaned_url", `String cleaned); ("dldur", `Float dldur); ("dlsize", `Int (String.length data)) ];
        let mt = T.parse_mimetype ctx data in
        let data = if ctx.cfg.strip_image_metadata && String.length mt >= 6 && String.sub mt 0 6 = "image/" then (try T.strip_metadata ctx data with _ -> data) else data in
        let murl = S.media_import ctx k_orig (fun () -> data) in
        elog ctx n [ ("step", `String "original:imported"); ("media_url", `String murl) ];
        (murl, T.mimetype_ext mt, mt, data)
  in
  elog ctx n [ ("url", `String url); ("orig_media_url", `String orig_media_url); ("ext", `String orig_ext) ];
  if orig_ext = ".bin" then `Assoc [ ("variants", `List []) ]
  else begin
    let starts p s = String.length s >= String.length p && String.sub s 0 (String.length p) = p in
    let variants = ref [] in
    List.iter
      (fun (size, animated) ->
        let v = `Assoc [ ("url", `String url); ("size", `String size); ("animated", `Bool animated) ] in
        if size = "original" || mimetype = "image/svg+xml" then begin
          elog ctx n [ ("v", v); ("murl", `String orig_media_url) ];
          variants := (size, animated, orig_media_url) :: !variants
        end
        else if starts "video/" mimetype && animated then ()
        else begin
          let single_frame = (not (starts "image/gif" mimetype)) && ((not animated) || starts "image/" mimetype) in
          let filters = match T.build_scale_filter size with Some f -> [ f ] | None -> [] in
          let k_res : S.key = [ ("url", `String url); ("type", `String "resized"); ("size", `String size); ("animated", `Bool animated) ] in
          match q ctx "select ms.media_url from media_storage ms join media_storage_priority msp on ms.storage_provider = msp.storage_provider where ms.h = $1 order by msp.priority limit 1" [ Some (S.key_h k_res) ] with
          | [ Some murl ] :: _ ->
              elog ctx n [ ("v", v); ("murl", `String murl) ];
              variants := (size, animated, murl) :: !variants
          | _ -> (
              Pushgateway.mkdir_p ctx.cfg.tmp_dir;
              let outfn = Printf.sprintf "%s/%s%s" ctx.cfg.tmp_dir h_orig orig_ext in
              let cmd = Printf.sprintf "`nice ionice -c3 ffmpeg -y -i -%s%s %s`" (if single_frame then " -frames:v 1 -update 1" else "") (if filters <> [] then Printf.sprintf " -vf \"%s\"" (String.concat "," filters) else "") outfn in
              elog ctx n [ ("v", v); ("cmd", `String cmd); ("outfn", `String outfn); ("logfile", `String (outfn ^ ".log")) ];
              match T.ffmpeg_resize_to_file ctx ~input:orig_data ~filters ~single_frame ~outfn with
              | exception Node_error m ->
                  log "ffmpeg resize failed: %s" m;
                  elog ctx n [ ("v", v); ("status", `Bool false); ("error", `String m) ]
              | stderr ->
                  elog ctx n [ ("v", v); ("status", `Bool true); ("ffmpeg_stderr", if stderr = "" then `Null else `String stderr) ];
                  let data = Pgj.read_file outfn in
                  let murl = S.media_import ctx k_res (fun () -> data) in
                  (try Sys.remove outfn with _ -> ());
                  elog ctx n [ ("v", v); ("murl", `String murl) ];
                  variants := (size, animated, murl) :: !variants)
        end)
      specs;
    let variants = List.rev !variants in
    elog ctx n [ ("url", `String url); ("variants", `Assoc (List.map (fun (s, a, m) -> (Printf.sprintf "(:%s, %b)" s a, `String m)) variants)) ];
    `Assoc [ ("variants", `List (List.map (fun (s, a, m) -> `Assoc [ ("size", `String s); ("animated", `Bool a); ("media_url", `String m) ]) variants)) ]
  end


let variants_of (v : Pgj.t) : (string * bool * string) list =
  match v with
  | `Assoc f -> ( match List.assoc_opt "variants" f with Some (`List l) -> List.filter_map (fun x -> match x with `Assoc g -> ( match (List.assoc_opt "size" g, List.assoc_opt "animated" g, List.assoc_opt "media_url" g) with Some (`String s), Some (`Bool a), Some (`String m) -> Some (s, a, m) | _ -> None) | _ -> None) l | _ -> [])
  | _ -> []

(* {1 import_media_variant_pn (PrimalServer.DB)} *)
let import_media_variant (ctx : ctx) (n : node) ~eid_hex ~url ~size ~anim ~media_url ~(orig_sha256 : string option) : Pgj.t =
  let v = `Assoc [ ("eid", eid_json eid_hex); ("url", `String url); ("size", Pgj.symbol size); ("anim", `Bool anim); ("media_url", `String media_url) ] in
  e_root ctx n ([ ("url", `String url); ("size", Pgj.symbol size); ("anim", `Bool anim); ("media_url", `String media_url) ] @ (match eid_hex with Some h -> [ ("eid", Pgj.event_id_hex h) ] | None -> []));
  let t0 = Unix.gettimeofday () in
  let data = T.download ctx media_url in
  let dldur = Unix.gettimeofday () -. t0 in
  let mimetype = T.parse_mimetype ctx data in
  let ftype = match String.index_opt mimetype '/' with Some i -> String.sub mimetype 0 i | None -> "" in
  let dims = if ftype = "image" then T.parse_image_dimensions ctx data else if ftype = "video" then T.parse_video_dimensions ctx data else None in
  elog ctx n [ ("v", Pgj.namedtuple (Pgj.namedtuple_fields v)); ("dldur", `Float dldur); ("dlsize", `Int (String.length data)); ("mimetype", `String mimetype); ("ftype", `String ftype); ("dims", match dims with Some (w, h, d) -> Pgj.tuple [ `Int w; `Int h; `Float d ] | None -> `Null) ];
  match dims with
  | None -> `Assoc [ ("columns", `List []); ("rows", `List []) ]
  | Some (w, h, duration) ->
      let width, height =
        if ftype = "image" then begin
          let rotated = T.is_image_rotated ctx data in
          elog ctx n [ ("v", v); ("rotated", `Bool rotated) ];
          if rotated then (h, w) else (w, h)
        end
        else begin
          (if ftype = "video" then
             match T.extract_video_thumbnail ctx data with
             | Some th -> (
                 match S.media_import ctx [ ("url", `String url); ("type", `String "video_thumbnail") ] (fun () -> th) with
                 | thumb ->
                     elog ctx n [ ("v", v); ("thumbnail_media_url", `String thumb) ];
                     elog ctx n [ ("op", `String "insert"); ("table", `String "video_thumbnails"); ("url", `String url); ("thumbnail_media_url", `String thumb) ];
                     ignore (q ctx "insert into video_thumbnails values ($1, $2, nextval('video_thumbnails_rowid_seq')) on conflict do nothing" [ Some url; Some thumb ]);
                     ignore (pn ctx ~mod_:"PrimalServer.DB" ~func:"import_media_pn" ~args:(Pgj.tuple [ Pgj.cache_storage; eid_json eid_hex; `String thumb; Pgj.all_variants ]) ~kwargs:(`Assoc []))
                 | exception Node_error m -> log "thumbnail import failed: %s" m)
             | None -> ());
          (w, h)
        end
      in
      elog ctx n ([ ("op", `String "insert"); ("table", `String "media"); ("url", `String url); ("media_url", `String media_url); ("size", Pgj.symbol size); ("anim", `Bool anim); ("dldur", `Float dldur); ("width", `Int width); ("height", `Int height); ("mimetype", `String mimetype); ("duration", `Float duration) ] @ (match orig_sha256 with Some s -> [ ("orig_sha256", `String (Hex_util.encode s)) ] | None -> []));
      insert_media ctx ~url ~media_url ~size ~animated:anim ~dldur ~width ~height ~mimetype ~duration ~orig_sha256;
      `Assoc [ ("columns", `List []); ("rows", `List []) ]

let import_media_variant_pn (ctx : ctx) (n : node) : Pgj.t =
  match as_args n with
  | _ :: eid :: url :: size :: anim :: media_url :: orig_sha :: _ ->
      import_media_variant ctx n ~eid_hex:(Pgj.as_hex_id eid) ~url:(Option.get (Pgj.as_string url)) ~size:(Option.value (Pgj.as_symbol size) ~default:"original") ~anim:(Option.value (Pgj.as_bool anim) ~default:false)
        ~media_url:(Option.value (Pgj.as_string media_url) ~default:"") ~orig_sha256:(Pgj.read_vec_u8 ~dir:ctx.cfg.binary_data_cache_dir orig_sha)
  | _ -> fail "invalid args length"

(* {1 import_media_pn (PrimalServer.DB)} *)
let import_media_pn (ctx : ctx) (n : node) : Pgj.t =
  let a = as_args n in
  let eid_hex, url, specs = match a with _ :: eid :: url :: rest -> (Pgj.as_hex_id eid, Option.get (Pgj.as_string url), (match rest with vs :: _ -> Some vs | [] -> None)) | _ -> fail "invalid args length" in
  let no_media_analysis = match Pgj.kw n.kwargs "no_media_analysis" with Some (`Bool b) -> b | _ -> false in
  e_root ctx n ((match eid_hex with Some h -> [ ("eid", `String h) ] | None -> []) @ [ ("url", `String url) ]);
  let pubkey = match eid_hex with Some h -> event_pubkey ctx h | None -> None in
  match eid_hex with
  | Some h when (match pubkey with Some pk -> low_trust_user ctx pk | None -> true) ->
      elog ctx n [ ("step", `String "low_trust_user:block"); ("eid", `String h) ];
      Pgj.symbol "low_trust_user"
  | _ -> (
      let kwargs =
        let base = Pgj.kwargs_fields n.kwargs in
        match specs with
        | Some vs -> `Assoc (("variant_specs", vs) :: List.remove_assoc "variant_specs" base)
        | None -> if List.mem_assoc "variant_specs" base then `Assoc base else if List.mem (T.url_ext url) [ ".mp4"; ".mov"; ".webm"; ".avi"; ".mkv"; ".m4v"; ".flv"; ".wmv" ] then `Assoc (("variant_specs", `List [ Pgj.tuple [ Pgj.symbol "original"; `Bool true ] ]) :: base) else `Assoc base
      in
      let _, vr = pn ctx ~mod_:"PrimalServer.Media" ~func:"media_variants_pn" ~args:(Pgj.tuple [ `Null; `String url ]) ~kwargs in
      let variants = match vr with Ok v -> variants_of v | Error m -> fail "media_variants_pn: %s" m in
      match variants with
      | [] -> `Null
      | _ ->
          (match eid_hex with
          | Some h ->
              elog ctx n [ ("op", `String "insert"); ("table", `String "event_media"); ("eid", Pgj.event_id_hex h); ("url", `String url) ];
              insert_event_media ctx ~eid_hex:h ~url
          | None -> ());
          let orig_media_url = match List.find_opt (fun (s, a, _) -> s = "original" && a) variants with Some (_, _, m) -> m | None -> url in
          let orig = try Some (T.download ctx orig_media_url) with _ -> ( try Some (T.download ctx url) with _ -> None) in
          let orig_sha256 = Option.map Pgj.sha256_raw orig in
          let orig_cache = Option.map (fun d -> Pgj.cache_write ~dir:ctx.cfg.binary_data_cache_dir d) orig in
          (match orig_sha256 with Some s -> elog ctx n [ ("orig_sha256", `String (Hex_util.encode s)) ] | None -> ());
          List.iter
            (fun (size, anim, media_url) ->
              let args = Pgj.tuple [ Pgj.cache_storage; eid_json eid_hex; `String url; Pgj.symbol size; `Bool anim; `String media_url; (match orig_sha256 with Some s -> Pgj.vec_u8 ~dir:ctx.cfg.binary_data_cache_dir s | None -> `Null); `Null ] in
              match pn ctx ~mod_:"PrimalServer.DB" ~func:"import_media_variant_pn" ~args ~kwargs:(`Assoc []) with _, Ok _ -> () | _, Error m -> log "import_media_variant_pn %s %s: %s" size url m)
            variants;
          (match (orig_cache, orig_sha256) with
          | Some hh, Some _ when not no_media_analysis ->
              let kw = (match pubkey with Some pk -> [ ("pubkey", Pgj.vec_u8_inline (Hex_util.decode_exn pk)) ] | None -> []) @ (match eid_hex with Some h -> [ ("eid", Pgj.event_id_hex h) ] | None -> []) @ [ ("origin", `String "nostr") ] in
              ignore (pnd ctx ~mod_:"MediaAnalysis" ~func:"ext_after_import_upload_2" ~args:(Pgj.tuple [ `String url; Pgj.vec_u8_cached hh ]) ~kwargs:(`Assoc kw))
          | _ -> ());
          `Null)

(* {1 import_media_fast_pn (PrimalServer.DB)} *)
let import_media_fast_pn (ctx : ctx) (n : node) : Pgj.t =
  let eid_hex, url = match as_args n with _ :: eid :: url :: _ -> (Pgj.as_hex_id eid, Option.get (Pgj.as_string url)) | _ -> fail "invalid args length" in
  (match eid_hex with Some h -> ( match event_pubkey ctx h with Some pk when low_trust_user ctx pk -> raise Exit | _ -> ()) | None -> ());
  e_root ctx n ((match eid_hex with Some h -> [ ("eid", `String h) ] | None -> []) @ [ ("url", `String url) ]);
  let cleaned = T.clean_url url in
  let t0 = Unix.gettimeofday () in
  let data = T.download ctx ~timeout:30.0 ~range:(1, 5 * 1024 * 1024) cleaned in
  let dldur = Unix.gettimeofday () -. t0 in
  elog ctx n [ ("url", `String url); ("cleaned_url", `String cleaned); ("dldur", `Float dldur); ("dlsize", `Int (String.length data)) ];
  let mimetype = T.parse_mimetype ctx data in
  let starts p s = String.length s >= String.length p && String.sub s 0 (String.length p) = p in
  let dims = if starts "image/" mimetype then T.parse_image_dimensions ctx data else if starts "video/" mimetype then T.parse_video_dimensions ctx data else None in
  match dims with
  | None -> Pgj.symbol "no_dims"
  | Some (width, height, duration) ->
      elog ctx n [ ("url", `String url); ("ext", `String (T.url_ext cleaned)); ("mimetype", `String mimetype); ("dims", Pgj.tuple [ `Int width; `Int height; `Float duration ]) ];
      if not (starts "image/" mimetype || starts "video/" mimetype) then `Null
      else begin
        (match eid_hex with
        | Some h ->
            elog ctx n [ ("op", `String "insert"); ("table", `String "event_media"); ("eid", Pgj.event_id_hex h); ("url", `String url) ];
            insert_event_media ctx ~eid_hex:h ~url
        | None -> ());
        elog ctx n [ ("op", `String "insert"); ("table", `String "media"); ("url", `String url); ("media_url", `String url); ("size", Pgj.symbol "original"); ("animated", `Int 0); ("dldur", `Float dldur); ("width", `Int width); ("height", `Int height); ("mimetype", `String mimetype); ("duration", `Float duration) ];
        insert_media ctx ~url ~media_url:url ~size:"original" ~animated:false ~dldur ~width ~height ~mimetype ~duration ~orig_sha256:None;
        `Null
      end

let import_media_fast_pn ctx n = try import_media_fast_pn ctx n with Exit -> Pgj.symbol "low_trust_user"

(* {1 import_preview_pn (PrimalServer.DB)} *)
let import_preview_pn (ctx : ctx) (n : node) : Pgj.t =
  let eid_hex, url = match as_args n with _ :: eid :: url :: _ -> (Option.get (Pgj.as_hex_id eid), Option.get (Pgj.as_string url)) | _ -> fail "invalid args length" in
  e_root ctx n [ ("eid", `String eid_hex); ("url", `String url) ];
  match event_pubkey ctx eid_hex with
  | Some pk when low_trust_user ctx pk -> Pgj.symbol "low_trust_user"
  | _ ->
      let t0 = Unix.gettimeofday () in
      let md = T.fetch_resource_metadata ctx url in
      if md.image <> "" then ignore (pn ctx ~mod_:"PrimalServer.DB" ~func:"import_media_pn" ~args:(Pgj.tuple [ Pgj.cache_storage; Pgj.event_id_hex eid_hex; `String md.image; Pgj.all_variants ]) ~kwargs:(`Assoc []));
      let dldur = Unix.gettimeofday () -. t0 in
      elog ctx n [ ("op", `String "insert"); ("table", `String "preview"); ("url", `String url); ("dldur", `Float dldur); ("mimetype", `String md.mimetype); ("title", `String md.title); ("description", `String md.description); ("image", `String md.image); ("icon_url", `String md.icon_url) ];
      ignore (q ctx (Printf.sprintf "insert into %s (url, imported_at, download_duration, mimetype, category, category_confidence, md_title, md_description, md_image, icon_url, rowid) values ($1,$2::int8,$3::float8,$4,'',1.0,$5,$6,$7,$8,nextval('preview_rowid_seq')) on conflict do nothing" preview_table)
                [ Some url; Some (now_s ()); Some (fl dldur); Some md.mimetype; Some md.title; Some md.description; Some md.image; Some md.icon_url ]);
      elog ctx n [ ("op", `String "insert"); ("table", `String "event_preview"); ("eid", Pgj.event_id_hex eid_hex); ("url", `String url) ];
      ignore (q ctx (Printf.sprintf "insert into %s (event_id, url, rowid) values (decode($1,'hex'), $2, nextval('event_preview_rowid_seq')) on conflict do nothing" event_preview_table) [ Some eid_hex; Some url ]);
      Pgj.namedtuple [ ("ok", `Bool true); ("r", `List []); ("id", Pgj.node_id_hex (id_hex n)) ]

(* {1 media_variant_fast_pn (PrimalServer.Media)} *)
let media_variant_fast_pn (ctx : ctx) (n : node) : Pgj.t =
  let url = match as_args n with _ :: u :: _ -> Option.get (Pgj.as_string u) | _ -> fail "invalid args" in
  let cleaned = T.clean_url url in
  let data = T.download ctx ~range:(1, 5 * 1024 * 1024) cleaned in
  let mimetype = T.parse_mimetype ctx data in
  let starts p s = String.length s >= String.length p && String.sub s 0 (String.length p) = p in
  let dims = if starts "image/" mimetype then T.parse_image_dimensions ctx data else if starts "video/" mimetype then T.parse_video_dimensions ctx data else None in
  match dims with
  | None -> Pgj.symbol "no_dims"
  | Some _ -> (
      let size = "large" and animated = false in
      let k_res : S.key = [ ("url", `String url); ("type", `String "resized"); ("size", `String size); ("animated", `Bool animated) ] in
      Pushgateway.mkdir_p ctx.cfg.tmp_dir;
      let outfn = Printf.sprintf "%s/%s%s" ctx.cfg.tmp_dir (S.key_h k_res) (T.mimetype_ext mimetype) in
      match T.ffmpeg_resize_to_file ctx ~input:data ~filters:(Option.to_list (T.build_scale_filter size)) ~single_frame:true ~outfn with
      | exception Node_error m -> log "fast_pn ffmpeg resize failed: %s" m; `Null
      | _ ->
          let out = Pgj.read_file outfn in
          let murl = S.media_import ctx k_res (fun () -> out) in
          (try Sys.remove outfn with _ -> ());
          elog ctx n [ ("step", `String "media_variant_fast:done"); ("media_url", `String murl); ("size", `String size) ];
          Pgj.tuple [ Pgj.symbol size; `Bool animated; `String murl; `String mimetype ])

(* {1 import_media_hls_pn (PrimalServer.DB)} *)
let import_media_hls_pn (ctx : ctx) (n : node) : Pgj.t =
  let eid_hex, url, media_url = match as_args n with _ :: eid :: url :: murl :: _ -> (Pgj.as_hex_id eid, Option.get (Pgj.as_string url), Option.get (Pgj.as_string murl)) | _ -> fail "invalid args length" in
  elog ctx n [ ("step", `String "import_media_hls_pn:start"); ("url", `String url); ("media_url", `String media_url) ];
  let blocked = match eid_hex with Some h -> ( match event_pubkey ctx h with Some pk -> low_trust_user ctx pk | None -> true) | None -> false in
  if blocked then (elog ctx n [ ("step", `String "low_trust_user:block") ]; Pgj.symbol "low_trust_user")
  else begin
    let providers = List.filter (fun (p : Media_config.hls_provider) -> p.enabled) ctx.cfg.hls_providers in
    if providers = [] then (elog ctx n [ ("step", `String "no_enabled_providers") ]; Pgj.symbol "no_providers")
    else begin
      elog ctx n [ ("step", `String "providers_found"); ("count", `Int (List.length providers)) ];
      let results = ref [] and errors = ref [] in
      Eio.Fiber.List.iter ~max_fibers:8
        (fun (p : Media_config.hls_provider) ->
          elog ctx n [ ("step", `String "processing_provider"); ("provider", `String p.htype) ];
          let t0 = Unix.gettimeofday () in
          match Hls.process_video ctx p ~video_url:media_url ~max_wait:ctx.cfg.hls_processing_timeout_s with
          | Ok (hls_url, asset_id) -> (
              elog ctx n [ ("step", `String "provider_success"); ("provider", `String p.htype); ("hls_url", `String hls_url); ("asset_id", `String asset_id); ("duration_secs", `Float (Unix.gettimeofday () -. t0)) ];
              match eid_hex with
              | Some h -> (
                  match
                    q ctx "insert into event_hls_media (event_id, url, media_url, provider, hls_url, created_at, extra) values (decode($1,'hex'), $2, $3, $4, $5, $6::int8, $7::jsonb) on conflict (event_id, url, provider) do update set media_url = excluded.media_url, hls_url = excluded.hls_url, created_at = excluded.created_at, extra = excluded.extra"
                      [ Some h; Some url; Some media_url; Some p.htype; Some hls_url; Some (now_s ()); Some (Pgj.to_string (`Assoc [ ("provider_asset_id", `String asset_id) ])) ]
                  with
                  | _ ->
                      elog ctx n [ ("op", `String "insert"); ("table", `String "event_hls_media"); ("event_id", `String h); ("url", `String url); ("media_url", `String media_url); ("provider", `String p.htype); ("hls_url", `String hls_url); ("asset_id", `String asset_id) ];
                      results := `Assoc [ ("provider", `String p.htype); ("hls_url", `String hls_url); ("asset_id", `String asset_id); ("success", `Bool true) ] :: !results
                  | exception exn ->
                      let m = "Database insert failed: " ^ Printexc.to_string exn in
                      elog ctx n [ ("step", `String "db_insert_error"); ("provider", `String p.htype); ("error", `String m) ];
                      errors := `Assoc [ ("provider", `String p.htype); ("error", `String m) ] :: !errors)
              | None -> results := `Assoc [ ("provider", `String p.htype); ("hls_url", `String hls_url); ("asset_id", `String asset_id); ("success", `Bool true) ] :: !results)
          | Error m ->
              elog ctx n [ ("step", `String "provider_error"); ("provider", `String p.htype); ("error", `String m) ];
              errors := `Assoc [ ("provider", `String p.htype); ("error", `String m) ] :: !errors)
        providers;
      elog ctx n [ ("step", `String "import_media_hls_pn:done"); ("success_count", `Int (List.length !results)); ("error_count", `Int (List.length !errors)) ];
      Pgj.namedtuple [ ("results", `List (List.rev !results)); ("errors", `List (List.rev !errors)); ("success_count", `Int (List.length !results)); ("error_count", `Int (List.length !errors)) ]
    end
  end

let register () =
  register ~mod_:"PrimalServer.Media" ~func:"media_variants_pn" media_variants_pn;
  register ~mod_:"PrimalServer.Media" ~func:"media_variant_fast_pn" media_variant_fast_pn;
  register ~mod_:"PrimalServer.DB" ~func:"import_media_pn" import_media_pn;
  register ~mod_:"PrimalServer.DB" ~func:"import_media_variant_pn" import_media_variant_pn;
  register ~mod_:"PrimalServer.DB" ~func:"import_media_fast_pn" import_media_fast_pn;
  register ~mod_:"PrimalServer.DB" ~func:"import_media_fast_pn_2" import_media_fast_pn;
  register ~mod_:"PrimalServer.DB" ~func:"import_preview_pn" import_preview_pn;
  register ~mod_:"PrimalServer.DB" ~func:"import_media_hls_pn" import_media_hls_pn
