(* The Blossom server (primal-blossom-server, Rust, blossom.primal.net on the media host): BUD-01/02/04/05
   with kind-24242 authorization. PUT /upload and /media (metadata stripped with exiftool/ffmpeg,
   recorded in media_metadata_stripping) and /mirror store the blob in every local storage, insert
   media_storage (cache DB) and media_uploads (membership DB) and schedule the import_upload_3
   processing node (the media role executes it); GET redirects to the storage URL, serving the
   bytes over an ssh fallback when the local file is missing; HEAD/LIST/DELETE as the Rust server,
   DELETE through a purge_media_ node it waits for. Node ids are the server's insertion-order JSON
   (serde_json preserve_order). The request log goes to the log DB when configured. *)

open Eio.Std
open Procgraph
module HS = Http_server
module T = Media_tools

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [blossom] %s\n%!" (Procinfo.timestamp ()) s) fmt

type config = {
  port : int;
  base_url : string; (* https://blossom.primal.net *)
  media_server_url : string; (* https://media.primal.net *)
  local_storages : (string * string) list; (* storage_provider name -> root dir *)
  media_serving_dir : string option; (* the docroot media_server_url serves from on this host *)
  ssh_fallback_host : string option;
  ssh_fallback_remote_base : string option;
  ssh_fallback_timeout_s : float;
  log_db : Postgres.conninfo option;
  proxy : (string * int) option; (* /mirror downloads *)
  sandboxing : bool; (* exiftool/ffmpeg under bwrap *)
  node_wait_timeout_s : float; (* DELETE waits this long for purge_media_ *)
}

exception Config_error of string

let config_of_json (j : Yojson.Safe.t) : config =
  let f k = match j with `Assoc l -> Option.value (List.assoc_opt k l) ~default:`Null | _ -> `Null in
  let rstr k = match f k with `String s -> s | _ -> raise (Config_error ("blossom: missing key " ^ k)) in
  let ostr k = match f k with `String s -> Some s | _ -> None in
  let ofloat k d = match f k with `Int i -> float_of_int i | `Float x -> x | _ -> d in
  { port = (match f "port" with `Int p -> p | _ -> raise (Config_error "blossom: missing key port"));
    base_url = rstr "base_url"; media_server_url = rstr "media_server_url";
    local_storages = (match f "local_storages" with `Assoc l -> List.map (fun (k, v) -> (k, match v with `String s -> s | _ -> raise (Config_error "blossom: local_storages values are paths"))) l | _ -> raise (Config_error "blossom: missing key local_storages"));
    media_serving_dir = ostr "media_serving_dir"; ssh_fallback_host = ostr "ssh_fallback_host"; ssh_fallback_remote_base = ostr "ssh_fallback_remote_base"; ssh_fallback_timeout_s = ofloat "ssh_fallback_timeout_s" 300.0;
    log_db = (match f "log_db" with `Assoc l -> Some { Postgres.host = (match List.assoc_opt "host" l with Some (`String s) -> s | _ -> raise (Config_error "blossom.log_db.host")); port = (match List.assoc_opt "port" l with Some (`Int p) -> p | _ -> 5432); user = (match List.assoc_opt "user" l with Some (`String s) -> s | _ -> raise (Config_error "blossom.log_db.user")); database = (match List.assoc_opt "database" l with Some (`String s) -> s | _ -> raise (Config_error "blossom.log_db.database")) } | _ -> None);
    proxy = (match f "proxy" with `String p -> Media_config.parse_proxy p | _ -> None);
    sandboxing = (match f "sandboxing" with `Bool b -> b | _ -> true);
    node_wait_timeout_s = ofloat "node_wait_timeout_s" 120.0 }

(* {1 tables} *)
let mimetype_ext =
  [ ("image/jpeg", ".jpg"); ("image/png", ".png"); ("image/gif", ".gif"); ("image/webp", ".webp"); ("image/svg+xml", ".svg"); ("video/mp4", ".mp4"); ("video/x-m4v", ".mp4"); ("video/mov", ".mov"); ("video/webp", ".webp"); ("video/webm", ".webm"); ("video/quicktime", ".mov"); ("video/x-matroska", ".mkv"); ("video/3gpp", ".3gp"); ("image/vnd.microsoft.icon", ".ico"); ("text/plain", ".txt"); ("application/json", ".json"); ("text/html", ".html"); ("text/javascript", ".js"); ("application/wasm", ".wasm"); ("audio/mpeg", ".mp3"); ("audio/wav", ".wav"); ("audio/flac", ".flac"); ("audio/ogg", ".ogg"); ("audio/aac", ".aac"); ("application/pdf", ".pdf") ]
let ext_of (mt : string) : string = Option.value (List.assoc_opt mt mimetype_ext) ~default:""
let rejected_mimetypes = [ "application/octet-stream" ]

exception Http_error of int * string
let fail status fmt = Printf.ksprintf (fun s -> raise (Http_error (status, s))) fmt

type state = { cfg : config; ctx : ctx; logp : Postgres.pool option; cache : (string, upload option) Hashtbl.t; cache_mu : Mutex.t; hostname : string; exiftool : string; ffmpeg : string }
and upload = { sha256 : string; media_url : string; mimetype : string; size : int64 }

(* a program's real path (the nix store file behind the profile symlink), for the sandbox *)
let resolve_program (name : string) : string =
  let dirs = String.split_on_char ':' (Option.value (Sys.getenv_opt "PATH") ~default:"") in
  match List.find_opt (fun d -> Sys.file_exists (Filename.concat d name)) dirs with
  | None -> name
  | Some d ->
      let p = Filename.concat d name in
      (try Unix.readlink p with _ -> p)

let sha256_raw (s : string) = Digestif.SHA256.(to_raw_string (digest_string s))
let hex = Hex_util.encode

(* /<sha256>[.ext] *)
let sha_of_path (path : string) : string =
  let p = if String.length path > 0 && path.[0] = '/' then String.sub path 1 (String.length path - 1) else path in
  let id = match String.index_opt p '.' with Some i -> String.sub p 0 i | None -> p in
  match Hex_util.decode_opt id with Some s -> s | None -> fail 400 "invalid sha256"

let header (r : HS.req) k = HS.req_header r k
let user_agent (r : HS.req) = Option.value (header r "user-agent") ~default:"unknown"

(* {1 authorization} (check_action) *)
let is_blob_blocked (st : state) (sha256 : string) : bool =
  q st.ctx "select 1 from media_uploads_media_block_csam mumb where mumb.sha256 = decode($1,'hex') limit 1" [ Some (hex sha256) ] <> []

let check_action (st : state) (r : HS.req) ~(action : string) ~(x_tag_hash : string option) : Nostr.t =
  let auth = match header r "authorization" with Some a -> a | None -> fail 400 "missing auth event" in
  let parts = List.filter (( <> ) "") (String.split_on_char ' ' (String.map (fun c -> if c = '\t' || c = '\n' || c = '\r' then ' ' else c) auth)) in
  (match parts with [ "Nostr"; _ ] -> () | [ _; _ ] -> fail 400 "invalid auth event" | _ -> fail 400 "missing auth event");
  let raw = match Base64.decode (List.nth parts 1) with Ok s -> s | Error _ -> fail 400 "invalid base64 for auth event" in
  let e = try Nostr.of_json (Yojson.Safe.from_string raw) with _ -> fail 400 "invalid auth event" in
  if not (Nostr.verify e) then fail 401 "auth event verification failed";
  if e.Nostr.kind <> 24242 then fail 401 "wrong kind in auth event";
  let now = Utils.current_time () in
  let action_ok = ref false and x_ok = ref (x_tag_hash = None) in
  List.iter
    (function
      | `String "expiration" :: `String v :: _ -> ( match int_of_string_opt v with Some exp -> if exp <= now then fail 401 "auth event expired" | None -> fail 400 "invalid expiration tag")
      | `String "t" :: `String v :: _ -> if v = action then action_ok := true
      | `String "x" :: `String v :: _ -> ( match x_tag_hash with Some h -> ( match Hex_util.decode_opt v with Some x -> if x = h then x_ok := true | None -> fail 400 "invalid x tag") | None -> ())
      | _ -> ())
    e.tags;
  if not !action_ok then fail 401 "invalid action in auth event";
  if not !x_ok then fail 401 "invalid x tag";
  if qm st.ctx "select 1 from filterlist where target = decode($1,'hex') and target_type = 'pubkey' and grp = 'csam' and blocked limit 1" [ Some (hex e.pubkey) ] <> [] then fail 401 "pubkey is blocked";
  (match x_tag_hash with Some h -> if is_blob_blocked st h then fail 401 "blob is blocked" | None -> ());
  e

(* {1 blobs} (find_blob with the 60 s cache) *)
let find_blob (st : state) (sha256 : string) : upload option =
  match Mutex.protect st.cache_mu (fun () -> Hashtbl.find_opt st.cache sha256) with
  | Some v -> v
  | None ->
      let blocked = match qm st.ctx "select bool_and(coalesce(fl.blocked, false))::text from media_uploads mu left join filterlist fl on fl.target = mu.pubkey and fl.target_type = 'pubkey' where mu.sha256 = decode($1,'hex')" [ Some (hex sha256) ] with [ Some "true" ] :: _ -> true | _ -> false in
      let v =
        if blocked then (log "error: uploaded blob %s is blocked" (hex sha256); None)
        else
          match q st.ctx "select encode(ms.sha256,'hex'), ms.media_url, ms.content_type, ms.size::text from media_storage ms join media_storage_priority msp on msp.storage_provider = ms.storage_provider where ms.sha256 = decode($1,'hex') and ms.media_block_id is null order by msp.priority limit 1" [ Some (hex sha256) ] with
          | [ Some s; Some media_url; Some mimetype; Some size ] :: _ -> Some { sha256 = Hex_util.decode_exn s; media_url; mimetype; size = Int64.of_string size }
          | [ None; _; _; _ ] :: _ -> log "error: sha256 is None"; None
          | _ -> None
      in
      Mutex.protect st.cache_mu (fun () -> Hashtbl.replace st.cache sha256 v);
      v

let cache_remove st sha256 = Mutex.protect st.cache_mu (fun () -> Hashtbl.remove st.cache sha256)

(* {1 ssh fallback} *)
let remote_relpath_for ~(media_url : string) ~(media_server_url : string) ~(sha256_hex : string) : (string, string) result =
  let n = String.length media_server_url in
  if String.length media_url < n || String.sub media_url 0 n <> media_server_url then Error "media_url not on media server"
  else
    let rel = String.sub media_url n (String.length media_url - n) in
    let starts p = String.length rel >= String.length p && String.sub rel 0 (String.length p) = p in
    if not (starts "/") then Error "relpath must start with /"
    else if not (starts "/uploads/" || starts "/uploads2/") then Error "relpath must be under /uploads"
    else if not (String.for_all (fun c -> (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c = '/' || c = '.' || c = '_' || c = '-') rel) then Error "relpath has disallowed characters"
    else if List.exists (fun comp -> comp = "" || comp = "." || comp = "..") (List.tl (String.split_on_char '/' rel)) then Error "relpath has invalid component"
    else
      let fname = List.hd (List.rev (String.split_on_char '/' rel)) in
      let stem = List.hd (String.split_on_char '.' fname) in
      if stem <> sha256_hex then Error "relpath filename does not match sha256" else Ok rel

let ssh_fallback_enabled (c : config) = c.ssh_fallback_host <> None && c.ssh_fallback_remote_base <> None

let exists_in_serving_dir (c : config) (rel : string) : bool =
  match c.media_serving_dir with Some d -> Sys.file_exists (d ^ rel) | None -> List.exists (fun (_, d) -> Sys.file_exists (d ^ rel)) c.local_storages

let ssh_fetch_and_verify (st : state) (rel : string) (sha256 : string) : (string, string) result =
  let c = st.cfg in
  match (c.ssh_fallback_host, c.ssh_fallback_remote_base) with
  | Some host, Some base -> (
      let remote = base ^ rel in
      match Proc.run ~proc_mgr:st.ctx.proc_mgr ~clock:st.ctx.clock ~timeout:c.ssh_fallback_timeout_s ~max_out:(10 * 1024 * 1024 * 1024) [ "ssh"; "-o"; "BatchMode=yes"; "-o"; "ConnectTimeout=10"; "-o"; "StrictHostKeyChecking=accept-new"; host; "cat"; remote ] with
      | r when r.status = 0 -> if sha256_raw r.stdout = sha256 then Ok r.stdout else Error "sha256 mismatch"
      | r -> Error (Printf.sprintf "ssh cat failed (status %d): %s" r.status (String.trim r.stderr))
      | exception exn -> Error (Printexc.to_string exn))
  | _ -> Error "ssh fallback not configured"

(* {1 tools} (execute_process, strip_metadata_2) *)
let execute_process (st : state) (program : string) (args : string list) (data : string) : (string, string) result =
  let argv = if st.cfg.sandboxing then [ "bwrap"; "--new-session"; "--die-with-parent"; "--unshare-net"; "--ro-bind"; "/nix"; "/nix"; "--bind"; st.ctx.cfg.tmp_dir; st.ctx.cfg.tmp_dir; program ] @ args else program :: args in
  match Proc.run ~proc_mgr:st.ctx.proc_mgr ~clock:st.ctx.clock ~timeout:600.0 ~stdin_data:data ~max_out:(10 * 1024 * 1024 * 1024) argv with
  | r when r.status = 0 -> Ok r.stdout
  | r -> Error (Printf.sprintf "Command failed with status: %d" r.status)
  | exception exn -> Error (Printexc.to_string exn)

let starts p s = String.length s >= String.length p && String.sub s 0 (String.length p) = p

let strip_metadata_2 (st : state) (input : string) : (string, string) result =
  let mt = T.parse_mimetype st.ctx input in
  if starts "audio/" mt then Ok input
  else
    match execute_process st st.exiftool [ "-ignoreMinorErrors"; "-all="; "-tagsfromfile"; "@"; "-Orientation"; "-" ] input with
    | Error e -> Error e
    | Ok data ->
        if starts "image/" mt || starts "application/pdf" mt || starts "text/" mt then Ok data
        else
          let data = if data = "" && starts "video/" mt then input else data in
          match List.assoc_opt mt mimetype_ext with
          | None -> Error "unsupported mime type"
          | Some ext ->
              let ext = String.concat "" (String.split_on_char '.' ext) in
              let f1 = Filename.concat st.ctx.cfg.tmp_dir (Nodes_moderation.uuid4 ()) and f2 = Filename.concat st.ctx.cfg.tmp_dir (Nodes_moderation.uuid4 ()) in
              Fun.protect ~finally:(fun () -> List.iter (fun f -> try Sys.remove f with _ -> ()) [ f1; f2 ]) (fun () ->
                  Out_channel.with_open_bin f1 (fun oc -> output_string oc data);
                  match execute_process st st.ffmpeg [ "-y"; "-i"; f1; "-map_metadata"; "-1"; "-c:v"; "copy"; "-c:a"; "copy"; "-movflags"; "+faststart"; "-f"; ext; f2 ] "" with
                  | Error e -> Error e
                  | Ok _ -> if Sys.file_exists f2 then Ok (In_channel.with_open_bin f2 In_channel.input_all) else Error ("file not found: " ^ f2))

(* {1 processing nodes} *)
let schedule_processing_node (st : state) ~(mod_ : string) ~(func : string) ~(args : Pgj.t) ~(kwargs : Pgj.t) : string =
  let id = Pgj.node_id_insertion ~mod_ ~func ~args ~kwargs in
  ignore (q st.ctx "insert into processing_nodes (id, created_at, updated_at, mod, func, args, kwargs, exception) values (decode($1,'hex'), now(), now(), $2, $3, $4::jsonb, $5::jsonb, false) on conflict (id) do update set started_at = null, finished_at = null" [ Some id; Some mod_; Some func; Some (Pgj.to_string args); Some (Pgj.to_string kwargs) ]);
  id

let schedule_media_processing (st : state) ~(pubkey_hex : string) ~(data : string) ~(sha256_before : string) ~(blossom_url : string) : string =
  let hh = Pgj.cache_write ~dir:st.ctx.cfg.binary_data_cache_dir data in
  schedule_processing_node st ~mod_:"PrimalServer.App" ~func:"import_upload_3"
    ~args:(Pgj.tuple [ `Assoc [ ("_ty", `String "CacheStorage"); ("_v", `Null) ]; Pgj.pubkey_id_hex pubkey_hex; Pgj.vec_u8_cached hh; Pgj.vec_u8_inline sha256_before; `String blossom_url ])
    ~kwargs:(`Assoc [])

let wait_processing_node (st : state) (id : string) : (Yojson.Safe.t, string) result =
  let deadline = Unix.gettimeofday () +. st.cfg.node_wait_timeout_s in
  let rec loop () =
    Eio.Time.sleep st.ctx.clock 0.2;
    if Unix.gettimeofday () > deadline then Error (Printf.sprintf "processing node %s timed out" id)
    else
      match q st.ctx "select result::text, exception::text from processing_nodes where id = decode($1,'hex') and finished_at is not null" [ Some id ] with
      | [ result; Some exc ] :: _ -> if exc = "true" || exc = "t" then Error (Printf.sprintf "processing node %s failed: %s" id (Option.value result ~default:"null")) else Ok (match result with Some s -> ( try Yojson.Safe.from_string s with _ -> `String s) | None -> `Null)
      | _ -> loop ()
  in
  loop ()

(* {1 import_blob} *)
let import_blob (st : state) (e : Nostr.t) (data : string) : Yojson.Safe.t * string =
  let c = st.cfg in
  let sha256 = sha256_raw data in
  let sha_hex = hex sha256 in
  log "import_blob: sha256: %s" sha_hex;
  if is_blob_blocked st sha256 then failwith "blob blocked";
  let size = String.length data in
  let content_type = T.parse_mimetype st.ctx data in
  let ext = ext_of content_type in
  let t = Utils.current_time () in
  let subdir = Printf.sprintf "/uploads2/%s/%s/%s" (String.sub sha_hex 0 1) (String.sub sha_hex 1 2) (String.sub sha_hex 3 2) in
  let pk_hex = hex e.Nostr.pubkey in
  let key = Printf.sprintf {|{"type":"member_upload","pubkey":"%s","sha256":"%s"}|} pk_hex sha_hex in
  let h = Pgj.sha256_hex key in
  List.iter
    (fun (host, hostdir) ->
      let dir = hostdir ^ subdir in
      Pushgateway.mkdir_p dir;
      let path = Printf.sprintf "%s/%s%s" dir sha_hex ext in
      if not (Sys.file_exists path) then begin
        let tmp = path ^ ".tmp" in
        Out_channel.with_open_bin tmp (fun oc -> output_string oc data);
        Sys.rename tmp path;
        log "%s -> %s: ok" tmp path
      end;
      let media_url = Printf.sprintf "%s%s/%s%s" c.media_server_url subdir sha_hex ext in
      ignore (q st.ctx "insert into media_storage (media_url, storage_provider, added_at, key, h, ext, content_type, size, sha256, media_block_id) values ($1, $2, $3::int8, $4, $5, $6, $7, $8::int8, decode($9,'hex'), null) on conflict (h, storage_provider) do update set media_url = $1, added_at = $3::int8, key = $4, ext = $6, content_type = $7, size = $8::int8, sha256 = decode($9,'hex'), media_block_id = null"
        [ Some media_url; Some host; Some (string_of_int t); Some key; Some h; Some ext; Some content_type; Some (string_of_int size); Some sha_hex ]))
    c.local_storages;
  ignore (qm st.ctx "insert into media_uploads (pubkey, type, key, created_at, path, size, mimetype, category, category_confidence, width, height, duration, sha256, moderation_category, media_block_id) values (decode($1,'hex'), 'member_upload', $2::jsonb, $3::int8, $4, $5::int8, $6, '', 1.0, 0, 0, 0.0, decode($7,'hex'), null, null)"
    [ Some pk_hex; Some key; Some (string_of_int t); Some (Printf.sprintf "%s/%s%s" subdir sha_hex ext); Some (string_of_int size); Some content_type; Some sha_hex ]);
  cache_remove st sha256;
  let blossom_url = Printf.sprintf "%s/%s%s" c.base_url sha_hex ext in
  (`Assoc [ ("url", `String blossom_url); ("sha256", `String sha_hex); ("size", `Int size); ("type", `String content_type); ("uploaded", `Int t) ], blossom_url)

