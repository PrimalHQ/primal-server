(* app_media.jl import_upload_3 (PrimalServer.App): the node the blossom server schedules for every
   upload — mimetype and dimensions, media_import_2 to the upload providers, the memberships row and
   used_storage, video frames (import_video), the after-upload analysis hook, the CSAM similarity
   checks (sha256, then embedding) that purge, and the CDN variants (import_media_pn). *)

open Procgraph
module T = Media_tools
module S = Media_store

let starts p s = String.length s >= String.length p && String.sub s 0 (String.length p) = p

(* cache_storage_media.jl import_video_frames / import_video *)
let import_video_frames (ctx : ctx) (frames : (float * string) list) ~(video_sha256 : string) ~(added_at : int) : unit =
  List.iteri
    (fun i (pos, frame) ->
      let idx = i + 1 in
      ignore (S.media_import ctx [ ("type", `String "video_frame"); ("video_sha256", `String (Hex_util.encode video_sha256)); ("frame_idx", `Int idx); ("frame_pos", `Float pos) ] (fun () -> frame));
      ignore (q ctx "insert into video_frames values (decode($1,'hex'), $2::int8, $3::float4, decode($4,'hex'), $5::int8) on conflict do nothing" [ Some (Hex_util.encode video_sha256); Some (string_of_int idx); Some (Pgj.julia_float pos); Some (Pgj.sha256_hex frame); Some (string_of_int added_at) ]))
    frames

let import_video (ctx : ctx) ~(video_url : string) ~(data : string) ~(video_sha256 : string) : unit =
  let added_at = Utils.current_time () in
  ignore (q ctx "insert into video_urls values ($1, decode($2,'hex'), $3::int8) on conflict do nothing" [ Some video_url; Some (Hex_util.encode video_sha256); Some (string_of_int added_at) ]);
  if q ctx "select 1 from video_frames where video_sha256 = decode($1,'hex') limit 1" [ Some (Hex_util.encode video_sha256) ] = [] then import_video_frames ctx (T.extract_video_frames ctx data) ~video_sha256 ~added_at

let bytea_array (shas : string list) = "{" ^ String.concat "," (List.map (fun s -> "\"\\\\x" ^ Hex_util.encode s ^ "\"") shas) ^ "}"

let csam_purge (ctx : ctx) ~pubkey_hex ~surl ~(reason : string) ~(extra : (string * Pgj.t) list) =
  log "upload %s: %s" surl reason;
  (try Nodes_moderation.purge_media ctx ~pubkey_hex:(Some pubkey_hex) ~surl ~reason:(Some reason) ~extra ~block_all_uploads:true ~clear_cache:false () with exn -> log "purge_media_ %s: %s" surl (Printexc.to_string exn));
  (match !Hooks.bunny_purge with Some f -> (try f ctx with exn -> log "bunny_purge: %s" (Printexc.to_string exn)) | None -> ())

(* App.upload_check_similarity_by_sha256 *)
let check_similarity_by_sha256 (ctx : ctx) ~pubkey_hex ~(shas : string list) ~surl : bool =
  match q ctx "select encode(mumb.sha256,'hex'), mumb.id::text, mumb.reason from media_uploads_media_block_csam mumb where mumb.sha256 = any ($1::bytea[]) limit 1" [ Some (bytea_array shas) ] with
  | [ Some msha; Some mid; reason ] :: _ ->
      csam_purge ctx ~pubkey_hex ~surl ~reason:(Printf.sprintf "%s; blocked by matching sha256" (Option.value reason ~default:"")) ~extra:[ ("matching_sha256", `String msha); ("matching_media_block_id", `String mid) ];
      true
  | _ -> false

