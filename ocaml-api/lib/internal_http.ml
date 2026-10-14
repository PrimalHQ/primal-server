(* The internal HTTP port, InternalServices (primal-server/internal_services.jl) route for route:
   /collect_metadata, /.well-known/nostr.json, /media-upload, /media-cache, /link-preview,
   /url-shortening, /url-lookup/*, /spam, /api, /api/suggestions(_2), and the catch-all
   preview_handler that serves the web app's index.html with OpenGraph tags for the path.
   Handler errors are a plain 500 "error", as in Julia; the HTML is rewritten textually (Julia went
   through libxml2, which added an XML prolog and self-closed every tag) — the OpenGraph and
   twitter meta elements come out identical. *)

open Http_server

type ctx = Handlers.ctx

let ctx_of (cfg : Config.t) clock : ctx = { Handlers.cfg; clock; conn_id = 0; subid = "http" }
let guard (f : unit -> resp) : resp =
  try f ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | e ->
      Printf.printf "%s [http] handler error: %s\n%!" (Procinfo.timestamp ()) (Printexc.to_string e);
      Text (500, "error")

let api_headers = [ ("content-type", "application/json") ]
let no_store = ("cache-control", "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0")
let cache_headers = [ ("cache-control", "must-revalidate, proxy-revalidate, max-age=1") ]
let json_resp ?(status = 200) (body : string) = Raw (status, api_headers, body)

(* URIs.escapeuri: everything but the unreserved set is percent-encoded *)
let escape_uri (s : string) : string =
  let b = Buffer.create (String.length s * 3) in
  String.iter
    (fun c ->
      if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-' || c = '_' || c = '.' || c = '~' then Buffer.add_char b c
      else Buffer.add_string b (Printf.sprintf "%%%02X" (Char.code c)))
    s;
  Buffer.contents b

let host_of (r : req) : string = Option.value (req_header r "host") ~default:""

(* {1 Metadata helpers} *)

let allowed_media_hosts =
  [ "media.primal.net"; "m.primal.net"; "blossom.primal.net"; "primaldata.s3.us-east-005.backblazeb2.com"; "primaldata.fsn1.your-objectstorage.com"; "r2.primal.net" ]

let url_host (u : string) : string = match Http.parse_url u with Some p -> p.Http.host | None -> ""

(* InternalServices.re_url *)
let re_url = Str.regexp {|https?://\(www\.\)?[-a-zA-Z0-9@:%._+~#=]+\.[a-zA-Z0-9()]+\b[-a-zA-Z0-9()@:%_+.~#?&/=]*|}
let strip_urls (s : string) : string = Str.global_replace re_url "" s

(* mdtitle: the first non-empty of displayName, display_name, name, username *)
let mdtitle (c : Yojson.Safe.t) : string =
  match c with
  | `Assoc f -> (
      match List.find_map (fun k -> match List.assoc_opt k f with Some (`String s) when String.trim s <> "" -> Some (String.trim s) | _ -> None) [ "displayName"; "display_name"; "name"; "username" ] with
      | Some t -> t
      | None -> "")
  | _ -> ""

let metadata_content (c : Db.cache Db.conn) (pubkey : string) : Yojson.Safe.t option =
  match Queries.metadata_event_json c ~pubkey with
  | None -> None
  | Some j -> (
      match Yojson.Safe.from_string j with
      | `Assoc f -> ( match List.assoc_opt "content" f with Some (`String s) -> ( try Some (Yojson.Safe.from_string s) with _ -> None) | _ -> None)
      | _ -> None
      | exception _ -> None)

type md = { title : string; description : string; image : string; url : string option }

(* InternalServices.mdpubkey *)
let mdpubkey (ctx : ctx) (c : Db.cache Db.conn) (pubkey : string) : md =
  let blocked = Handlers.with_membership ctx (fun m -> Queries_mem.filterlist_pubkey_blocked m ~pubkey) in
  if blocked then { title = ""; description = ""; image = ""; url = None }
  else begin
    let title, description, image, url =
      match metadata_content c pubkey with
      | Some (`Assoc f as content) ->
          let str k = match List.assoc_opt k f with Some (`String s) -> Some s | _ -> None in
          let url =
            match str "nip05" with
            | Some a when String.ends_with ~suffix:"@primal.net" (String.trim a) -> Some ("https://primal.net/" ^ List.hd (String.split_on_char '@' (String.trim a)))
            | _ -> None
          in
          (mdtitle content, (match str "about" with Some a -> strip_urls a | None -> ""), Option.value (str "picture") ~default:"", url)
      | _ -> ("", "", "", None)
    in
    let image = match Queries.media_url_smallest c ~url:image with Some u -> u | None -> image in
    { title; description; image; url }
  end

(* DB.re_hashref + re_mention: #[n] p-tag references and nostr: mentions become names *)
let re_hashref = Str.regexp {|#\[\([0-9]*\)\]|}
let re_mention = Str.regexp {|\b\(nostr:\)?\(\(note\|npub\|naddr\|nevent\|nprofile\)1[A-Za-z0-9_]+\)\b|}

let content_refs_resolved (c : Db.cache Db.conn) (e : Yojson.Safe.t) : string =
  let fields = match e with `Assoc f -> f | _ -> [] in
  let content = match List.assoc_opt "content" fields with Some (`String s) -> s | _ -> "" in
  let tags = match List.assoc_opt "tags" fields with Some (`List l) -> l | _ -> [] in
  let name_of_pubkey pk = match metadata_content c pk with Some md -> Some (mdtitle md) | None -> None in
  let s =
    Str.global_substitute re_hashref
      (fun m ->
        match int_of_string_opt (Str.matched_group 1 m) with
        | Some i when i >= 0 && i < List.length tags -> (
            match List.nth tags i with
            | `List (`String "p" :: `String h :: _) -> ( match Option.bind (Hex_util.decode_opt h) name_of_pubkey with Some n -> "@" ^ n | None -> "")
            | _ -> "")
        | _ -> "")
      content
  in
  Str.global_substitute re_mention
    (fun m ->
      let whole = Str.matched_string m in
      let r = Str.matched_group 2 m in
      match Bech32.nip19_decode r with
      | Some (Bech32.Npub pk) | Some (Bech32.Nprofile pk) -> ( match name_of_pubkey pk with Some n -> "@" ^ n | None -> whole)
      | Some (Bech32.Note eid) | Some (Bech32.Nevent eid) -> (
          match Queries.events_by_ids c ~event_ids_json:(Handlers.hex_list_json [ Hex_util.encode eid ]) with
          | (_, j) :: _ -> (
              match Yojson.Safe.from_string j with
              | `Assoc f -> (
                  match List.assoc_opt "pubkey" f with
                  | Some (`String pk) -> ( match Option.bind (Hex_util.decode_opt pk) name_of_pubkey with Some n -> "[nostr note by " ^ n ^ "]" | None -> "[nostr note]")
                  | _ -> "[nostr note]")
              | _ -> "[nostr note]"
              | exception _ -> "[nostr note]")
          | [] -> "[nostr note]")
      | _ -> whole)
    s

(* {1 get_meta_elements} *)

type image = Cached of string (* wrapped in /media-cache *) | Direct of string
type mels = { m_title : string; m_description : string; m_image : image; m_url : string; twitter_card : string; twitter_image : string }

let event_json (c : Db.cache Db.conn) (eid_hex : string) : Yojson.Safe.t option =
  match Queries.events_by_ids c ~event_ids_json:(Handlers.hex_list_json [ eid_hex ]) with (_, j) :: _ -> ( try Some (Yojson.Safe.from_string j) with _ -> None) | [] -> None

let tag_value (e : Yojson.Safe.t) (name : string) : string option =
  match e with
  | `Assoc f -> (
      match List.assoc_opt "tags" f with
      | Some (`List tags) -> List.fold_left (fun acc t -> match t with `List (`String n :: `String v :: _) when n = name -> Some v | _ -> acc) None tags
      | _ -> None)
  | _ -> None

let event_pubkey (e : Yojson.Safe.t) : string option = match e with `Assoc f -> ( match List.assoc_opt "pubkey" f with Some (`String pk) -> Hex_util.decode_opt pk | _ -> None) | _ -> None

(* an article / live-event preview from the event's title/summary/image tags *)
let article_mels (ctx : ctx) (c : Db.cache Db.conn) ~host ~(naddr_path : string) ~pubkey (e : Yojson.Safe.t) : mels =
  let title = Option.value (tag_value e "title") ~default:"" and description = Option.value (tag_value e "summary") ~default:"" in
  let image =
    match tag_value e "image" with
    | Some img -> ( match Queries.media_url_medium c ~url:img with Some u -> u | None -> img)
    | None -> ""
  in
  let image = if image = "" then (mdpubkey ctx c pubkey).image else image in
  { m_title = title; m_description = description; m_image = Cached image; m_url = "https://" ^ host ^ "/e/" ^ naddr_path; twitter_card = "summary_large_image"; twitter_image = image }

let decode_pubkey_arg (s : string) : string option =
  if String.starts_with ~prefix:"npub" s || String.starts_with ~prefix:"nprofile" s then
    match Bech32.nip19_decode s with Some (Bech32.Npub pk) | Some (Bech32.Nprofile pk) -> Some pk | _ -> None
  else if String.length s = 64 then Hex_util.decode_opt s
  else None

let static_mels ~host ~title ~description ~image ~url ~twitter_image = { m_title = title; m_description = description; m_image = Direct image; m_url = url; twitter_card = "summary_large_image"; twitter_image } |> fun m -> ignore host; m

let get_meta_elements (ctx : ctx) ~(host : string) ~(path : string) ~(target : string) : mels option =
  let re s = Str.regexp s in
  let matches r s = Str.string_match r s 0 in
  Handlers.with_cache ctx (fun c ->
      let mdpubkey_ pk =
        let md = mdpubkey ctx c pk in
        Some { m_title = md.title; m_description = md.description; m_image = Cached md.image; m_url = (match md.url with Some u -> u | None -> "https://" ^ host ^ target); twitter_card = "summary"; twitter_image = md.image }
      in
      let name_pubkey name = match Handlers.with_membership ctx (fun m -> Queries_mem.verified_pubkeys_by_name m ~name) with h :: _ -> Hex_util.decode_opt h | [] -> None in
      if host = "primal.net" || host = "dev.primal.net" then begin
        if matches (re {|^/\(profile\|p\)/\(.*\)|}) path then begin
          match decode_pubkey_arg (Str.matched_group 2 path) with Some pk -> mdpubkey_ pk | None -> raise Not_found
        end
        else if matches (re {|^/\(thread\|e\|a\)/\(.*\)|}) path then begin
          let eidstr = Str.matched_group 2 path in
          let empty = { m_title = ""; m_description = ""; m_image = Cached ""; m_url = ""; twitter_card = "summary"; twitter_image = "" } in
          let note_preview eid =
            match event_json c (Hex_util.encode eid) with
            | None -> empty
            | Some e ->
                let description = strip_urls (content_refs_resolved c e) in
                let author = Option.value (event_pubkey e) ~default:"" in
                let md = mdpubkey ctx c author in
                let image =
                  match Queries.event_media_url_one c ~event_id:eid with
                  | None -> md.image
                  | Some murl -> (
                      match Queries.video_thumbnail_one c ~video_url:murl with
                      | Some t -> t
                      | None -> ( match Queries.media_url_largest_still c ~url:murl with Some u -> u | None -> murl))
                in
                { m_title = md.title; m_description = description; m_image = Cached image; m_url = "https://" ^ host ^ "/e/" ^ eidstr; twitter_card = "summary_large_image"; twitter_image = image }
          in
          match Bech32.nip19_decode eidstr with
          | Some (Bech32.Nevent eid) | Some (Bech32.Note eid) -> Some (note_preview eid)
          | Some (Bech32.Naddr { kind; author; identifier }) -> (
              match Queries.parametrized_event_id_one c ~pubkey:author ~kind ~identifier with
              | Some eh -> ( match event_json c eh with Some e -> Some (article_mels ctx c ~host ~naddr_path:eidstr ~pubkey:author e) | None -> Some empty)
              | None -> Some empty)
          | _ -> ( match Hex_util.decode_opt eidstr with Some eid when String.length eid = 32 -> Some (note_preview eid) | _ -> Some empty)
        end
        else
          let article =
            if matches (re {|^/\([^/]*\)/\([^?]*\)|}) path then begin
              let name = Str.matched_group 1 path and identifier = percent_decode (Str.matched_group 2 path) in
              match name_pubkey name with
              | None -> None
              | Some pubkey -> (
                  match Queries.parametrized_event_id_one c ~pubkey ~kind:30023 ~identifier with
                  | Some eh -> (
                      match event_json c eh with
                      | Some e -> Some (article_mels ctx c ~host ~naddr_path:(Bech32.encode_naddr ~kind:30023 ~author:pubkey ~identifier) ~pubkey e)
                      | None -> None)
                  | None -> None)
            end
            else None
          in
          match article with
          | Some m -> Some m
          | None -> (
              let live =
                let pk_id =
                  if matches (re {|^/p/\([^/]*\)/live/\([^?]*\)|}) path then
                    let pk = Str.matched_group 1 path and identifier = Str.matched_group 2 path in
                    Option.map (fun p -> (p, identifier)) (decode_pubkey_arg pk)
                  else if matches (re {|^/\([^/]*\)/live/\([^?]*\)|}) path then
                    let name = Str.matched_group 1 path and identifier = percent_decode (Str.matched_group 2 path) in
                    Option.map (fun p -> (p, identifier)) (name_pubkey name)
                  else None
                in
                match pk_id with
                | None -> None
                | Some (pubkey, identifier) -> (
                    match Queries.live_event_id c ~pubkey ~identifier with
                    | Some eh -> ( match event_json c eh with Some e -> Some (article_mels ctx c ~host ~naddr_path:(Bech32.encode_naddr ~kind:30311 ~author:pubkey ~identifier) ~pubkey e) | None -> None)
                    | None -> None)
              in
              match live with
              | Some m -> Some m
              | None ->
                  if matches (re {|^/downloads?|}) path then
                    Some (static_mels ~host ~title:"Download Primal apps and source code" ~description:"" ~image:("https://" ^ host ^ "/public/primal-link-preview.jpg") ~url:("https://" ^ host ^ "/downloads") ~twitter_image:("https://" ^ host ^ "/public/primal-link-preview.jpg?a=444"))
                  else if matches (re {|^/legends|}) path then
                    Some (static_mels ~host ~title:"Primal Legends" ~description:"Recognizing users who made a contribution to Nostr and Primal" ~image:("https://" ^ host ^ "/public/legends-link-preview.png") ~url:("https://" ^ host ^ "/legends") ~twitter_image:("https://" ^ host ^ "/public/legends-link-preview.png?a=444"))
                  else if path = "/myarticles" then
                    Some (static_mels ~host ~title:"Primal Article Editor" ~description:"Create long form articles for Nostr" ~image:("https://" ^ host ^ "/public/article-editor-link-preview.png") ~url:("https://" ^ host ^ "/myarticles") ~twitter_image:("https://" ^ host ^ "/public/article-editor-link-preview.png?a=444"))
                  else if path = "/" then
                    Some (static_mels ~host ~title:"Primal" ~description:"Live Free" ~image:("https://" ^ host ^ "/public/primal-link-preview.jpg") ~url:("https://" ^ host ^ "/") ~twitter_image:("https://" ^ host ^ "/images/twitter-hero.jpg"))
                  else if path = "/landing" then
                    Some (static_mels ~host ~title:"Primal" ~description:"Live Free" ~image:("https://" ^ host ^ "/public/primal-link-preview.jpg") ~url:"https://primal.net/" ~twitter_image:"https://primal.net/images/twitter-hero.jpg")
                  else if matches (re {|^/\(.*\)|}) path then begin
                    match name_pubkey (Str.matched_group 1 path) with Some pk -> mdpubkey_ pk | None -> None
                  end
                  else None)
      end
      else if host = "studio.primal.net" || host = "studio-dev.primal.net" then
        Some (static_mels ~host ~title:"Primal Studio" ~description:"Empowering Nostr Content Creators" ~image:("https://" ^ host ^ "/public/link-preview_primal-studio.jpg") ~url:("https://" ^ host ^ "/") ~twitter_image:("https://" ^ host ^ "/public/link-preview_primal-studio.jpg"))
      else None)

(* {1 The index.html rewrite} *)

let attr_escape (s : string) : string =
  let b = Buffer.create (String.length s + 16) in
  String.iter (function '&' -> Buffer.add_string b "&amp;" | '<' -> Buffer.add_string b "&lt;" | '>' -> Buffer.add_string b "&gt;" | '"' -> Buffer.add_string b "&quot;" | '\n' -> Buffer.add_string b "&#10;" | '\r' -> Buffer.add_string b "&#13;" | '\t' -> Buffer.add_string b "&#9;" | c -> Buffer.add_char b c) s;
  Buffer.contents b

let text_escape (s : string) : string =
  let b = Buffer.create (String.length s + 16) in
  String.iter (function '&' -> Buffer.add_string b "&amp;" | '<' -> Buffer.add_string b "&lt;" | '>' -> Buffer.add_string b "&gt;" | c -> Buffer.add_char b c) s;
  Buffer.contents b

let re_og_meta = Str.regexp "[ \t]*<meta[^>]*property=\"og:[^\"]*\"[^>]*>[ \t]*\r?\n?"
let re_title = Str.regexp {|<title>[^<]*</title>|}
let re_head_end = Str.regexp_case_fold {|</head>|}

(* preview_handler's document: the file's own og: metas removed, ours appended to <head>, the title replaced *)
let og_page (index_html : string) (m : mels) : string =
  let image_value = match m.m_image with Direct v -> v | Cached v -> if v = "" then "" else "https://primal.net/media-cache?u=" ^ escape_uri v in
  let meta attr k v = let v = String.trim v in if v = "" then Printf.sprintf {|<meta %s="%s"/>|} attr k else Printf.sprintf {|<meta %s="%s" content="%s"/>|} attr k (attr_escape v) in
  let metas =
    String.concat ""
      [ meta "property" "og:title" m.m_title; meta "property" "og:description" m.m_description; meta "property" "og:image" image_value; meta "property" "og:url" m.m_url;
        {|<meta name="og:type" content="website"/>|}; meta "name" "twitter:card" m.twitter_card; meta "name" "twitter:image" m.twitter_image ]
  in
  let doc = Str.global_replace re_og_meta "" index_html in
  let doc = Str.replace_first re_title ("<title>" ^ text_escape (String.trim m.m_title) ^ "</title>") doc in
  match Str.search_forward re_head_end doc 0 with
  | i -> String.sub doc 0 i ^ metas ^ String.sub doc i (String.length doc - i)
  | exception Not_found -> doc ^ metas

(* {1 Link preview} *)

(* Media.fetch_resource_metadata: each download proxy in random order until one yields a title *)
let fetch_resource_metadata (ctx : ctx) (url : string) : Link_preview.t =
  match !Handlers.net_ref with
  | None -> Link_preview.empty
  | Some net ->
      let proxies = Array.of_list ctx.cfg.download_proxies in
      for i = Array.length proxies - 1 downto 1 do
        let j = Random.int (i + 1) in
        let t = proxies.(i) in
        proxies.(i) <- proxies.(j);
        proxies.(j) <- t
      done;
      let try_one p =
        let proxy =
          if p = "null" then None
          else
            let s = List.fold_left (fun s pre -> if String.starts_with ~prefix:pre s then String.sub s (String.length pre) (String.length s - String.length pre) else s) p [ "socks5h://"; "socks5://" ] in
            match String.rindex_opt s ':' with Some i -> ( match int_of_string_opt (String.sub s (i + 1) (String.length s - i - 1)) with Some port -> Some (String.sub s 0 i, port) | None -> None) | None -> None
        in
        let get u =
          match Http.request ~net ~clock:ctx.clock ?proxy ~timeout:10.0 ~headers:[ ("User-Agent", Link_preview.user_agent) ] u with
          | Some r when r.Http.status >= 200 && r.status < 300 -> Some r.body
          | _ -> None
        in
        let page = Option.map (Link_preview.parse ~url) (get url) in
        match page with
        | Some pv when pv.Link_preview.title <> "" -> page
        | _ -> (
            (* no title (a bot check page, or no page): the site's oEmbed through the same proxy *)
            match Option.bind (Option.bind (Link_preview.oembed_url url) get) Link_preview.parse_oembed with Some o -> Some o | None -> page)
      in
      let rec go = function
        | [] -> Link_preview.empty
        | p :: rest -> ( match try_one p with Some pv when pv.Link_preview.title <> "" -> pv | _ -> go rest)
      in
      go (Array.to_list proxies)

(* {1 URL shortening} *)

let short_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

let short_path_of_idx (idx : int) : string =
  let n = String.length short_chars in
  let rec go i acc = if i > 0 then go (i / n) (String.make 1 short_chars.[i mod n] :: acc) else acc in
  String.concat "" (go (1_000_000 + idx) [])

let ext_of_url (url : string) : string =
  let path = match Http.parse_url url with Some u -> ( match String.index_opt u.Http.path '?' with Some i -> String.sub u.path 0 i | None -> u.path) | None -> url in
  let base = match String.rindex_opt path '/' with Some i -> String.sub path (i + 1) (String.length path - i - 1) | None -> path in
  match String.rindex_opt base '.' with Some i -> String.lowercase_ascii (String.sub base i (String.length base - i)) | None -> ""

let url_shortening (ctx : ctx) (url : string) : string =
  let spath, ext =
    Handlers.with_membership ctx (fun m ->
        match Queries_mem.short_url_by_url m ~url with
        | Some (p, e) -> (p, e)
        | None ->
            let idx = Queries_mem.short_url_next_idx m in
            let spath = short_path_of_idx (Int64.to_int idx) and ext = ext_of_url url in
            Queries_mem.short_url_insert m ~idx ~url ~path:spath ~ext;
            (spath, ext))
  in
  ctx.cfg.url_shortening_root_url ^ "/" ^ spath ^ ext

(* {1 collect_metadata and /api} *)

let collect_metadata (ctx : ctx) (hexes : string list) : Yojson.Safe.t =
  let hexes = List.filter (fun h -> String.length h = 64 && Hex_util.decode_opt h <> None) hexes |> List.sort_uniq compare in
  if hexes = [] then `Assoc []
  else
    Handlers.with_cache ctx (fun c -> `Assoc (List.map (fun (k, e) -> (k, Yojson.Safe.from_string e)) (Queries.metadata_events_json c ~pubkeys_json:(Handlers.hex_list_json hexes))))

(* a funcall /api does not answer (unknown, an extension's, or Not_handled): 500 error *)
let not_handled (ctx : ctx) ~(peer : string) ~(fc : string) : resp =
  if ctx.cfg.log_not_handled then Printf.printf "%s [http] not handled: %s from %s\n%!" (Procinfo.timestamp ()) fc peer;
  Text (500, "error")

let api (ctx : ctx) (r : req) : resp =
  guard (fun () ->
      match Yojson.Safe.from_string r.body with
      | `List (`String fc :: rest) -> (
          let kwargs = match rest with (`Assoc _ as kw) :: _ -> kw | _ -> `Assoc [] in
          let not_handled () = not_handled ctx ~peer:r.peer ~fc in
          match Funcall.of_string fc with
          | Funcall.Other _ -> not_handled ()
          | Funcall.Server_name -> (
              (* Julia's App.server_name answered {server, node} here; ws-connector's name is the WS answer *)
              match ctx.cfg.http_server_name with
              | Some (server, node) ->
                  json_resp (Yojson.Safe.to_string (`List [ `Assoc [ ("content", `String (Yojson.Safe.to_string (`Assoc [ ("server", `Int server); ("node", `Int node) ]))) ] ]))
              | None -> not_handled ())
          | f -> (
              match Funcall.dispatch ctx f kwargs with
              | Response.Handled res -> json_resp ("[" ^ String.concat "," res.messages ^ "]")
              | Response.Notice n -> json_resp (Yojson.Safe.to_string (`Assoc [ ("error", `String n) ]))
              | Response.Not_handled -> not_handled ()))
      | _ -> Text (500, "error"))

let suggestions (ctx : ctx) : resp =
  guard (fun () ->
      match Yojson.Safe.from_string (Files.read (Handlers.cm_file ctx "suggested-accounts.json")) with
      | `List groups ->
          let groups = List.filter_map (function `List [ `String group; `List members ] -> Some (group, List.filter_map (function `List [ `String pk; `String name ] -> Some (pk, name) | _ -> None) members) | _ -> None) groups in
          let pubkeys = List.concat_map (fun (_, ms) -> List.map fst ms) groups in
          let res =
            `Assoc
              [ ("metadata", collect_metadata ctx pubkeys);
                ("suggestions", `List (List.map (fun (group, ms) -> `Assoc [ ("group", `String group); ("members", `List (List.map (fun (pk, name) -> `Assoc [ ("name", `String name); ("pubkey", `String pk) ]) ms)) ]) groups)) ]
          in
          json_resp (Yojson.Safe.to_string res)
      | _ -> Text (500, "error"))

let suggestions_2 (ctx : ctx) : resp =
  guard (fun () ->
      match Yojson.Safe.from_string (Files.read (Handlers.cm_file ctx "suggested-accounts-v2.json")) with
      | `List groups ->
          let pubkeys = ref [] in
          let groups =
            List.map
              (function
                | `Assoc g ->
                    let people =
                      match List.assoc_opt "people" g with
                      | Some (`List people) ->
                          List.map
                            (function
                              | `Assoc u ->
                                  let pk = match List.assoc_opt "pubkey" u with Some (`String p) -> p | _ -> raise Not_found in
                                  let pk = if String.starts_with ~prefix:"npub" pk then (match Bech32.nip19_decode pk with Some (Bech32.Npub raw) -> Hex_util.encode raw | _ -> raise Not_found) else pk in
                                  if Hex_util.decode_opt pk = None || String.length pk <> 64 then raise Not_found;
                                  pubkeys := pk :: !pubkeys;
                                  `Assoc (List.map (fun (k, v) -> if k = "pubkey" then (k, `String pk) else (k, v)) u)
                              | v -> v)
                            people
                      | _ -> []
                    in
                    `Assoc (List.map (fun (k, v) -> if k = "people" then (k, `List people) else (k, v)) g)
                | v -> v)
              groups
          in
          json_resp (Yojson.Safe.to_string (`Assoc [ ("metadata", collect_metadata ctx (List.rev !pubkeys)); ("suggestions", `List groups) ]))
      | _ -> Text (500, "error"))

(* {1 The service} *)

let service ~(cfg : Config.t) ~clock : Http_server.service =
  let ctx = ctx_of cfg clock in
  let cm name = Handlers.cm_file ctx name in
  let static_json path = match Files.read_opt path with Some s -> Raw (200, ("content-type", "application/json") :: cache_headers, s) | None -> Text (500, "error") in
  let preview (r : req) : resp =
    guard (fun () ->
        let target = r.path ^ (match r.query with [] -> "" | q -> "?" ^ String.concat "&" (List.map (fun (k, v) -> k ^ "=" ^ v) q)) in
        match r.path with
        | "/.well-known/apple-app-site-association" -> static_json (cm "apple-app-site-association.json")
        | "/.well-known/assetlinks.json" -> static_json (cm "assetlinks.json")
        | "/.well-known/remote-signer-nip46-defaults.json" -> static_json (cm "remote-signer-nip46-defaults.json")
        | "/.well-known/remote-signer-nip46-permissions.json" -> static_json (cm "remote-signer-nip46-permissions.json")
        | _ -> (
            let host = host_of r in
            match List.assoc_opt host cfg.index_dirs with
            | None -> Text (404, "not found")
            | Some index_dir ->
                if String.starts_with ~prefix:"/imageCacheWorker.js" r.path then Raw (200, ("content-type", "text/javascript") :: cache_headers, Files.read (index_dir ^ "/imageCacheWorker.js"))
                else if String.starts_with ~prefix:"/manifest.json" r.path then Raw (200, ("content-type", "text/json") :: cache_headers, Files.read (index_dir ^ "/manifest.json"))
                else begin
                  let index_html = Files.read (index_dir ^ "/index.html") in
                  let doc = match (try get_meta_elements ctx ~host ~path:r.path ~target with _ -> None) with Some m -> og_page index_html m | None -> index_html in
                  Raw (200, ("content-type", "text/html") :: cache_headers, doc)
                end))
  in
  let routes =
    [
      { meth = `POST; pattern = [ Lit "collect_metadata" ]; handler = (fun r -> guard (fun () ->
            let res = try match Yojson.Safe.from_string r.body with `List l -> collect_metadata ctx (List.filter_map (function `String s -> Some s | _ -> None) l) | _ -> raise Not_found with e -> `List [ `String "ERROR"; `String (Printexc.to_string e) ] in
            Raw (200, [], Yojson.Safe.to_string res))) };
      { meth = `GET; pattern = [ Lit ".well-known"; Lit "nostr.json" ]; handler = (fun r -> guard (fun () ->
            let names = match r.query with ("name", name) :: _ -> ( match Handlers.with_membership ctx (fun m -> Queries_mem.verified_pubkeys_by_name m ~name) with pk :: _ -> `Assoc [ (name, `String pk) ] | [] -> `Assoc []) | _ -> `Assoc [] in
            json_resp (Jsonfmt.julia_pretty (`Assoc [ ("names", names) ])))) };
      { meth = `GET; pattern = [ Lit "media-upload" ]; handler = (fun r -> guard (fun () ->
            let url = match query_param r "u" with Some u -> u | None -> raise Not_found in
            if List.mem (url_host url) allowed_media_hosts then Raw (302, [ ("location", url); no_store ], "")
            else Raw (404, [ ("content-type", "text/plain"); ("cache-control", "max-age=20") ], "not found"))) };
      { meth = `GET; pattern = [ Lit "media-cache" ]; handler = (fun r -> guard (fun () ->
            (match query_param r "s" with None | Some "o" | Some "s" | Some "m" | Some "l" -> () | Some _ -> raise Not_found);
            (match query_param r "a" with None | Some "1" | Some "0" -> () | Some _ -> raise Not_found);
            let url = match query_param r "u" with Some u -> u | None -> raise Not_found in
            let known = Handlers.with_cache ctx (fun c -> Queries.media_known c ~url) in
            if (not known) && not (List.mem (url_host url) allowed_media_hosts) then Raw (404, [ ("content-type", "text/plain"); ("cache-control", "max-age=20") ], "not found")
            else Raw (302, [ ("location", url); no_store ], ""))) };
      { meth = `GET; pattern = [ Lit "link-preview" ]; handler = (fun r -> guard (fun () ->
            let url = match query_param r "u" with Some u -> u | None -> raise Not_found in
            (* an empty preview (no proxy gave a title) is not cached: nginx keeps serving the last
               good one *)
            let p = fetch_resource_metadata ctx url in
            if p.Link_preview.title = "" then Raw (200, no_store :: api_headers, Link_preview.to_json p) else json_resp (Link_preview.to_json p))) };
      { meth = `GET; pattern = [ Lit "url-shortening" ]; handler = (fun r -> guard (fun () ->
            let url = match query_param r "u" with Some u -> u | None -> raise Not_found in
            Raw (200, [ ("content-type", "application/text") ], url_shortening ctx url))) };
      { meth = `GET; pattern = [ Lit "url-lookup"; Rest "p" ]; handler = (fun r -> guard (fun () ->
            let last = match String.rindex_opt r.path '/' with Some i -> String.sub r.path (i + 1) (String.length r.path - i - 1) | None -> r.path in
            let spath = match String.rindex_opt last '.' with Some i -> String.sub last 0 i | None -> last in
            match Handlers.with_membership ctx (fun m -> Queries_mem.short_url_target m ~path:spath) with
            | None -> Raw (404, [ ("content-type", "text/plain; charset=utf-8") ], "unknown url")
            | Some url ->
                let file = match String.rindex_opt url '/' with Some i -> String.sub url (i + 1) (String.length url - i - 1) | None -> url in
                let h = match String.rindex_opt file '.' with Some i -> String.sub file 0 i | None -> file in
                let rurl =
                  match Handlers.with_cache ctx (fun c -> Queries.media_storage_url_by_hash c ~h) with
                  | Some url2 -> if url_host url2 = "media.primal.net" then "https://primal.b-cdn.net/media-upload?u=" ^ escape_uri url2 else url2
                  | None -> "https://primal.b-cdn.net/media-upload?u=" ^ escape_uri ("https://media.primal.net" ^ (match Http.parse_url url with Some u -> u.Http.path | None -> ""))
                in
                Raw (302, [ ("location", rurl) ], ""))) };
      { meth = `GET; pattern = [ Lit "spam" ]; handler = (fun _ -> guard (fun () -> json_resp (Jsonfmt.julia_pretty (Handlers.filterlist_dict ctx)))) };
      { meth = `POST; pattern = [ Lit "api" ]; handler = api ctx };
      { meth = `GET; pattern = [ Lit "api" ]; handler = api ctx };
      { meth = `GET; pattern = [ Lit "api"; Lit "suggestions" ]; handler = (fun _ -> suggestions ctx) };
      { meth = `POST; pattern = [ Lit "api"; Lit "suggestions" ]; handler = (fun _ -> suggestions ctx) };
      { meth = `GET; pattern = [ Lit "api"; Lit "suggestions_2" ]; handler = (fun _ -> suggestions_2 ctx) };
      { meth = `POST; pattern = [ Lit "api"; Lit "suggestions_2" ]; handler = (fun _ -> suggestions_2 ctx) };
      { meth = `GET; pattern = []; handler = preview };
      { meth = `GET; pattern = [ Rest "path" ]; handler = preview };
    ]
  in
  { (default_service "internal" (routes @ Extensions.routes `Internal)) with cors = true; max_body = 4 * 1024 * 1024 }