(* {1 the request log} *)
let insert_log (st : state) (tag : string) (data : Yojson.Safe.t) : unit =
  match st.logp with
  | None -> ()
  | Some p -> ( try Postgres.use p (fun dbh -> ignore (Postgres.query dbh "insert into log (t, hostname, node, tag, data) values (now(), $1, $2, $3, $4::jsonb)" [ Some st.hostname; Some ""; Some tag; Some (Yojson.Safe.to_string data) ])) with exn -> log "insert_log failed: %s" (Printexc.to_string exn))

(* {1 handlers} *)
let ok_text ?(extra = []) body = HS.Raw (200, ("content-type", "text/plain") :: extra, body)
let ok_json (j : Yojson.Safe.t) = HS.Raw (200, [ ("content-type", "application/json") ], Yojson.Safe.to_string j)

let welcome (r : HS.req) = log "GET / | %s" (user_agent r); ok_text "Welcome to Primal Blossom server. Implemented: BUD-01, BUD-02, BUD-04, BUD-05"

let head_handler (st : state) (r : HS.req) (path : string) : HS.resp =
  log "HEAD %s | %s" path (user_agent r);
  if path = "upload" || path = "media" then begin
    let sha256 = match header r "x-sha-256" with Some v -> ( match Hex_util.decode_opt v with Some s -> s | None -> fail 401 "Invalid X-SHA-256 header") | None -> fail 401 "X-SHA-256 request header is missing" in
    ignore (check_action st r ~action:"upload" ~x_tag_hash:(Some sha256));
    ok_text "ok"
  end
  else
    match find_blob st (sha_of_path path) with
    | Some u -> HS.Raw (200, [ ("content-type", u.mimetype); ("content-length", Int64.to_string u.size) ], "")
    | None -> fail 404 "not found"

