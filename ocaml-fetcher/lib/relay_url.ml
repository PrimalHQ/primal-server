(* Relay URL sanitising, mirroring fetching.jl sanitize_uri / sanitize_valid_relay_url (URIs.jl
   semantics): lowercase host, default port dropped, path normalised and stripped of trailing
   slashes; .onion, IPv6 literals and localhost rejected. The STRING form matters: it names the
   per-relay state directory (Resume), so it has to come out exactly as Julia's string(URI). *)

type parts = { scheme : string; userinfo : string option; host : string; port : string option; path : string; query : string option; fragment : string option }

let parse (s : string) : parts option =
  match Str.bounded_split_delim (Str.regexp_string "://") s 2 with
  | [ scheme; rest ] when scheme <> "" ->
      let rest, fragment = match String.index_opt rest '#' with Some i -> (String.sub rest 0 i, Some (String.sub rest (i + 1) (String.length rest - i - 1))) | None -> (rest, None) in
      let rest, query = match String.index_opt rest '?' with Some i -> (String.sub rest 0 i, Some (String.sub rest (i + 1) (String.length rest - i - 1))) | None -> (rest, None) in
      let authority, path = match String.index_opt rest '/' with Some i -> (String.sub rest 0 i, String.sub rest i (String.length rest - i)) | None -> (rest, "") in
      let userinfo, hostport = match String.rindex_opt authority '@' with Some i -> (Some (String.sub authority 0 i), String.sub authority (i + 1) (String.length authority - i - 1)) | None -> (None, authority) in
      let host, port =
        if String.length hostport > 0 && hostport.[0] = '[' then (hostport, None)
        else match String.rindex_opt hostport ':' with Some i -> (String.sub hostport 0 i, Some (String.sub hostport (i + 1) (String.length hostport - i - 1))) | None -> (hostport, None)
      in
      Some { scheme; userinfo; host; port; path; query; fragment }
  | _ -> None

(* URIs.normpath: resolve "." and ".." segments *)
let normpath (p : string) : string =
  if p = "" then ""
  else
    let segs = String.split_on_char '/' p in
    let absolute = String.length p > 0 && p.[0] = '/' in
    (* only "." and ".." are resolved; empty segments ("a//b") survive, as in URIs.normpath *)
    let segs = if absolute then List.tl segs else segs in
    let out = List.fold_left (fun acc s -> match s with "." -> acc | ".." -> ( match acc with _ :: tl -> tl | [] -> []) | s -> s :: acc) [] segs in
    let body = String.concat "/" (List.rev out) in
    (if absolute then "/" else "") ^ body

let to_string (u : parts) : string =
  String.concat ""
    [ u.scheme; "://"; (match u.userinfo with Some ui -> ui ^ "@" | None -> ""); u.host; (match u.port with Some p -> ":" ^ p | None -> ""); u.path;
      (match u.query with Some q -> "?" ^ q | None -> ""); (match u.fragment with Some f -> "#" ^ f | None -> "") ]

let rstrip_slashes (s : string) : string =
  let n = ref (String.length s) in
  while !n > 0 && s.[!n - 1] = '/' do decr n done;
  String.sub s 0 !n

(* sanitize_uri *)
let sanitize (u : parts) : parts =
  (* strip(u.host, [' ']): spaces only — a tab inside the host survives, as it does in Julia *)
  let strip_spaces s = let n = String.length s in let i = ref 0 and j = ref n in while !i < n && s.[!i] = ' ' do incr i done; while !j > !i && s.[!j - 1] = ' ' do decr j done; String.sub s !i (!j - !i) in
  let host = String.lowercase_ascii (strip_spaces u.host) in
  let path = rstrip_slashes (normpath u.path) in
  let port = match (u.scheme, u.port) with ("ws", Some "80") | ("wss", Some "443") -> None | _ -> u.port in
  { u with host; path; port }

let ends_with ~suffix s = let ls = String.length s and lf = String.length suffix in ls >= lf && String.sub s (ls - lf) lf = suffix

(* sanitize_valid_relay_url: None when the url is to be dropped *)
let sanitize_valid (url : string) : string option =
  if url = "" || ends_with ~suffix:".onion" url then None
  else
    let url = List.hd (String.split_on_char '\n' (String.trim url)) in
    match parse url with
    | None -> None
    | Some u ->
        let u = sanitize u in
        (* URIs.jl: a query makes isvalid false, a fragment makes URI() throw — both dropped *)
        if u.query <> None || u.fragment <> None then None
        (* URIs.isvalid accepts an empty host ("wss:///x"); such urls stay, dead, as in Julia *)
        else if String.contains u.host ':' || (String.length u.host > 0 && u.host.[0] = '[') then None
        else if u.host = "localhost" || u.host = "127.0.0.1" then None
        else if not (u.scheme = "ws" || u.scheme = "wss") then None
        else Some (to_string u)

(* monitor_relays_from_db: skip 192.168/16, 10/8, 127/8 literal hosts *)
let private_ipv4_host (host : string) : bool =
  match String.split_on_char '.' host with
  | [ a; b; _; _ ] -> ( match (int_of_string_opt a, int_of_string_opt b) with Some a, Some b -> (a = 192 && b = 168) || a = 10 || a = 127 | _ -> false)
  | _ -> false
