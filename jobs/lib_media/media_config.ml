(* The "media" sub-object of the jobs config (merged from the Rust primal-media config's
   media/scheduler/tasks sections and the Julia media settings, Media.MEDIA_PATHS etc.). Every key
   required unless noted; null where marked option. Unknown keys are ignored. *)

exception Config_error of string

module U = Yojson.Safe.Util

let field j key = match j with `Assoc f -> ( match List.assoc_opt key f with Some v -> v | None -> raise (Config_error ("media: missing key " ^ key))) | _ -> raise (Config_error "media: config must be an object")
let rstr j k = try U.to_string (field j k) with U.Type_error _ -> raise (Config_error ("media." ^ k ^ ": expected a string"))
let rstr_opt j k = match field j k with `Null -> None | v -> Some (U.to_string v)
let rint j k = try U.to_int (field j k) with U.Type_error _ -> raise (Config_error ("media." ^ k ^ ": expected an integer"))
let field_opt j key = match j with `Assoc f -> List.assoc_opt key f | _ -> None
let rfloat j k = match field j k with `Int i -> float_of_int i | `Float f -> f | _ -> raise (Config_error ("media." ^ k ^ ": expected a number"))
let rbool j k = try U.to_bool (field j k) with U.Type_error _ -> raise (Config_error ("media." ^ k ^ ": expected a boolean"))
let rlist j k = match field j k with `List l -> l | _ -> raise (Config_error ("media." ^ k ^ ": expected a list"))
let rstrlist j k = List.map U.to_string (rlist j k)
let ostr o k = match List.assoc_opt k (match o with `Assoc f -> f | _ -> []) with Some (`String s) -> Some s | _ -> None
let oint o k = match List.assoc_opt k (match o with `Assoc f -> f | _ -> []) with Some (`Int i) -> Some i | _ -> None
let obool o k = match List.assoc_opt k (match o with `Assoc f -> f | _ -> []) with Some (`Bool b) -> b | _ -> false

type path_entry = Local of { host : string; path : string } | S3 of { provider : string; dir : string }
type paths = { uploadfast : path_entry list; upload : path_entry list; cache : path_entry list }

type abr_profile = { pname : string; width : int; height : int; video_bitrate : int; audio_bitrate : int }

type hls_provider = {
  htype : string; (* aws | mux | bunny | cloudflare *)
  enabled : bool;
  api_key : string option;
  api_secret : string option;
  api_token : string option;
  account_id : string option;
  region : string option;
  endpoint : string option;
  library_id : string option;
  cdn_hostname : string option;
  role_arn : string option;
  s3_output_bucket : string option;
  s3_output_path : string option;
  abr_profiles : abr_profile list option;
}

