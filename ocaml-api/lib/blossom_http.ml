(* Blossom on 21000+N (src/blossom.jl): BUD-01/02/04/05 with kind-24242 authorization. The read
   side (GET /<sha256>, HEAD, /list/<pubkey>) and DELETE (purge_media) are native; PUT /upload,
   /media and /mirror need the upload importer (import_upload_2 is missing at HEAD, ocaml-plan.md
   §10.2) and answer 500 "uploads not available" until the media phase lands it. *)

open Http_server

exception Blossom_error of int * string

let mimetype_ext =
  [ ("image/jpeg", ".jpg"); ("image/png", ".png"); ("image/gif", ".gif"); ("image/webp", ".webp"); ("image/svg+xml", ".svg"); ("video/mp4", ".mp4"); ("video/x-m4v", ".mp4");
    ("video/mov", ".mov"); ("video/webp", ".webp"); ("video/webm", ".webm"); ("video/quicktime", ".mov"); ("video/x-matroska", ".mkv"); ("video/3gpp", ".3gp");
    ("image/vnd.microsoft.icon", ".ico"); ("text/plain", ".txt"); ("application/json", ".json"); ("text/html", ".html"); ("text/javascript", ".js"); ("application/wasm", ".wasm") ]

let ext_of_mimetype (m : string option) : string = match m with Some m -> Option.value (List.assoc_opt m mimetype_ext) ~default:"" | None -> ""
let headers ct extra = ("content-type", ct) :: extra
let text status ?(extra = []) body = Raw (status, headers "text/plain" extra, body)

type blob = { media_url : string; mimetype : string option; size : int64 option; sha256 : string; pubkey : string; path : string }

(* the hex sha256 of a /<sha256>[.ext] target *)
let sha_of_target (path : string) : string option =
  let name = if String.length path > 0 && path.[0] = '/' then String.sub path 1 (String.length path - 1) else path in
  let h = match String.index_opt name '.' with Some i -> String.sub name 0 i | None -> name in
  let h = String.lowercase_ascii h in
  if String.length h = 64 then Hex_util.decode_opt h else None

(* find_upload: an unblocked upload by hash, served from the preferred storage or a local root *)
let find_upload (ctx : Handlers.ctx) (sha256 : string) : blob option =
  match Handlers.with_membership ctx (fun m -> Queries_mem.blossom_upload_by_sha256 m ~sha256) with
  | None -> None
  | Some u -> (
      let path = u.Queries_mem.up_path in
      let base = match String.rindex_opt path '/' with Some i -> String.sub path (i + 1) (String.length path - i - 1) | None -> path in
      let kh = match String.rindex_opt base '.' with Some i -> String.sub base 0 i | None -> base in
      match Handlers.with_cache ctx (fun c -> Queries.media_storage_by_hash_full c ~h:kh) with
      | Some (media_url, ct, size, _) -> Some { media_url; mimetype = Some ct; size = Some size; sha256; pubkey = u.up_pubkey; path }
      | None ->
          List.find_map
            (fun root -> if Sys.file_exists (root ^ path) then Some { media_url = "https://media.primal.net" ^ path; mimetype = Some u.up_mimetype; size = Some u.up_size; sha256; pubkey = u.up_pubkey; path } else None)
            ctx.cfg.blossom_local_roots)

(* check_action: "Authorization: Nostr <base64 kind-24242 event>" with the action in a t tag,
   unexpired, and the blob hash in an x tag when one is required *)
let check_action (r : req) (action : string) ~(x_tag_hash : string option) : Nostr.t =
  let parts = match req_header r "authorization" with Some v -> String.split_on_char ' ' v |> List.filter (fun s -> s <> "") | None -> [] in
  (match parts with [ _; _ ] -> () | _ -> raise (Blossom_error (400, "missing auth event")));
  if List.hd parts <> "Nostr" then raise (Blossom_error (400, "invalid auth event"));
  let e =
    match Base64.decode (List.nth parts 1) with
    | Ok s -> ( try Nostr.of_json (Yojson.Safe.from_string s) with _ -> raise (Blossom_error (500, "unspecified error")))
    | Error _ -> raise (Blossom_error (500, "unspecified error"))
  in
  if not (Nostr.verify e) then raise (Blossom_error (400, "auth event verification failed"));
  if e.Nostr.kind <> 24242 then raise (Blossom_error (400, "wrong kind in auth event"));
  let action_ok = ref false and x_tag_ok = ref (x_tag_hash = None) in
  List.iter
    (fun tg ->
      match tg with
      | `String "expiration" :: `String v :: _ -> if (match int_of_string_opt v with Some t -> t | None -> raise (Blossom_error (500, "unspecified error"))) <= Handlers.now () then raise (Blossom_error (400, "auth event expired"))
      | `String "t" :: `String a :: _ -> if a = action then action_ok := true
      | `String "x" :: `String h :: _ -> ( match x_tag_hash with Some want -> if Hex_util.decode_opt h = Some want then x_tag_ok := true | None -> ())
      | _ -> ())
    e.Nostr.tags;
  if not !action_ok then raise (Blossom_error (400, "invalid action in auth event"));
  if not !x_tag_ok then raise (Blossom_error (400, "invalid x tag"));
  e