let get_handler (st : state) (r : HS.req) (path : string) : HS.resp =
  log "GET %s | %s" path (user_agent r);
  let sha256 = sha_of_path path in
  match find_blob st sha256 with
  | None -> fail 404 "not found"
  | Some u ->
      let c = st.cfg in
      let served =
        if ssh_fallback_enabled c && starts c.media_server_url u.media_url then
          match remote_relpath_for ~media_url:u.media_url ~media_server_url:c.media_server_url ~sha256_hex:(hex sha256) with
          | Ok rel when not (exists_in_serving_dir c rel) -> (
              log "GET %s: local miss, fetching from ssh fallback (%s): %s%s" path (Option.value c.ssh_fallback_host ~default:"") (Option.value c.ssh_fallback_remote_base ~default:"") rel;
              match ssh_fetch_and_verify st rel sha256 with
              | Ok data -> log "GET %s: served %d bytes from ssh fallback" path (String.length data); Some (HS.Raw (200, [ ("content-type", u.mimetype) ], data))
              | Error e -> log "GET %s: ssh fallback failed: %s" path e; fail 404 "not found")
          | _ -> None
        else None
      in
      (match served with Some resp -> resp | None -> HS.Raw (302, [ ("location", u.media_url); ("content-type", u.mimetype) ], ""))