type t = {
  binary_data_cache_dir : string; (* ProcessingGraph.BINARY_DATA_CACHE_DIR *)
  media_url_root : string; (* "https://media.primal.net" *)
  tmp_dir : string;
  proxies : string list; (* socks5[h]://host:port, rotated for downloads *)
  metadata_proxy : string option; (* link previews (import_preview_pn); None or "null" = direct *)
  download_timeout_s : float;
  strip_image_metadata : bool;
  s3_providers : S3.provider list;
  hls_providers : hls_provider list;
  hls_processing_timeout_s : float;
  media_paths : paths; (* Media.MEDIA_PATHS *)
  media_paths_2 : paths; (* Media.MEDIA_PATHS_2 *)
  ai_host : string; (* the AI host: ollama 11434, classifiers 5012.., features 5013/5014 *)
  ai_timeout_s : float;
  blossom_host : string; (* media_import_2 returns BLOSSOM_HOST/<file> *)
  ffmpeg_remote_host : string option;
  scheduler_period_s : float; (* claim period *)
  worker_domains : int; (* domains executing nodes (the scheduler claims on its own); default 8 *)
  worker_pool_size : int; (* cache-DB connections per worker domain; default 8 (membership: 3) *)
  max_concurrent_per_name : int; (* running-node limit per func (Rust tasks.max_concurrent_per_name) *)
  julia_duty_concurrency : int; (* running-node limit of import_upload_3 / block_media / purge_media_ (the funcs Julia used to run; the name is kept for the configs) *)
  refresh_matview_period_s : float; (* pn_time_for_pubkeys refresh period *)
  cloudflare_cache : (string * string) option; (* zone_id, api_key for purge *)
  blossom_hosts : string list; (* purge_media_: ["blossom.primal.net", "blossom-dev.primal.net"] *)
  upload_url_root : string; (* "https://_media.primal.net" *)
  user_content_purger_api : string option; (* MediaAnalysis.USER_CONTENT_PURGER_API *)
  execute_funcs : string list; (* the funcs this executor claims; everything else stays pending *)
  log : bool;
}

let path_entry_of_json (j : Yojson.Safe.t) : path_entry =
  match ostr j "type" with
  | Some "local" -> Local { host = rstr j "host"; path = rstr j "path" }
  | Some "s3" -> S3 { provider = rstr j "provider"; dir = rstr j "dir" }
  | _ -> raise (Config_error "media_paths: entry type must be local or s3")

let paths_of_json (j : Yojson.Safe.t) : paths =
  let l k = match field j k with `List l -> List.map path_entry_of_json l | _ -> raise (Config_error ("media_paths." ^ k ^ ": expected a list")) in
  { uploadfast = l "uploadfast"; upload = l "upload"; cache = l "cache" }

let s3_of_json (j : Yojson.Safe.t) : S3.provider =
  { S3.name = rstr j "name"; endpoint = rstr j "endpoint"; region = rstr j "region"; bucket = rstr j "bucket"; bucket2 = ostr j "bucket2"; access_key = rstr j "access_key"; secret_key = rstr j "secret_key"; domain = ostr j "domain" }

let hls_of_json (j : Yojson.Safe.t) : hls_provider =
  { htype = rstr j "type"; enabled = obool j "enabled"; api_key = ostr j "api_key"; api_secret = ostr j "api_secret"; api_token = ostr j "api_token"; account_id = ostr j "account_id"; region = ostr j "region"; endpoint = ostr j "endpoint";
    library_id = ostr j "library_id"; cdn_hostname = ostr j "cdn_hostname"; role_arn = ostr j "role_arn"; s3_output_bucket = ostr j "s3_output_bucket"; s3_output_path = ostr j "s3_output_path";
    abr_profiles = (match List.assoc_opt "abr_profiles" (match j with `Assoc f -> f | _ -> []) with
                   | Some (`List l) -> Some (List.map (fun p -> { pname = rstr p "name"; width = rint p "width"; height = rint p "height"; video_bitrate = rint p "video_bitrate"; audio_bitrate = rint p "audio_bitrate" }) l)
                   | _ -> None) }

let default_execute_funcs = [ "import_media_fast_pn"; "import_media_fast_pn_2"; "import_media_pn"; "import_preview_pn"; "import_media_hls_pn"; "import_text_event_pn"; "import_upload_3"; "block_media"; "purge_media_"; "inc_counter" ]

let of_json (j : Yojson.Safe.t) : t =
  {
    binary_data_cache_dir = rstr j "binary_data_cache_dir";
    media_url_root = rstr j "media_url_root";
    tmp_dir = rstr j "tmp_dir";
    proxies = rstrlist j "proxies";
    metadata_proxy = rstr_opt j "metadata_proxy";
    download_timeout_s = rfloat j "download_timeout_s";
    strip_image_metadata = rbool j "strip_image_metadata";
    s3_providers = List.map s3_of_json (rlist j "s3_providers");
    hls_providers = List.map hls_of_json (rlist j "hls_providers");
    hls_processing_timeout_s = rfloat j "hls_processing_timeout_s";
    media_paths = paths_of_json (field j "media_paths");
    media_paths_2 = paths_of_json (field j "media_paths_2");
    ai_host = rstr j "ai_host";
    ai_timeout_s = rfloat j "ai_timeout_s";
    blossom_host = rstr j "blossom_host";
    ffmpeg_remote_host = rstr_opt j "ffmpeg_remote_host";
    scheduler_period_s = rfloat j "scheduler_period_s";
    worker_domains = (match field_opt j "worker_domains" with Some (`Int n) when n >= 1 -> n | _ -> 8);
    worker_pool_size = (match field_opt j "worker_pool_size" with Some (`Int n) when n >= 1 -> n | _ -> 8);
    max_concurrent_per_name = rint j "max_concurrent_per_name";
    julia_duty_concurrency = rint j "julia_duty_concurrency";
    refresh_matview_period_s = rfloat j "refresh_matview_period_s";
    cloudflare_cache = (match field j "cloudflare_cache" with `Null -> None | o -> Some (rstr o "zone_id", rstr o "api_key"));
    blossom_hosts = rstrlist j "blossom_hosts";
    upload_url_root = rstr j "upload_url_root";
    user_content_purger_api = rstr_opt j "user_content_purger_api";
    execute_funcs = (match field j "execute_funcs" with `Null -> default_execute_funcs | _ -> rstrlist j "execute_funcs");
    log = rbool j "log";
  }

(* "socks5h://host:port" -> (host, port) *)
let parse_proxy (s : string) : (string * int) option =
  let s = String.trim s in
  let rest = match Str_util.find_substring s "://" with Some i -> String.sub s (i + 3) (String.length s - i - 3) | None -> s in
  let rest = match String.index_opt rest '/' with Some i -> String.sub rest 0 i | None -> rest in
  match String.rindex_opt rest ':' with Some i -> ( match int_of_string_opt (String.sub rest (i + 1) (String.length rest - i - 1)) with Some p -> Some (String.sub rest 0 i, p) | None -> None) | None -> None

let find_s3 (t : t) (name : string) : S3.provider option = List.find_opt (fun (p : S3.provider) -> p.S3.name = name) t.s3_providers