let blob_json ~(base_url : string) ~sha256 ~mimetype ~size ~uploaded : Yojson.Safe.t =
  let hex = Hex_util.encode sha256 in
  `Assoc
    [ ("url", `String (base_url ^ "/" ^ hex ^ ext_of_mimetype mimetype)); ("sha256", `String hex); ("size", match size with Some s -> `Int (Int64.to_int s) | None -> `Null);
      ("type", match mimetype with Some m -> `String m | None -> `Null); ("uploaded", match uploaded with Some t -> `Int (Int64.to_int t) | None -> `Null) ]

let handler (ctx : Handlers.ctx) (r : req) : resp =
  try
    match r.raw_meth with
    | "GET" when r.path = "/" -> text 200 "Welcome to Primal Blossom server. Implemented: BUD-01, BUD-02, BUD-04, BUD-05"
    | "GET" when String.starts_with ~prefix:"/list/" r.path -> (
        let last = match String.rindex_opt r.path '/' with Some i -> String.sub r.path (i + 1) (String.length r.path - i - 1) | None -> "" in
        match Hex_util.decode_opt last with
        | Some pk when String.length pk = 32 ->
            let ups = Handlers.with_membership ctx (fun m -> Queries_mem.blossom_uploads_by_pubkey m ~pubkey:pk) in
            let items = List.filter_map (fun (u : Queries_mem.upload) -> match u.up_sha256 with Some sha256 -> Some (blob_json ~base_url:ctx.cfg.blossom_base_url ~sha256 ~mimetype:(Some u.up_mimetype) ~size:(Some u.up_size) ~uploaded:(Some u.up_created_at)) | None -> None) ups in
            Raw (200, headers "application/json" [], Yojson.Safe.to_string (`List items))
        | _ -> raise (Blossom_error (500, "unspecified error")))
    | "GET" -> (
        match sha_of_target r.path with
        | Some sha256 -> (
            match find_upload ctx sha256 with
            | Some b -> Raw (302, headers (Option.value b.mimetype ~default:"application/octet-stream") [ ("location", b.media_url) ], "redirecting")
            | None -> raise (Blossom_error (404, "not found")))
        | None -> raise (Blossom_error (404, "not found")))
    | "HEAD" when r.path = "/upload" || r.path = "/media" ->
        let h = match Option.bind (req_header r "x-sha-256") Hex_util.decode_opt with Some h -> h | None -> raise (Blossom_error (401, "X-SHA-256 request header is missing")) in
        ignore (check_action r "upload" ~x_tag_hash:(Some h));
        text 200 "ok"
    | "HEAD" -> (
        match Option.bind (sha_of_target r.path) (find_upload ctx) with
        | Some b -> Raw (200, headers (Option.value b.mimetype ~default:"application/octet-stream") [ ("content-length", Int64.to_string (Option.value b.size ~default:0L)) ], "")
        | None -> raise (Blossom_error (404, "not found")))
    | "DELETE" -> (
        let b = match Option.bind (sha_of_target r.path) (find_upload ctx) with Some b -> b | None -> raise (Blossom_error (500, "unspecified error")) in
        let e = check_action r "delete" ~x_tag_hash:(Some b.sha256) in
        if b.pubkey = e.Nostr.pubkey then begin
          Moderation_http.purge_media ctx ~pubkey:(Some e.pubkey) ~surl:b.media_url ~reason:(Some "delete from blossom") ~initiator_pubkey:(`String (Hex_util.encode e.pubkey)) ~block_all_uploads:false ~clear_cache:false;
          text 200 "ok"
        end
        else raise (Blossom_error (404, "not found")))
    | "PUT" -> raise (Blossom_error (500, "uploads not available"))
    | _ -> raise (Blossom_error (404, "not found"))
  with
  | Blossom_error (status, message) -> text status ~extra:[ ("x-reason", message) ] message
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> text 500 ~extra:[ ("x-reason", "unspecified error") ] "error"

let service ~(cfg : Config.t) ~clock : Http_server.service =
  let ctx = Internal_http.ctx_of cfg clock in
  let h = handler ctx in
  let routes = List.concat_map (fun m -> [ { meth = m; pattern = []; handler = h }; { meth = m; pattern = [ Rest "path" ]; handler = h } ]) [ `GET; `PUT; `DELETE; `POST ] in
  { (default_service "blossom" routes) with cors = true; max_body = 256 * 1024 * 1024 }