let list_handler (st : state) (r : HS.req) (path : string) : HS.resp =
  log "GET /list/%s | %s" path (user_agent r);
  let pk = match Hex_util.decode_opt path with Some p when String.length p = 32 -> p | _ -> ( match Bech32.nip19_decode path with Some (Bech32.Npub p) | Some (Bech32.Nprofile p) -> p | _ -> fail 400 "invalid pubkey") in
  let e = check_action st r ~action:"list" ~x_tag_hash:None in
  if e.Nostr.pubkey <> pk then fail 401 "invalid pubkey";
  let since = Option.value (Option.bind (HS.query_param r "since") int_of_string_opt) ~default:0 and until = Option.value (Option.bind (HS.query_param r "until") int_of_string_opt) ~default:(Utils.current_time ()) in
  let rows = qm st.ctx "select mimetype, created_at::text, path, size::text, encode(sha256,'hex') from media_uploads where pubkey = decode($1,'hex') and created_at >= $2::int8 and created_at <= $3::int8 and media_block_id is null" [ Some (hex pk); Some (string_of_int since); Some (string_of_int until) ] in
  ok_json
    (`List
      (List.map
         (function
           | [ Some mimetype; Some created_at; _; Some size; sha ] ->
               let sha_hex = match sha with Some s -> s | None -> fail 500 "invalid sha256" in
               `Assoc [ ("url", `String (Printf.sprintf "%s/%s%s" st.cfg.base_url sha_hex (ext_of mimetype))); ("sha256", `String sha_hex); ("size", `Intlit size); ("type", `String mimetype); ("uploaded", `Intlit created_at) ]
           | _ -> fail 500 "db error")
         rows))

let delete_handler (st : state) (r : HS.req) (path : string) : HS.resp =
  log "DELETE %s | %s" path (user_agent r);
  let sha256 = sha_of_path path in
  match find_blob st sha256 with
  | None -> fail 404 "not found"
  | Some b ->
      let e = check_action st r ~action:"delete" ~x_tag_hash:(Some b.sha256) in
      let pk_hex = hex e.Nostr.pubkey in
      log "DELETE pubkey: %s" pk_hex;
      if qm st.ctx "select 1 from media_uploads where sha256 = decode($1,'hex') and pubkey = decode($2,'hex') and media_block_id is null limit 1" [ Some (hex sha256); Some pk_hex ] = [] then fail 404 "not found";
      let blossom_url = Printf.sprintf "%s/%s" st.cfg.base_url path in
      let nid =
        try schedule_processing_node st ~mod_:"PrimalServer.InternalServices" ~func:"purge_media_" ~args:(Pgj.tuple [ Pgj.pubkey_id_hex pk_hex; `String blossom_url ]) ~kwargs:(`Assoc [ ("extra", Pgj.namedtuple [ ("initiator_pubkey", Pgj.pubkey_id_hex pk_hex) ]); ("reason", `String ("delete from " ^ st.cfg.base_url)) ])
        with exn -> log "purge_media_ failed: %s" (Printexc.to_string exn); fail 500 "purge_media_ failed"
      in
      (match wait_processing_node st nid with Ok _ -> () | Error m -> log "%s" m; fail 500 "wait_processing_node failed");
      ok_text "ok"