(* App.upload_check_similarity_by_embedding *)
let check_similarity_by_embedding (ctx : ctx) ~pubkey_hex ~(mimetype : string) ~(data : string) ~surl : bool =
  let model, emb = if starts "image/" mimetype then ("google/vit-base-patch16-384", T.image_features ctx data) else if starts "video/" mimetype then ("google/vivit-b-16x2-kinetics400", T.video_features ctx data) else ("", None) in
  match emb with
  | None -> false
  | Some emb -> (
      match q ctx "select encode(mumb.sha256,'hex'), mumb.id::text, mumb.reason, me.emb <=> $2::vector from media_embedding me, media_uploads_media_block_csam mumb where me.model = $1 and me.emb <=> $2::vector <= 0.02 and mumb.sha256 = me.sha256 order by me.emb <=> $2::vector limit 1" [ Some model; Some (Yojson.Safe.to_string emb) ] with
      | [ Some msha; Some mid; reason; dist ] :: _ ->
          csam_purge ctx ~pubkey_hex ~surl ~reason:(Printf.sprintf "%s; blocked by matching embedding" (Option.value reason ~default:"")) ~extra:[ ("matching_sha256", `String msha); ("matching_media_block_id", `String mid); ("cosinedist", `Float (Option.value (Option.bind dist float_of_string_opt) ~default:0.0)) ];
          true
      | _ -> false)

let import_upload_3 (ctx : ctx) (n : node) : Pgj.t =
  let pubkey_hex, data, sha256_before, burl =
    match Pgj.as_tuple n.args with
    | _ :: pk :: data :: sha_before :: burl :: _ ->
        ( Option.get (Pgj.as_hex_id pk),
          (match Pgj.read_vec_u8 ~dir:ctx.cfg.binary_data_cache_dir data with Some d -> d | None -> fail "upload payload missing from the binary cache"),
          Option.value (Pgj.read_vec_u8 ~dir:ctx.cfg.binary_data_cache_dir sha_before) ~default:"",
          Option.get (Pgj.as_string burl) )
    | _ -> fail "invalid args"
  in
  let sha256 = Pgj.sha256_raw data in
  let key : S.key = [ ("type", `String "member_upload"); ("pubkey", `String pubkey_hex); ("sha256", `String (Hex_util.encode sha256)) ] in
  let mimetype = T.parse_mimetype ctx data in
  let dims = if starts "image/" mimetype then T.parse_image_dimensions ctx data else if starts "video/" mimetype then T.parse_video_dimensions ctx data else None in
  elog ctx n [ ("burl", `String burl); ("size", `Int (String.length data)); ("mimetype", `String mimetype); ("dims", match dims with Some (w, h, d) -> Pgj.tuple [ `Int w; `Int h; `Float d ] | None -> `Null) ];
  (* replicate to the upload providers (Julia: Threads.@spawn, result unobserved) *)
  (try ignore (S.media_import_2 ctx ~media_path:`Upload ~pubkey:pubkey_hex key ~sha256 (fun () -> data))
   with exn -> elog ctx n [ ("step", `String "media_import_2"); ("error", `String (Printexc.to_string exn)) ]; log "import_upload_3 %s: media_import_2: %s" burl (Printexc.to_string exn));
  (* memberships row and used_storage *)
  (try
     if qm ctx "select 1 from memberships where pubkey = decode($1,'hex') limit 1" [ Some pubkey_hex ] = [] then begin
       let tier = if qm ctx "select 1 from verified_users where pubkey = decode($1,'hex') limit 1" [ Some pubkey_hex ] = [] then "free" else "premium" in
       ignore (qm ctx "insert into memberships (pubkey, tier, valid_until, name, used_storage) values (decode($1,'hex'), $2, null, null, 0) on conflict do nothing" [ Some pubkey_hex; Some tier ])
     end;
     ignore (qm ctx "update memberships set used_storage = coalesce(used_storage, 0) + $2::int8 where pubkey = decode($1,'hex')" [ Some pubkey_hex; Some (string_of_int (String.length data)) ])
   with exn -> log "import_upload_3 %s: memberships: %s" burl (Printexc.to_string exn));
  (* video frames and the private analysis hook *)
  (try
     if starts "video/" mimetype then import_video ctx ~video_url:burl ~data ~video_sha256:sha256;
     if starts "image/" mimetype || starts "video/" mimetype then (match !Hooks.after_import_upload with Some f -> f ctx ~surl:burl ~data ~pubkey_hex:(Some pubkey_hex) ~eid_hex:None ~origin:"upload" | None -> ())
   with exn -> log "import_upload_3 %s: video/analysis: %s" burl (Printexc.to_string exn));
  (* similarity checks *)
  let blocked =
    try
      let shas = ref [ sha256 ] in
      if sha256_before <> "" then shas := sha256_before :: !shas;
      List.iter
        (fun row -> match row with
          | [ Some after ] -> (match Hex_util.decode_opt after with Some a -> shas := a :: !shas | None -> ());
            List.iter (fun r -> match r with [ Some b ] -> (match Hex_util.decode_opt b with Some bb -> shas := bb :: !shas | None -> ()) | _ -> ()) (q ctx "select encode(sha256_before,'hex') from media_metadata_stripping where sha256_after = decode($1,'hex') limit 1" [ Some after ])
          | _ -> ())
        (if sha256_before <> "" then q ctx "select encode(sha256_after,'hex') from media_metadata_stripping where sha256_before = decode($1,'hex') limit 1" [ Some (Hex_util.encode sha256_before) ] else []);
      let shas = List.sort_uniq compare !shas in
      let b1 = check_similarity_by_sha256 ctx ~pubkey_hex ~shas ~surl:burl in
      (try ignore (check_similarity_by_embedding ctx ~pubkey_hex ~mimetype ~data ~surl:burl) with exn -> log "import_upload_3 %s: embedding check: %s" burl (Printexc.to_string exn));
      b1
    with exn -> log "import_upload_3 %s: similarity: %s" burl (Printexc.to_string exn); true
  in
  (* the CDN variants *)
  if (not blocked) && String.length data < 10 * 1024 * 1024 && List.mem (T.url_ext burl) [ ".jpg"; ".png"; ".gif"; ".mp4"; ".mov"; ".webp" ] then
    (match pn ctx ~mod_:"PrimalServer.DB" ~func:"import_media_pn" ~args:(Pgj.tuple [ Pgj.cache_storage; `Null; `String burl; Pgj.all_variants ]) ~kwargs:(`Assoc []) with _, Ok _ -> () | _, Error m -> log "import_upload_3 %s: import_media_pn: %s" burl m);
  (* deleted or blocked while this import ran: a purge of that time missed what was written since *)
  (let sha_hex = Hex_util.encode sha256 in
   try
     if Nodes_moderation.sha256_blocked ctx sha_hex then begin
       log "import_upload_3 %s: blocked during the import, purging what it wrote" burl;
       elog ctx n [ ("step", `String "blocked:purge_late_writes") ];
       Nodes_moderation.purge_late_writes ctx ~sha_hex ~ext:(T.url_ext burl)
     end
   with exn -> log "import_upload_3 %s: purge_late_writes: %s" burl (Printexc.to_string exn));
  `Null

let register () = register ~mod_:"PrimalServer.App" ~func:"import_upload_3" import_upload_3
