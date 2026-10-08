(* A small S3 client (AWS Signature Version 4, path-style addressing) replacing primal-server/s3.py:
   check (HEAD), delete, copy, upload, get and pre-signed GET URLs. Any S3-compatible endpoint
   (Backblaze, Hetzner, Cloudflare R2). Requests go through [Http.request]; nothing is retried. *)

type provider = {
  name : string;
  endpoint : string; (* https://host[:port] *)
  region : string;
  bucket : string;
  bucket2 : string option; (* the backup bucket purge_media copies into *)
  access_key : string;
  secret_key : string;
  domain : string option; (* the CDN domain in front (Cloudflare cache purge) *)
}

let sha256_hex (s : string) : string = Digestif.SHA256.(to_hex (digest_string s))
let hmac (key : string) (msg : string) : string = Digestif.SHA256.(to_raw_string (hmac_string ~key msg))
let empty_payload_hash = sha256_hex ""

(* AWS URI encoding: unreserved characters kept, '/' kept only in object keys *)
let uri_encode ?(keep_slash = false) (s : string) : string =
  let b = Buffer.create (String.length s * 3) in
  String.iter
    (fun c ->
      if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-' || c = '_' || c = '.' || c = '~' || (keep_slash && c = '/') then Buffer.add_char b c
      else Buffer.add_string b (Printf.sprintf "%%%02X" (Char.code c)))
    s;
  Buffer.contents b

let amz_dates (t : float) : string * string =
  let tm = Unix.gmtime t in
  let date = Printf.sprintf "%04d%02d%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday in
  (date, Printf.sprintf "%sT%02d%02d%02dZ" date tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec)

let signing_key ~secret ~date ~region ~service = hmac (hmac (hmac (hmac ("AWS4" ^ secret) date) region) service) "aws4_request"

let canonical_query (q : (string * string) list) : string =
  List.sort compare (List.map (fun (k, v) -> (uri_encode k, uri_encode v)) q) |> List.map (fun (k, v) -> k ^ "=" ^ v) |> String.concat "&"

let host_of_endpoint (endpoint : string) : string = match Http.parse_url endpoint with Some u -> u.Http.host | None -> endpoint

(* the canonical path of bucket/key in path style *)
let object_path ~(bucket : string) ~(key : string) : string = "/" ^ uri_encode bucket ^ "/" ^ uri_encode ~keep_slash:true key

let string_to_sign ~amz_date ~scope ~canonical_request = String.concat "\n" [ "AWS4-HMAC-SHA256"; amz_date; scope; sha256_hex canonical_request ]

(* Authorization header for a request whose [headers] (lowercase names) include host, x-amz-date
   and x-amz-content-sha256 *)
let authorization (p : provider) ~now ~meth ~path ~(query : (string * string) list) ~(headers : (string * string) list) ~payload_hash : string =
  let date, amz_date = amz_dates now in
  let headers = List.sort compare (List.map (fun (k, v) -> (String.lowercase_ascii k, String.trim v)) headers) in
  let signed = String.concat ";" (List.map fst headers) in
  let canonical_request = String.concat "\n" [ meth; path; canonical_query query; String.concat "" (List.map (fun (k, v) -> k ^ ":" ^ v ^ "\n") headers); signed; payload_hash ] in
  let scope = String.concat "/" [ date; p.region; "s3"; "aws4_request" ] in
  let signature = Digestif.SHA256.(to_hex (hmac_string ~key:(signing_key ~secret:p.secret_key ~date ~region:p.region ~service:"s3") (string_to_sign ~amz_date ~scope ~canonical_request))) in
  Printf.sprintf "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s" p.access_key scope signed signature

(* a pre-signed GET URL (query-string authentication), as boto3 generate_presigned_url *)
let presign_get ?(expires = 3600) ~now (p : provider) ~(bucket : string) ~(key : string) : string =
  let date, amz_date = amz_dates now in
  let scope = String.concat "/" [ date; p.region; "s3"; "aws4_request" ] in
  let host = host_of_endpoint p.endpoint in
  let path = object_path ~bucket ~key in
  let query =
    [ ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"); ("X-Amz-Credential", p.access_key ^ "/" ^ scope); ("X-Amz-Date", amz_date); ("X-Amz-Expires", string_of_int expires); ("X-Amz-SignedHeaders", "host") ]
  in
  let canonical_request = String.concat "\n" [ "GET"; path; canonical_query query; "host:" ^ host ^ "\n"; "host"; "UNSIGNED-PAYLOAD" ] in
  let signature = Digestif.SHA256.(to_hex (hmac_string ~key:(signing_key ~secret:p.secret_key ~date ~region:p.region ~service:"s3") (string_to_sign ~amz_date ~scope ~canonical_request))) in
  Printf.sprintf "%s%s?%s&X-Amz-Signature=%s" p.endpoint path (canonical_query query) signature

let request ~net ~clock ?proxy ?(timeout = 30.0) (p : provider) ~meth ~(bucket : string) ~(key : string) ?(extra_headers = []) ?(body = "") () : Http.response option =
  let now = Unix.gettimeofday () in
  let _, amz_date = amz_dates now in
  let host = host_of_endpoint p.endpoint in
  let path = object_path ~bucket ~key in
  let payload_hash = sha256_hex body in
  let headers = [ ("host", host); ("x-amz-date", amz_date); ("x-amz-content-sha256", payload_hash) ] @ List.map (fun (k, v) -> (String.lowercase_ascii k, v)) extra_headers in
  let auth = authorization p ~now ~meth ~path ~query:[] ~headers ~payload_hash in
  Http.request ~net ~clock ?proxy ~timeout ~meth ~headers:(("Authorization", auth) :: List.filter (fun (k, _) -> k <> "host") headers) ~body ~max_redirects:0 (p.endpoint ^ path)

let ok (r : Http.response option) = match r with Some r -> r.Http.status >= 200 && r.status < 300 | None -> false

let check ~net ~clock ?proxy (p : provider) ?(bucket = p.bucket) (key : string) : bool = ok (request ~net ~clock ?proxy p ~meth:"HEAD" ~bucket ~key ())

(* [check] cannot tell "no such object" from "the request failed"; a purge that silently skips a
   provider on a failed HEAD leaves the object in place (the media host's SOCKS proxy did that on
   2026-10-08). None = the request itself failed or timed out. *)
let check_opt ~net ~clock ?proxy (p : provider) ?(bucket = p.bucket) (key : string) : bool option =
  match request ~net ~clock ?proxy p ~meth:"HEAD" ~bucket ~key () with
  | Some r -> Some (r.Http.status >= 200 && r.status < 300)
  | None -> None
let delete ~net ~clock ?proxy (p : provider) ?(bucket = p.bucket) (key : string) : bool = ok (request ~net ~clock ?proxy p ~meth:"DELETE" ~bucket ~key ())

let copy ~net ~clock ?proxy (p : provider) ~source_bucket ~source_key ~destination_bucket ~destination_key : bool =
  ok (request ~net ~clock ?proxy p ~meth:"PUT" ~bucket:destination_bucket ~key:destination_key ~extra_headers:[ ("x-amz-copy-source", object_path ~bucket:source_bucket ~key:source_key) ] ())

let upload ~net ~clock ?proxy (p : provider) ?(bucket = p.bucket) ~(content_type : string) (key : string) (body : string) : bool =
  ok (request ~net ~clock ?proxy ~timeout:(10.0 +. (float_of_int (String.length body) /. (512. *. 1024.))) p ~meth:"PUT" ~bucket ~key ~extra_headers:[ ("content-type", content_type) ] ~body ())

let get ~net ~clock ?proxy (p : provider) ?(bucket = p.bucket) (key : string) : string option =
  match request ~net ~clock ?proxy ~timeout:120.0 p ~meth:"GET" ~bucket ~key () with Some r when r.Http.status >= 200 && r.status < 300 -> Some r.body | _ -> None