let put_handler_ (st : state) (r : HS.req) (path : string) (data : string) : HS.resp * Nostr.t =
  log "PUT %s: got %d bytes | %s" path (String.length data) (user_agent r);
  let c = st.cfg in
  if path = "mirror" then begin
    let req = try Yojson.Safe.from_string data with _ -> fail 400 "invalid json" in
    let url = match req with `Assoc l -> ( match List.assoc_opt "url" l with Some (`String u) -> u | Some _ -> fail 400 "invalid url" | None -> fail 400 "missing url") | _ -> fail 400 "missing url" in
    let u = match Http.parse_url url with Some u -> u | None -> fail 400 "invalid url" in
    let sha256 = sha_of_path (match String.index_opt u.Http.path '?' with Some i -> String.sub u.path 0 i | None -> u.path) in
    let e = check_action st r ~action:"upload" ~x_tag_hash:(Some sha256) in
    log "PUT %s pubkey: %s" (hex sha256) (hex e.pubkey);
    let data = match Http.request ~net:st.ctx.net ~clock:st.ctx.clock ?proxy:c.proxy ~timeout:300.0 url with Some resp when resp.status >= 200 && resp.status < 300 -> resp.body | _ -> fail 400 "download error" in
    let resp, burl = try import_blob st e data with exn -> log "import_blob: %s" (Printexc.to_string exn); fail 500 "blob import error" in
    (try ignore (schedule_media_processing st ~pubkey_hex:(hex e.pubkey) ~data ~sha256_before:sha256 ~blossom_url:burl) with exn -> log "schedule: %s" (Printexc.to_string exn); fail 500 "scheduling media processing failed");
    (ok_json resp, e)
  end
  else if path = "upload" || path = "media" then begin
    let sha256 = sha256_raw data in
    let e = check_action st r ~action:"upload" ~x_tag_hash:(Some sha256) in
    log "PUT %s pubkey: %s" (hex sha256) (hex e.pubkey);
    let data =
      if path = "media" then begin
        let data2 = match strip_metadata_2 st data with Ok d -> d | Error m -> log "strip: %s" m; fail 500 "metadata stripping error" in
        ignore (q st.ctx "insert into media_metadata_stripping values (decode($1,'hex'), decode($2,'hex'), now(), $3::jsonb)" [ Some (hex sha256); Some (hex (sha256_raw data2)); Some (Yojson.Safe.to_string (`Assoc [ ("mod", `String "primal_blossom_server"); ("func", `String "put_handler"); ("pubkey", `String (hex e.pubkey)) ])) ]);
        data2
      end
      else data
    in
    let content_type = T.parse_mimetype st.ctx data in
    if List.mem content_type rejected_mimetypes then fail 415 "upload rejected: unsupported media type %s" content_type;
    let resp, burl = try import_blob st e data with exn -> log "import_blob: %s" (Printexc.to_string exn); fail 500 "blob import error" in
    (try ignore (schedule_media_processing st ~pubkey_hex:(hex e.pubkey) ~data ~sha256_before:sha256 ~blossom_url:burl) with exn -> log "schedule: %s" (Printexc.to_string exn); fail 500 "scheduling media processing failed");
    (ok_json resp, e)
  end
  else fail 404 "not found"

