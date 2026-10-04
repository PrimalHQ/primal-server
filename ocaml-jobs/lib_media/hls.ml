(* hls_providers.rs: submit a video URL for HLS transcoding and poll until the playlist exists.
   Mux, Bunny Stream and Cloudflare Stream are JSON APIs; AWS MediaConvert is SigV4-signed JSON
   (account endpoint discovered with DescribeEndpoints), its assets deleted from the output S3
   bucket. process_video polls with 2 s doubling-and-a-half backoff up to 30 s. *)

open Procgraph
module C = Media_config

type status = Queued | Processing | Completed | Failed of string

let json_request (ctx : ctx) ~(meth : string) ?(headers = []) ?(body = "") (url : string) : (int * Pgj.t) option =
  match Http.request ~net:ctx.net ~clock:ctx.clock ~timeout:30.0 ~meth ~headers ~body url with
  | Some r -> Some (r.status, (try Yojson.Safe.from_string r.body with _ -> `String r.body))
  | None -> None

let get (j : Pgj.t) path : Pgj.t = List.fold_left (fun acc k -> match acc with `Assoc f -> Option.value (List.assoc_opt k f) ~default:`Null | `List l -> ( match int_of_string_opt k with Some i -> (try List.nth l i with _ -> `Null) | None -> `Null) | _ -> `Null) j path
let gets j path = match get j path with `String s -> Some s | _ -> None
let basic_auth u p = "Basic " ^ Base64.encode_string (u ^ ":" ^ p)
let req_opt (name : string) = function Some v -> v | None -> fail "%s is required" name

(* {1 SigV4 for a JSON API (AWS MediaConvert)} *)
let sigv4_headers ~access_key ~secret_key ~region ~service ~meth ~host ~path ~(query : (string * string) list) ~body ~content_type : (string * string) list =
  let now = Unix.gettimeofday () in
  let date, amz_date = S3.amz_dates now in
  let payload_hash = S3.sha256_hex body in
  let headers = List.sort compare [ ("content-type", content_type); ("host", host); ("x-amz-content-sha256", payload_hash); ("x-amz-date", amz_date) ] in
  let signed = String.concat ";" (List.map fst headers) in
  let canonical_request = String.concat "\n" [ meth; path; S3.canonical_query query; String.concat "" (List.map (fun (k, v) -> k ^ ":" ^ v ^ "\n") headers); signed; payload_hash ] in
  let scope = String.concat "/" [ date; region; service; "aws4_request" ] in
  let signature = Digestif.SHA256.(to_hex (hmac_string ~key:(S3.signing_key ~secret:secret_key ~date ~region ~service) (S3.string_to_sign ~amz_date ~scope ~canonical_request))) in
  [ ("Authorization", Printf.sprintf "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s" access_key scope signed signature); ("Content-Type", content_type); ("x-amz-content-sha256", payload_hash); ("x-amz-date", amz_date) ]

let aws_call (ctx : ctx) (p : C.hls_provider) ~(service : string) ~(meth : string) ~(endpoint : string) ~(path : string) ?(query = []) (body : string) : (int * Pgj.t) option =
  let region = req_opt "AWS region" p.region in
  let access_key = req_opt "AWS access key" p.api_key and secret_key = req_opt "AWS secret key" p.api_secret in
  let host = S3.host_of_endpoint endpoint in
  let headers = sigv4_headers ~access_key ~secret_key ~region ~service ~meth ~host ~path ~query ~body ~content_type:"application/json" in
  let url = endpoint ^ path ^ (if query = [] then "" else "?" ^ S3.canonical_query query) in
  json_request ctx ~meth ~headers ~body url

let mediaconvert_endpoint (ctx : ctx) (p : C.hls_provider) : string =
  match p.endpoint with
  | Some e -> e
  | None -> (
      let region = req_opt "AWS region" p.region in
      let base = Printf.sprintf "https://mediaconvert.%s.amazonaws.com" region in
      match aws_call ctx p ~service:"mediaconvert" ~meth:"POST" ~endpoint:base ~path:"/2017-08-29/endpoints" "{\"MaxResults\":1}" with
      | Some (200, j) -> ( match gets j [ "Endpoints"; "0"; "Url" ] with Some u -> u | None -> fail "MediaConvert DescribeEndpoints: no endpoint") 
      | Some (st, j) -> fail "MediaConvert DescribeEndpoints: HTTP %d %s" st (Yojson.Safe.to_string j)
      | None -> fail "MediaConvert DescribeEndpoints failed")

let default_abr = [ { C.pname = "1080p"; width = 1920; height = 1080; video_bitrate = 5000000; audio_bitrate = 128000 }; { pname = "720p"; width = 1280; height = 720; video_bitrate = 3000000; audio_bitrate = 128000 }; { pname = "480p"; width = 854; height = 480; video_bitrate = 1500000; audio_bitrate = 96000 }; { pname = "360p"; width = 640; height = 360; video_bitrate = 800000; audio_bitrate = 96000 } ]

let aws_submit (ctx : ctx) (p : C.hls_provider) ~(video_url : string) : string =
  let endpoint = mediaconvert_endpoint ctx p in
  let job_uuid = Pgj.sha256_hex (Printf.sprintf "%f-%d-%s" (Unix.gettimeofday ()) (Random.bits ()) video_url) in
  let job_uuid = Printf.sprintf "%s-%s-%s-%s-%s" (String.sub job_uuid 0 8) (String.sub job_uuid 8 4) (String.sub job_uuid 12 4) (String.sub job_uuid 16 4) (String.sub job_uuid 20 12) in
  let destination = Printf.sprintf "s3://%s/%s/%s/hls" (req_opt "AWS S3 output bucket" p.s3_output_bucket) (Option.value p.s3_output_path ~default:"hls-output") job_uuid in
  let outputs =
    List.map
      (fun (pr : C.abr_profile) ->
        `Assoc
          [ ("NameModifier", `String ("_" ^ pr.pname)); ("ContainerSettings", `Assoc [ ("Container", `String "M3U8") ]);
            ("VideoDescription", `Assoc [ ("Width", `Int pr.width); ("Height", `Int pr.height); ("CodecSettings", `Assoc [ ("Codec", `String "H_264"); ("H264Settings", `Assoc [ ("RateControlMode", `String "QVBR"); ("CodecProfile", `String "MAIN"); ("MaxBitrate", `Int pr.video_bitrate) ]) ]) ]);
            ("AudioDescriptions", `List [ `Assoc [ ("AudioSourceName", `String "Audio Selector 1"); ("CodecSettings", `Assoc [ ("Codec", `String "AAC"); ("AacSettings", `Assoc [ ("CodecProfile", `String "LC"); ("RateControlMode", `String "CBR"); ("CodingMode", `String "CODING_MODE_2_0"); ("SampleRate", `Int 48000); ("Bitrate", `Int pr.audio_bitrate) ]) ]) ] ]) ])
      (Option.value p.abr_profiles ~default:default_abr)
  in
  let body =
    `Assoc
      [ ("Role", `String (req_opt "AWS MediaConvert IAM role ARN" p.role_arn));
        ("Settings", `Assoc [ ("Inputs", `List [ `Assoc [ ("FileInput", `String video_url); ("AudioSelectors", `Assoc [ ("Audio Selector 1", `Assoc [ ("DefaultSelection", `String "DEFAULT") ]) ]) ] ]);
                              ("OutputGroups", `List [ `Assoc [ ("Name", `String "HLS ABR Group"); ("OutputGroupSettings", `Assoc [ ("Type", `String "HLS_GROUP_SETTINGS"); ("HlsGroupSettings", `Assoc [ ("Destination", `String destination); ("StreamInfResolution", `String "INCLUDE"); ("SegmentLength", `Int 6); ("MinSegmentLength", `Int 0) ]) ]); ("Outputs", `List outputs) ] ]) ]);
        ("AccelerationSettings", `Assoc [ ("Mode", `String "DISABLED") ]); ("UserMetadata", `Assoc [ ("source_url", `String video_url); ("job_name", `String ("hls_transcode_" ^ job_uuid)) ]) ]
  in
  match aws_call ctx p ~service:"mediaconvert" ~meth:"POST" ~endpoint ~path:"/2017-08-29/jobs" (Yojson.Safe.to_string body) with
  | Some (st, j) when st >= 200 && st < 300 -> ( match gets j [ "Job"; "Id" ] with Some id -> id | None -> fail "MediaConvert CreateJob: no job id")
  | Some (st, j) -> fail "MediaConvert CreateJob: HTTP %d %s" st (Yojson.Safe.to_string j)
  | None -> fail "MediaConvert CreateJob failed"

let aws_get_job (ctx : ctx) (p : C.hls_provider) (job_id : string) : Pgj.t =
  let endpoint = mediaconvert_endpoint ctx p in
  match aws_call ctx p ~service:"mediaconvert" ~meth:"GET" ~endpoint ~path:("/2017-08-29/jobs/" ^ job_id) "" with
  | Some (200, j) -> get j [ "Job" ]
  | Some (st, j) -> fail "MediaConvert GetJob: HTTP %d %s" st (Yojson.Safe.to_string j)
  | None -> fail "MediaConvert GetJob failed"

let aws_destination (job : Pgj.t) = gets job [ "Settings"; "OutputGroups"; "0"; "OutputGroupSettings"; "HlsGroupSettings"; "Destination" ]

let aws_poll (ctx : ctx) (p : C.hls_provider) (job_id : string) : status * string option =
  let job = aws_get_job ctx p job_id in
  let st = match gets job [ "Status" ] with Some "SUBMITTED" -> Queued | Some "PROGRESSING" -> Processing | Some "COMPLETE" -> Completed | Some "CANCELED" -> Failed "Job was canceled" | Some "ERROR" -> Failed (Option.value (gets job [ "ErrorMessage" ]) ~default:"Unknown error") | _ -> Processing in
  let hls_url =
    if st = Completed then
      Option.map
        (fun dest ->
          if String.length dest > 5 && String.sub dest 0 5 = "s3://" then
            let rest = String.sub dest 5 (String.length dest - 5) in
            match String.index_opt rest '/' with Some i -> Printf.sprintf "https://%s.s3.amazonaws.com/%s.m3u8" (String.sub rest 0 i) (String.sub rest (i + 1) (String.length rest - i - 1)) | None -> dest
          else dest)
        (aws_destination job)
    else None
  in
  (st, hls_url)

(* list + delete the S3 objects under the job's destination prefix *)
let aws_s3_provider (p : C.hls_provider) ~(bucket : string) : S3.provider =
  let region = req_opt "AWS region" p.region in
  { S3.name = "aws"; endpoint = Printf.sprintf "https://s3.%s.amazonaws.com" region; region; bucket; bucket2 = None; access_key = req_opt "AWS access key" p.api_key; secret_key = req_opt "AWS secret key" p.api_secret; domain = None }

let s3_list_keys (ctx : ctx) (sp : S3.provider) ~(prefix : string) : string list =
  let now = Unix.gettimeofday () in
  let _, amz_date = S3.amz_dates now in
  let host = S3.host_of_endpoint sp.endpoint in
  let path = "/" ^ S3.uri_encode sp.bucket in
  let query = [ ("list-type", "2"); ("prefix", prefix) ] in
  let payload_hash = S3.sha256_hex "" in
  let headers = [ ("host", host); ("x-amz-date", amz_date); ("x-amz-content-sha256", payload_hash) ] in
  let auth = S3.authorization sp ~now ~meth:"GET" ~path ~query ~headers ~payload_hash in
  match Http.request ~net:ctx.net ~clock:ctx.clock ~timeout:30.0 ~meth:"GET" ~headers:(("Authorization", auth) :: List.filter (fun (k, _) -> k <> "host") headers) ~max_redirects:0 (sp.endpoint ^ path ^ "?" ^ S3.canonical_query query) with
  | Some r when r.status = 200 ->
      let re = Str.regexp "<Key>\\([^<]*\\)</Key>" in
      let rec all pos acc = match Str.search_forward re r.body pos with i -> all (i + 1) (Str.matched_group 1 r.body :: acc) | exception Not_found -> List.rev acc in
      all 0 []
  | Some r -> fail "S3 list failed: HTTP %d" r.status
  | None -> fail "S3 list failed"

let aws_delete (ctx : ctx) (p : C.hls_provider) (job_id : string) : unit =
  let job = aws_get_job ctx p job_id in
  match aws_destination job with
  | Some dest when String.length dest > 5 && String.sub dest 0 5 = "s3://" -> (
      let rest = String.sub dest 5 (String.length dest - 5) in
      match String.index_opt rest '/' with
      | Some i ->
          let bucket = String.sub rest 0 i and prefix = String.sub rest (i + 1) (String.length rest - i - 1) in
          let sp = aws_s3_provider p ~bucket in
          List.iter (fun key -> if not (S3.delete ~net:ctx.net ~clock:ctx.clock sp key) then fail "Failed to delete S3 object: %s" key) (s3_list_keys ctx sp ~prefix)
      | None -> fail "Could not determine S3 location for job %s" job_id)
  | _ -> fail "Could not determine S3 location for job %s" job_id

(* {1 Mux} *)
let mux_auth (p : C.hls_provider) = basic_auth (req_opt "Mux API token ID" p.api_key) (req_opt "Mux API token secret" p.api_secret)
let mux_submit ctx p ~video_url =
  match json_request ctx ~meth:"POST" ~headers:[ ("Authorization", mux_auth p); ("Content-Type", "application/json") ] ~body:(Yojson.Safe.to_string (`Assoc [ ("input", `List [ `Assoc [ ("url", `String video_url) ] ]); ("playback_policy", `List [ `String "public" ]) ])) "https://api.mux.com/video/v1/assets" with
  | Some (st, j) when st >= 200 && st < 300 -> Option.get (gets j [ "data"; "id" ])
  | Some (st, j) -> fail "Mux API error %d: %s" st (Yojson.Safe.to_string j)
  | None -> fail "Failed to submit Mux job"
let mux_poll ctx p job_id =
  match json_request ctx ~meth:"GET" ~headers:[ ("Authorization", mux_auth p) ] ("https://api.mux.com/video/v1/assets/" ^ job_id) with
  | Some (200, j) ->
      let st = match gets j [ "data"; "status" ] with Some ("preparing" | "waiting") -> Queued | Some "ready" -> Completed | Some "errored" -> Failed "Mux asset in errored state" | _ -> Processing in
      (st, if st = Completed then Option.map (fun id -> Printf.sprintf "https://stream.mux.com/%s.m3u8" id) (gets j [ "data"; "playback_ids"; "0"; "id" ]) else None)
  | Some (st, j) -> fail "Mux API error %d: %s" st (Yojson.Safe.to_string j)
  | None -> fail "Failed to poll Mux status"
let mux_delete ctx p asset_id =
  match json_request ctx ~meth:"DELETE" ~headers:[ ("Authorization", mux_auth p) ] ("https://api.mux.com/video/v1/assets/" ^ asset_id) with Some (st, _) when st >= 200 && st < 300 -> () | Some (st, j) -> fail "Mux delete API error %d: %s" st (Yojson.Safe.to_string j) | None -> fail "Failed to delete Mux asset"

(* {1 Bunny Stream} *)
let bunny_submit ctx (p : C.hls_provider) ~video_url =
  let key = req_opt "Bunny Stream API key" p.api_key and lib = req_opt "Bunny Stream library ID" p.library_id in
  let hdr = [ ("AccessKey", key); ("Content-Type", "application/json") ] in
  match json_request ctx ~meth:"POST" ~headers:hdr ~body:(Yojson.Safe.to_string (`Assoc [ ("title", `String (Printf.sprintf "video_%d" (Utils.current_time ()))) ])) (Printf.sprintf "https://video.bunnycdn.com/library/%s/videos" lib) with
  | Some (st, j) when st >= 200 && st < 300 -> (
      let guid = Option.get (gets j [ "guid" ]) in
      match json_request ctx ~meth:"POST" ~headers:hdr ~body:(Yojson.Safe.to_string (`Assoc [ ("url", `String video_url) ])) (Printf.sprintf "https://video.bunnycdn.com/library/%s/videos/%s/fetch" lib guid) with
      | Some (st, _) when st >= 200 && st < 300 -> guid
      | Some (st, j) -> fail "Bunny fetch API error %d: %s" st (Yojson.Safe.to_string j)
      | None -> fail "Failed to fetch Bunny video")
  | Some (st, j) -> fail "Bunny API error %d: %s" st (Yojson.Safe.to_string j)
  | None -> fail "Failed to create Bunny video"
let bunny_poll ctx (p : C.hls_provider) job_id =
  let key = req_opt "Bunny Stream API key" p.api_key and lib = req_opt "Bunny Stream library ID" p.library_id in
  match json_request ctx ~meth:"GET" ~headers:[ ("AccessKey", key) ] (Printf.sprintf "https://video.bunnycdn.com/library/%s/videos/%s" lib job_id) with
  | Some (200, j) ->
      let st = match get j [ "status" ] with `Int 0 -> Queued | `Int (1 | 2) -> Processing | `Int (3 | 4) -> Completed | `Int 5 -> Failed "Encoding error" | _ -> Processing in
      (st, if st = Completed then Some (Printf.sprintf "https://%s/%s/playlist.m3u8" (req_opt "Bunny Stream CDN hostname" p.cdn_hostname) job_id) else None)
  | Some (st, j) -> fail "Bunny API error %d: %s" st (Yojson.Safe.to_string j)
  | None -> fail "Failed to poll Bunny status"
let bunny_delete ctx (p : C.hls_provider) asset_id =
  match json_request ctx ~meth:"DELETE" ~headers:[ ("AccessKey", req_opt "Bunny Stream API key" p.api_key) ] (Printf.sprintf "https://video.bunnycdn.com/library/%s/videos/%s" (req_opt "Bunny Stream library ID" p.library_id) asset_id) with
  | Some (st, _) when st >= 200 && st < 300 -> ()
  | Some (st, j) -> fail "Bunny delete API error %d: %s" st (Yojson.Safe.to_string j)
  | None -> fail "Failed to delete Bunny video"

(* {1 Cloudflare Stream} *)
let cf_creds (p : C.hls_provider) = (req_opt "Cloudflare API token" (match p.api_token with Some t -> Some t | None -> p.api_key), req_opt "Cloudflare account ID" (match p.account_id with Some a -> Some a | None -> p.api_secret))
let cf_check j = match get j [ "success" ] with `Bool true -> () | _ -> fail "Cloudflare API errors: %s" (String.concat ", " (match get j [ "errors" ] with `List l -> List.filter_map (fun e -> gets e [ "message" ]) l | _ -> []))
let cf_submit ctx p ~video_url =
  let token, account = cf_creds p in
  match json_request ctx ~meth:"POST" ~headers:[ ("Authorization", "Bearer " ^ token); ("Content-Type", "application/json") ] ~body:(Yojson.Safe.to_string (`Assoc [ ("url", `String video_url); ("meta", `Assoc [ ("name", `String (Printf.sprintf "video_%d" (Utils.current_time ()))) ]) ])) (Printf.sprintf "https://api.cloudflare.com/client/v4/accounts/%s/stream/copy" account) with
  | Some (st, j) when st >= 200 && st < 300 -> cf_check j; Option.get (gets j [ "result"; "uid" ])
  | Some (st, j) -> fail "Cloudflare API error %d: %s" st (Yojson.Safe.to_string j)
  | None -> fail "Failed to submit Cloudflare Stream job"
let cf_poll ctx p job_id =
  let token, account = cf_creds p in
  match json_request ctx ~meth:"GET" ~headers:[ ("Authorization", "Bearer " ^ token) ] (Printf.sprintf "https://api.cloudflare.com/client/v4/accounts/%s/stream/%s" account job_id) with
  | Some (200, j) ->
      cf_check j;
      let st = match gets j [ "result"; "status"; "state" ] with Some ("queued" | "downloading") -> Queued | Some ("processing" | "encoding") -> Processing | Some "ready" -> Completed | Some "error" -> Failed "Cloudflare Stream encoding error" | _ -> Processing in
      (st, if st = Completed then gets j [ "result"; "playback"; "hls" ] else None)
  | Some (st, j) -> fail "Cloudflare API error %d: %s" st (Yojson.Safe.to_string j)
  | None -> fail "Failed to poll Cloudflare status"
let cf_delete ctx p asset_id =
  let token, account = cf_creds p in
  match json_request ctx ~meth:"DELETE" ~headers:[ ("Authorization", "Bearer " ^ token) ] (Printf.sprintf "https://api.cloudflare.com/client/v4/accounts/%s/stream/%s" account asset_id) with
  | Some (st, j) when st >= 200 && st < 300 -> ( match j with `Assoc _ -> cf_check j | _ -> ())
  | Some (st, j) -> fail "Cloudflare delete API error %d: %s" st (Yojson.Safe.to_string j)
  | None -> fail "Failed to delete Cloudflare Stream video"

(* {1 dispatch} *)
let submit ctx (p : C.hls_provider) ~video_url = match p.htype with "aws" -> aws_submit ctx p ~video_url | "mux" -> mux_submit ctx p ~video_url | "bunny" -> bunny_submit ctx p ~video_url | "cloudflare" -> cf_submit ctx p ~video_url | t -> fail "Unknown HLS provider type: %s" t
let poll ctx (p : C.hls_provider) job_id = match p.htype with "aws" -> aws_poll ctx p job_id | "mux" -> mux_poll ctx p job_id | "bunny" -> bunny_poll ctx p job_id | "cloudflare" -> cf_poll ctx p job_id | t -> fail "Unknown HLS provider type: %s" t
let delete_asset ctx (p : C.hls_provider) asset_id = match p.htype with "aws" -> aws_delete ctx p asset_id | "mux" -> mux_delete ctx p asset_id | "bunny" -> bunny_delete ctx p asset_id | "cloudflare" -> cf_delete ctx p asset_id | t -> fail "Unknown HLS provider type: %s" t

(* HlsProvider::process_video: (hls_url, asset_id) *)
let process_video (ctx : ctx) (p : C.hls_provider) ~(video_url : string) ~(max_wait : float) : (string * string, string) result =
  try
    let job_id = submit ctx p ~video_url in
    let t0 = Unix.gettimeofday () in
    let backoff = ref 2.0 in
    let rec loop () =
      if Unix.gettimeofday () -. t0 > max_wait then Error "Timeout waiting for transcoding to complete"
      else begin
        Eio.Time.sleep ctx.clock !backoff;
        match poll ctx p job_id with
        | Completed, Some url -> Ok (url, job_id)
        | Completed, None -> Error "Job completed but no HLS URL returned"
        | Failed m, _ -> Error ("Transcoding failed: " ^ m)
        | (Queued | Processing), _ -> backoff := Float.min (!backoff *. 1.5) 30.0; loop ()
      end
    in
    loop ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Node_error m -> Error m
  | exn -> Error (Printexc.to_string exn)
