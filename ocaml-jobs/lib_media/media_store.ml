(* media.jl media_import (v1: key-addressed, h = sha256 of the key JSON) and media_import_2 (v2:
   content-addressed by sha256), to local roots and S3 providers per Media.MEDIA_PATHS /
   MEDIA_PATHS_2; media_storage rows. Layout: <root>/<h1>/<h2:3>/<h4:5>/<h><ext>, a <h>.key file
   (v1), a <h> symlink to <h><ext>; url = <media_url_root>/<last dir of root>/<subdir>/<h><ext>. *)

open Procgraph

type key = (string * Pgj.t) list

let key_json (k : key) : string = Pgj.to_string (`Assoc k)
let key_h (k : key) : string = Pgj.sha256_hex (key_json k)
let subdir_of_h (h : string) : string = Printf.sprintf "%s/%s/%s" (String.sub h 0 1) (String.sub h 1 2) (String.sub h 3 2)
let last_segment (p : string) : string = match List.rev (List.filter (fun s -> s <> "") (String.split_on_char '/' p)) with x :: _ -> x | [] -> "cache"
let join_url root segs = String.concat "/" (String.concat "" [ (let n = String.length root in if n > 0 && root.[n - 1] = '/' then String.sub root 0 (n - 1) else root) ] :: segs)

let rand_hex n = Hex_util.encode (String.init n (fun _ -> Char.chr (Random.int 256)))

let write_file (path : string) (data : string) : unit =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc data)

(* Media.use_external_storage: verified users and users above the threshold rank stay local *)
let use_external_storage (ctx : ctx) (pubkey_hex : string) : bool =
  if qm ctx "select 1 from verified_users where pubkey = decode($1,'hex') limit 1" [ Some pubkey_hex ] <> [] then false
  else q ctx "select 1 from pubkey_trustrank where pubkey = decode($1,'hex') and rank >= 0.0 limit 1" [ Some pubkey_hex ] = []

let pubkey_of_key (k : key) : string option =
  if List.assoc_opt "type" k = Some (`String "member_upload") then (match List.assoc_opt "pubkey" k with Some (`String h) -> Some h | _ -> None) else None

let insert_storage (ctx : ctx) ~media_url ~provider ~key ~h ~ext ~mt ~size ~sha256 : unit =
  ignore (q ctx "insert into media_storage (media_url, storage_provider, added_at, key, h, ext, content_type, size, sha256) values ($1,$2,$3::int8,$4,$5,$6,$7,$8::int8,decode($9,'hex')) on conflict do nothing"
            [ Some media_url; Some provider; Some (string_of_int (Utils.current_time ())); Some (key_json key); Some h; Some ext; Some mt; Some (string_of_int size); Some (Hex_util.encode sha256) ])

let s3_domain (p : S3.provider) : string = match p.S3.domain with Some d -> d | None -> p.bucket ^ "." ^ S3.host_of_endpoint p.endpoint

let s3_put (ctx : ctx) (p : S3.provider) ~(key : string) ~(mt : string) (data : string) : unit =
  if not (S3.upload ~net:ctx.net ~clock:ctx.clock p ~content_type:mt key data) then fail "s3 upload to %s failed: %s" p.S3.name key

(* local layout shared by v1 and v2: writes <base><ext>, the <base> symlink *)
let place_local ~(media_path : string) ~(h : string) ~(ext : string) ~(data : string) ~(key : key option) : unit =
  let dirpath = media_path ^ "/" ^ subdir_of_h h in
  Pushgateway.mkdir_p dirpath;
  let base = dirpath ^ "/" ^ h in
  let rnd = rand_hex 12 in
  (match key with
  | Some k -> write_file (base ^ ".key.tmp-" ^ rnd) (key_json k); Sys.rename (base ^ ".key.tmp-" ^ rnd) (base ^ ".key")
  | None -> ());
  write_file (base ^ ".tmp-" ^ rnd) data;
  Sys.rename (base ^ ".tmp-" ^ rnd) (base ^ ext);
  (try Unix.symlink (h ^ ext) (base ^ ".tmp-" ^ rnd); (try Sys.rename (base ^ ".tmp-" ^ rnd) base with _ -> (try Sys.remove (base ^ ".tmp-" ^ rnd) with _ -> ())) with _ -> ())

let media_import_local (ctx : ctx) (k : key) ~(host : string) ~(media_path : string) (fetch : unit -> string) : string =
  let h = key_h k in
  match q ctx "select media_url from media_storage where storage_provider = $1 and h = $2 limit 1" [ Some host; Some h ] with
  | [ Some url ] :: _ -> url
  | _ ->
      let data = fetch () in
      let mt = Media_tools.parse_mimetype ctx data in
      let ext = Media_tools.mimetype_ext mt in
      place_local ~media_path ~h ~ext ~data ~key:(Some k);
      let url = join_url ctx.cfg.media_url_root [ last_segment media_path; subdir_of_h h; h ^ ext ] in
      insert_storage ctx ~media_url:url ~provider:host ~key:k ~h ~ext ~mt ~size:(String.length data) ~sha256:(Pgj.sha256_raw data);
      url

let media_import_s3 (ctx : ctx) (k : key) ~(provider : string) ~(dir : string) (fetch : unit -> string) : string =
  let p = match Media_config.find_s3 ctx.cfg provider with Some p -> p | None -> fail "unknown s3 provider %s" provider in
  let h = key_h k in
  match q ctx "select media_url from media_storage where storage_provider = $1 and h = $2 limit 1" [ Some provider; Some h ] with
  | [ Some url ] :: _ -> url
  | _ ->
      let data = fetch () in
      let mt = Media_tools.parse_mimetype ctx data in
      let ext = Media_tools.mimetype_ext mt in
      let obj = Printf.sprintf "%s/%s/%s%s" (String.concat "/" (List.filter (( <> ) "") (String.split_on_char '/' dir))) (subdir_of_h h) h ext in
      s3_put ctx p ~key:obj ~mt data;
      let url = Printf.sprintf "https://%s/%s" (s3_domain p) obj in
      insert_storage ctx ~media_url:url ~provider ~key:k ~h ~ext ~mt ~size:(String.length data) ~sha256:(Pgj.sha256_raw data);
      url

let paths_of (ctx : ctx) ~(v2 : bool) (which : [ `Cache | `Upload | `Uploadfast ]) : Media_config.path_entry list =
  let p = if v2 then ctx.cfg.media_paths_2 else ctx.cfg.media_paths in
  match which with `Cache -> p.Media_config.cache | `Upload -> p.upload | `Uploadfast -> p.uploadfast

(* Media.media_import: the first provider that takes it (locals only for non-external users) *)
let media_import (ctx : ctx) ?(media_path = `Cache) ?pubkey ?use_external (k : key) (fetch : unit -> string) : string =
  let pubkey = match pubkey with Some p -> Some p | None -> pubkey_of_key k in
  let external_ = match use_external with Some e -> e | None -> ( match pubkey with Some pk -> use_external_storage ctx pk | None -> true) in
  let cached = ref None in
  let fetch () = match !cached with Some d -> d | None -> let d = fetch () in cached := Some d; d in
  let errs = ref [] in
  let result = ref None in
  List.iter
    (fun entry ->
      if !result = None then
        try
          match entry with
          | Media_config.Local { host; path } -> if not external_ then result := Some (media_import_local ctx k ~host ~media_path:path fetch)
          | Media_config.S3 { provider; dir } -> result := Some (media_import_s3 ctx k ~provider ~dir fetch)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn -> errs := Printexc.to_string exn :: !errs)
    (paths_of ctx ~v2:false media_path);
  match !result with Some u -> u | None -> fail "media_import: %s" (match !errs with e :: _ -> e | [] -> "no providers configured")