let put_handler (st : state) (r : HS.req) (path : string) : HS.resp =
  let request_headers = `Assoc (List.map (fun (k, v) -> (k, `String v)) r.HS.headers) in
  match put_handler_ st r path r.body with
  | resp, e ->
      let status, hdrs = match resp with HS.Raw (s, h, _) -> (s, h) | _ -> (200, []) in
      insert_log st "blossom.put_handler" (`Assoc [ ("request_headers", request_headers); ("path", `String path); ("size", `Int (String.length r.body)); ("auth_event", Nostr.to_json e); ("response_status", `Int status); ("response_headers", `Assoc (List.map (fun (k, v) -> (k, `String v)) hdrs)) ]);
      resp
  | exception Http_error (status, msg) ->
      insert_log st "blossom.put_handler" (`Assoc [ ("request_headers", request_headers); ("path", `String path); ("size", `Int (String.length r.body)); ("response_status", `Int status); ("error_msg", `String msg) ]);
      raise (Http_error (status, msg))

let service (st : state) : HS.service =
  let wrap f (r : HS.req) : HS.resp =
    try f r with
    | Http_error (status, msg) -> HS.Raw (status, [ ("content-type", "text/plain; charset=utf-8") ], msg)
    | Eio.Cancel.Cancelled e -> raise (Eio.Cancel.Cancelled e)
    | exn -> log "%s %s: %s" r.HS.raw_meth r.path (Printexc.to_string exn); HS.Raw (500, [ ("content-type", "text/plain; charset=utf-8") ], "error")
  in
  let path_of (r : HS.req) = HS.param r "path" in
  let on_blob (r : HS.req) = if r.raw_meth = "HEAD" then head_handler st r (path_of r) else get_handler st r (path_of r) in
  let on_list (r : HS.req) = if r.raw_meth = "HEAD" then ok_text "ok" else list_handler st r (path_of r) in
  let routes =
    [ { HS.meth = `GET; pattern = []; handler = wrap welcome };
      { meth = `GET; pattern = [ HS.Lit "list"; HS.Rest "path" ]; handler = wrap on_list };
      { meth = `GET; pattern = [ HS.Rest "path" ]; handler = wrap on_blob };
      { meth = `PUT; pattern = [ HS.Rest "path" ]; handler = wrap (fun r -> put_handler st r (path_of r)) };
      { meth = `DELETE; pattern = [ HS.Rest "path" ]; handler = wrap (fun r -> delete_handler st r (path_of r)) } ]
  in
  { (HS.default_service "blossom" routes) with cors = true; max_body = 10 * 1024 * 1024 * 1024 }

