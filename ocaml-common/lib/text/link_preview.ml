(* Link preview metadata from a page's <head> (replaces link-preview.py): the og:/twitter: title,
   description and image, the description meta, and a lone rel="icon" link as the image fallback.
   Used by the API's /link-preview and the media role's import_preview_pn. *)

let re_head_end = Str.regexp_case_fold {|</head>|}

let decode_entities (s : string) : string =
  let re = Str.regexp {|&\(amp\|lt\|gt\|quot\|apos\|#[0-9]+\|#x[0-9a-fA-F]+\);|} in
  Str.global_substitute re
    (fun m ->
      match Str.matched_group 1 m with
      | "amp" -> "&" | "lt" -> "<" | "gt" -> ">" | "quot" -> "\"" | "apos" -> "'"
      | e ->
          let code = if e.[1] = 'x' || e.[1] = 'X' then int_of_string ("0" ^ String.sub e 1 (String.length e - 1)) else int_of_string (String.sub e 1 (String.length e - 1)) in
          let b = Buffer.create 4 in
          Buffer.add_utf_8_uchar b (Uchar.of_int code);
          Buffer.contents b)
    s

(* the attributes of every <tag ...> in [html], lowercase names, entity-decoded values *)
let tag_attrs (html : string) (tag : string) : (string * string) list list =
  let re = Str.regexp_case_fold ("<" ^ tag ^ "[ \t\r\n][^>]*>") in
  let attr_re = Str.regexp "\\([a-zA-Z_:][-a-zA-Z0-9_:.]*\\)\\(\\([ \t\r\n]*=[ \t\r\n]*\\)\\(\"[^\"]*\"\\|'[^']*'\\|[^ \t\r\n\"'>]+\\)\\)?" in
  let rec collect pos acc =
    match Str.search_forward re html pos with
    | exception Not_found -> List.rev acc
    | i ->
        let whole = Str.matched_string html in
        let inner = String.sub whole (String.length tag + 1) (String.length whole - String.length tag - 2) in
        let rec attrs p acc =
          match Str.search_forward attr_re inner p with
          | exception Not_found -> List.rev acc
          | j ->
              (* read every group before decode_entities: Str's match state is global *)
              let mlen = String.length (Str.matched_string inner) in
              let name = String.lowercase_ascii (Str.matched_group 1 inner) in
              let raw = try Some (Str.matched_group 4 inner) with Not_found -> None in
              let value = match raw with Some v -> let v = if String.length v >= 2 && (v.[0] = '"' || v.[0] = '\'') then String.sub v 1 (String.length v - 2) else v in decode_entities v | None -> "" in
              attrs (j + max 1 mlen) ((name, value) :: acc)
        in
        collect (i + String.length whole) (attrs 0 [] :: acc)
  in
  collect 0 []

type t = { mimetype : string; title : string; image : string; description : string; icon_url : string }

let empty = { mimetype = ""; title = ""; image = ""; description = ""; icon_url = "" }

(* sites serve their OpenGraph tags to link-preview bots *)
let user_agent = "WhatsApp/2"

let parse ~(url : string) (html : string) : t =
  let head = match Str.search_forward re_head_end html 0 with i -> String.sub html 0 i | exception Not_found -> html in
  let title = ref "" and image = ref "" and description = ref "" in
  List.iter
    (fun a ->
      match (List.assoc_opt "rel" a, List.assoc_opt "href" a) with
      | Some rel, Some href when String.split_on_char ' ' (String.trim rel) |> List.filter (fun s -> s <> "") = [ "icon" ] -> image := Http.urljoin url href
      | _ -> ())
    (tag_attrs head "link");
  List.iter
    (fun a ->
      match (List.assoc_opt "property" a, List.assoc_opt "name" a, List.assoc_opt "content" a) with
      | Some p, _, Some c -> (
          match p with
          | "og:title" -> title := c
          | "og:image" -> image := Http.urljoin url c
          | "og:description" -> description := c
          | "twitter:title" -> title := c
          | "twitter:description" -> description := c
          | "twitter:image:src" -> image := Http.urljoin url c
          | _ -> ())
      | None, Some n, Some c -> (
          match n with
          | "description" -> description := c
          | "og:title" -> title := c
          | "og:image" -> image := Http.urljoin url c
          | "og:description" -> description := c
          | "twitter:title" -> title := c
          | "twitter:description" -> description := c
          | "twitter:image:src" -> image := Http.urljoin url c
          | _ -> ())
      | _ -> ())
    (tag_attrs head "meta");
  { mimetype = "text/html"; title = !title; image = !image; description = !description; icon_url = "" }

(* {1 oEmbed} YouTube answers some proxy exits with a "confirm you're not a bot" page that has no
   title; its oEmbed endpoint still answers there (title and thumbnail, no description) *)

let pct_encode (s : string) : string =
  let b = Buffer.create (String.length s * 3) in
  String.iter (fun c -> match c with 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~' -> Buffer.add_char b c | c -> Buffer.add_string b (Printf.sprintf "%%%02X" (Char.code c))) s;
  Buffer.contents b

(* the oEmbed request for [url], when its site has one we use *)
let oembed_url (url : string) : string option =
  match Http.parse_url url with
  | Some u ->
      let h = String.lowercase_ascii u.Http.host in
      if h = "youtu.be" || h = "youtube.com" || String.ends_with ~suffix:".youtube.com" h then Some ("https://www.youtube.com/oembed?format=json&url=" ^ pct_encode url) else None
  | None -> None

(* an oEmbed response as a preview; None without a title *)
let parse_oembed (body : string) : t option =
  match Yojson.Safe.from_string body with
  | `Assoc l ->
      let str k = match List.assoc_opt k l with Some (`String s) -> s | _ -> "" in
      if str "title" = "" then None else Some { mimetype = "text/html"; title = str "title"; image = str "thumbnail_url"; description = ""; icon_url = "" }
  | _ -> None
  | exception Yojson.Json_error _ -> None

let to_json (p : t) : string =
  Yojson.Safe.to_string (`Assoc [ ("mimetype", `String p.mimetype); ("title", `String p.title); ("image", `String p.image); ("description", `String p.description); ("icon_url", `String p.icon_url) ])