(* v2: content-addressed *)
let media_import_local_2 (ctx : ctx) (k : key) ~(sha256 : string) ~(host : string) ~(media_path : string) (fetch : unit -> string) : string =
  match q ctx "select media_url from media_storage where storage_provider = $1 and sha256 = decode($2,'hex') limit 1" [ Some host; Some (Hex_util.encode sha256) ] with
  | [ Some url ] :: _ -> url
  | _ ->
      let data = fetch () in
      if Pgj.sha256_raw data <> sha256 then fail "sha256 mismatch for media_import_local_2";
      let h = Hex_util.encode sha256 in
      let mt = Media_tools.parse_mimetype ctx data in
      let ext = Media_tools.mimetype_ext mt in
      place_local ~media_path ~h ~ext ~data ~key:None;
      let url = join_url ctx.cfg.media_url_root [ last_segment media_path; subdir_of_h h; h ^ ext ] in
      insert_storage ctx ~media_url:url ~provider:host ~key:k ~h:(key_h k) ~ext ~mt ~size:(String.length data) ~sha256;
      url

let media_import_s3_2 (ctx : ctx) (k : key) ~(sha256 : string) ~(provider : string) ~(dir : string) (fetch : unit -> string) : string =
  let p = match Media_config.find_s3 ctx.cfg provider with Some p -> p | None -> fail "unknown s3 provider %s" provider in
  match q ctx "select media_url from media_storage where storage_provider = $1 and sha256 = decode($2,'hex') limit 1" [ Some provider; Some (Hex_util.encode sha256) ] with
  | [ Some url ] :: _ -> url
  | _ ->
      let data = fetch () in
      if Pgj.sha256_raw data <> sha256 then fail "sha256 mismatch for media_import_s3_2";
      let h = Hex_util.encode sha256 in
      let mt = Media_tools.parse_mimetype ctx data in
      let ext = Media_tools.mimetype_ext mt in
      let obj = Printf.sprintf "%s/%s/%s%s" (last_segment dir) (subdir_of_h h) h ext in
      s3_put ctx p ~key:obj ~mt data;
      let url = Printf.sprintf "https://%s/%s" (s3_domain p) obj in
      insert_storage ctx ~media_url:url ~provider ~key:k ~h:(key_h k) ~ext ~mt ~size:(String.length data) ~sha256;
      url