let run ~(cfg : config) ~(ctx : ctx) ~clock ~(stop : unit Promise.t) : unit =
  let st = { cfg; ctx; logp = Option.map (Postgres.make_pool ~size:2) cfg.log_db; cache = Hashtbl.create 1024; cache_mu = Mutex.create (); hostname = Unix.gethostname (); exiftool = resolve_program "exiftool"; ffmpeg = resolve_program "ffmpeg" } in
  log "blossom: port %d, base %s, media %s, storages %s, ssh fallback %s, sandbox %b, log db %s" cfg.port cfg.base_url cfg.media_server_url (String.concat "," (List.map fst cfg.local_storages)) (if ssh_fallback_enabled cfg then "on" else "off") cfg.sandboxing (if cfg.log_db <> None then "on" else "off");
  Switch.run @@ fun sw ->
  Fiber.fork_daemon ~sw (fun () ->
      (* the Rust server clears its blob cache every 60 s *)
      let rec loop () = Eio.Time.sleep clock 60.0; if not (Promise.is_resolved stop) then (let n = Mutex.protect st.cache_mu (fun () -> let n = Hashtbl.length st.cache in Hashtbl.reset st.cache; n) in log "cache size before clear: %d" n; loop ()) in
      loop ();
      `Stop_daemon);
  let sock = Listen.import ~sw (Listen.bind ~host:"0.0.0.0" ~port:cfg.port ()) in
  log "listening on http://0.0.0.0:%d" cfg.port;
  HS.serve_on ~sw ~clock ~stop (service st) sock