(* Media.media_import_2: every provider gets a copy (as the Julia loop did); returns
   BLOSSOM_HOST/<file> of the first *)
let media_import_2 (ctx : ctx) ?(media_path = `Cache) ?pubkey ?use_external (k : key) ~(sha256 : string) (fetch : unit -> string) : string =
  let external_ = match use_external with Some e -> e | None -> ( match pubkey with Some pk -> use_external_storage ctx pk | None -> true) in
  let cached = ref None in
  let fetch () = match !cached with Some d -> d | None -> let d = fetch () in cached := Some d; d in
  let errs = ref [] and rs = ref [] in
  List.iter
    (fun entry ->
      try
        match entry with
        | Media_config.Local { host; path } -> if not external_ then rs := media_import_local_2 ctx k ~sha256 ~host ~media_path:path fetch :: !rs
        | Media_config.S3 { provider; dir } -> rs := media_import_s3_2 ctx k ~sha256 ~provider ~dir fetch :: !rs
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> log "media_import_2 %s: %s" (Hex_util.encode sha256) (Printexc.to_string exn); errs := Printexc.to_string exn :: !errs)
    (paths_of ctx ~v2:true media_path);
  match List.rev !rs with
  | url :: _ -> let file = match List.rev (String.split_on_char '/' url) with f :: _ -> f | [] -> url in ctx.cfg.blossom_host ^ "/" ^ file
  | [] -> fail "media_import_2: %s" (match !errs with e :: _ -> e | [] -> "no providers configured")
