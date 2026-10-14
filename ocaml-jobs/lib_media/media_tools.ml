(* media.jl / media.rs: downloads (proxy rotation, HEAD size check, range), mime type and
   dimension probing with file(1)/identify/ffprobe/exiftool, ffmpeg variants, thumbnails, frames,
   metadata stripping, link previews (link-preview.py). *)

open Eio.Std

let log = Procgraph.log
let user_agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
let max_download = 2 * 1024 * 1024 * 1024

let mimetype_ext (mt : string) : string =
  match mt with
  | "image/jpeg" -> ".jpg" | "image/png" -> ".png" | "image/gif" -> ".gif" | "image/webp" -> ".webp" | "image/svg+xml" -> ".svg" | "video/mp4" -> ".mp4" | "video/x-m4v" -> ".mp4" | "video/mov" -> ".mov" | "video/webp" -> ".webp"
  | "video/webm" -> ".webm" | "video/quicktime" -> ".mov" | "video/x-matroska" -> ".mkv" | "video/3gpp" -> ".3gp" | "image/vnd.microsoft.icon" -> ".ico" | "text/plain" -> ".txt" | "application/json" -> ".json" | "text/html" -> ".html"
  | "text/javascript" -> ".js" | "application/wasm" -> ".wasm" | _ -> ".bin"

let contains s sub = Str_util.find_substring s sub <> None
let clean_url (u : string) : string = match String.index_opt u '#' with Some i -> String.sub u 0 i | None -> u
let url_ext (u : string) : string =
  let p = clean_url u in
  let p = match String.index_opt p '?' with Some i -> String.sub p 0 i | None -> p in
  let last = match String.rindex_opt p '/' with Some i -> String.sub p (i + 1) (String.length p - i - 1) | None -> p in
  match String.rindex_opt last '.' with Some i -> String.lowercase_ascii (String.sub last i (String.length last - i)) | None -> ""

(* {1 HTTP} *)

(* [host] is [domain] or one of its subdomains: a match on the parsed host, never a substring of
   the URL (a query string could supply that), and only for plain hostname characters. *)
let host_under (domains : string list) (host : string) : bool =
  let h = String.lowercase_ascii host in
  h <> ""
  && String.for_all (function 'a' .. 'z' | '0' .. '9' | '.' | '-' -> true | _ -> false) h
  && List.exists (fun d -> h = d || String.ends_with ~suffix:("." ^ d) h) domains

(* Primal's own hosts: downloads from them go direct first (no proxy), and they and the nodes get
   the long timeout *)
let direct_domains = [ "primal.net" ]
let long_timeout_domains = [ "primal.net"; "primalnode.net" ]
let url_host_under (domains : string list) (url : string) : bool = match Http.parse_url url with Some u -> host_under domains u.Http.host | None -> false

exception Refused of string

(* The connection for one request. A direct one to a host that is not Primal's (no proxies
   configured, or a redirect away from a Primal host) must resolve to a public address, which is
   then the one connected to: the URL and every Location come from untrusted input, and the media
   host sits on the internal network. *)
let connect (ctx : Procgraph.ctx) ~sw ~proxy (u : Http.url) : Http.conn =
  match proxy with
  | None when not (host_under direct_domains u.host) -> (
      Phases.phase "https:dns";
      match Http.resolve ~net:ctx.net ~clock:ctx.clock ~sw ~host:u.host ~port:u.port with
      | `Tcp (ip, _) as addr when Http.is_public_ip ip ->
          Phases.phase "https:connect";
          (Eio.Net.connect ~sw ctx.net addr :> Http.conn)
      | _ -> raise (Refused (Printf.sprintf "%s: not a public address" u.host)))
  | _ -> Http.two_way_of_proxy ~sw ~net:ctx.net ~clock:ctx.clock ~proxy ~host:u.host ~port:u.port

(* one GET/HEAD over Http's connection helpers with a large body cap and redirects; raises
   [Refused] for a hop [connect] refuses *)
let fetch (ctx : Procgraph.ctx) ?proxy ~(timeout : float) ~(meth : string) ?(headers = []) ?(max_body = max_download) (url : string) : Http.response option =
  let one (u : Http.url) : Http.response option =
    try
      Switch.run @@ fun sw ->
      match
        Eio.Time.with_timeout ctx.clock timeout (fun () ->
            let tcp = connect ctx ~sw ~proxy u in
            let flow = if u.scheme = "https" then Http.tls_wrap ~host:u.host tcp else (tcp :> Eio.Flow.two_way_ty r) in
            let hdrs = ("Host", u.host) :: ("Connection", "close") :: ("User-Agent", user_agent) :: headers in
            let req = Printf.sprintf "%s %s HTTP/1.1\r\n%s\r\n" meth u.path (String.concat "" (List.map (fun (k, v) -> k ^ ": " ^ v ^ "\r\n") hdrs)) in
            Eio.Flow.copy_string req (flow :> _ Eio.Flow.sink);
            let r = Eio.Buf_read.of_flow (flow :> _ Eio.Flow.source) ~max_size:(max_body + (1 lsl 20)) in
            Ok (Http.parse_response (Eio.Buf_read.take_all r)))
      with
      | Ok r -> Some r
      | Error `Timeout -> None
    with
    | (Eio.Cancel.Cancelled _ | Refused _) as e -> raise e
    | _ -> None
  in
  let rec go url n =
    match Http.parse_url url with
    | None -> None
    | Some u -> (
        match one u with
        | Some r when (r.status = 301 || r.status = 302 || r.status = 303 || r.status = 307 || r.status = 308) && n < 5 -> ( match List.assoc_opt "location" r.resp_headers with Some loc -> go (Http.urljoin url loc) (n + 1) | None -> Some r)
        | r -> r)
  in
  go url 0

let shuffle (l : 'a list) : 'a list = let a = Array.of_list l in let n = Array.length a in for i = n - 1 downto 1 do let j = Random.int (i + 1) in let t = a.(i) in a.(i) <- a.(j); a.(j) <- t done; Array.to_list a

(* Media.download: the requested proxy, or the configured proxies in random order (direct first
   for primal hosts); HEAD size check; 180 s for primal hosts; 2 s between attempts. A direct
   attempt [connect] refuses moves on to the next proxy. *)
let download (ctx : Procgraph.ctx) ?proxy ?timeout ?range (url : string) : string =
  let cfg = ctx.cfg in
  let timeout = if url_host_under long_timeout_domains url then 180.0 else Option.value timeout ~default:cfg.download_timeout_s in
  let proxies : (string * int) option list =
    match proxy with
    | Some p -> [ p ]
    | None ->
        let ps = shuffle (List.filter_map Media_config.parse_proxy cfg.proxies) |> List.map (fun p -> Some p) in
        if url_host_under direct_domains url && not (List.mem None ps) then None :: ps else if ps = [] then [ None ] else ps
  in
  let last_err = ref "download failed" in
  let result = ref None in
  List.iter
    (fun p ->
      if !result = None then begin
        (try
           (if range = None then
              match fetch ctx ?proxy:p ~timeout ~meth:"HEAD" ~max_body:(1 lsl 20) url with
              | Some r -> (
                  match List.assoc_opt "content-length" r.Http.resp_headers with
                  | Some cl -> ( match int_of_string_opt (String.trim cl) with Some n when n > max_download -> Procgraph.fail "File size %d bytes exceeds maximum allowed size of 2GB" n | _ -> ())
                  | None -> ())
              | None -> ());
           let headers = match range with Some (a, b) -> [ ("Range", Printf.sprintf "bytes=%d-%d" (max 0 (a - 1)) (max 0 (b - 1))) ] | None -> [] in
           match fetch ctx ?proxy:p ~timeout ~meth:"GET" ~headers url with
           | Some r when r.status >= 200 && r.status < 300 -> result := Some r.body
           | Some r -> last_err := Printf.sprintf "HTTP %d" r.status
           | None -> last_err := "request failed or timed out"
         with Refused m -> last_err := "refused: " ^ m);
        if !result = None then Eio.Time.sleep ctx.clock 2.0
      end)
    proxies;
  match !result with Some b -> b | None -> Procgraph.fail "download %s: %s" url !last_err

(* {1 probing} *)

let parse_mimetype (ctx : Procgraph.ctx) (data : string) : string =
  if data = "" then "inode/x-empty"
  else
    let r = Proc.run ~proc_mgr:ctx.proc_mgr ~clock:ctx.clock ~timeout:60.0 ~stdin_data:data [ "file"; "-b"; "--mime-type"; "-" ] in
    let mt = String.trim r.stdout in
    if r.status = 0 && mt <> "" then mt else "application/octet-stream"

let re_dims = Re.compile (Re.seq [ Re.str ", "; Re.group (Re.rep1 Re.digit); Re.opt (Re.char ' '); Re.char 'x'; Re.opt (Re.char ' '); Re.group (Re.rep1 Re.digit); Re.alt [ Re.str ", "; Re.eol ] ])

(* (width, height, duration) *)
let parse_image_dimensions (ctx : Procgraph.ctx) (data : string) : (int * int * float) option =
  let svg = String.length data >= 4 && (String.sub data 0 4 = "<svg" || contains (String.sub data 0 (min (String.length data) 4096)) "<svg") in
  let from_svg () =
    let attr k = match Str_util.find_substring data (k ^ "=\"") with Some i -> ( let st = i + String.length k + 2 in match String.index_from_opt data st '"' with Some j -> int_of_string_opt (String.sub data st (j - st)) | None -> None) | None -> None in
    match (attr "width", attr "height") with Some w, Some h when w > 0 -> Some (500, 500 * h / w, 0.0) | _ -> None
  in
  match if svg then from_svg () else None with
  | Some r -> Some r
  | None ->
      Proc.with_tmp_file data (fun path ->
          let r = Proc.run ~proc_mgr:ctx.proc_mgr ~clock:ctx.clock ~timeout:60.0 [ "file"; path ] in
          let from_file = if r.status = 0 then (match Re.exec_opt re_dims r.stdout with Some g -> Some (int_of_string (Re.Group.get g 1), int_of_string (Re.Group.get g 2), 0.0) | None -> None) else None in
          match from_file with
          | Some d -> Some d
          | None -> (
              let r = Proc.run ~proc_mgr:ctx.proc_mgr ~clock:ctx.clock ~timeout:120.0 [ "identify"; "-format"; "%w %h"; path ^ "[0]" ] in
              match String.split_on_char ' ' (String.trim r.stdout) with
              | w :: h :: _ when r.status = 0 -> ( match (int_of_string_opt w, int_of_string_opt h) with Some w, Some h -> Some (w, h, 0.0) | _ -> None)
              | _ -> None))

let is_image_rotated (ctx : Procgraph.ctx) (data : string) : bool =
  Proc.with_tmp_file data (fun path ->
      let r = Proc.run ~proc_mgr:ctx.proc_mgr ~clock:ctx.clock ~timeout:60.0 [ "exiftool"; "-t"; path ] in
      r.status = 0 && List.exists (fun line -> match String.split_on_char '\t' line with k :: v :: _ -> k = "Orientation" && contains v "Rotate 90 CW" | _ -> false) (String.split_on_char '\n' r.stdout))

let parse_video_dimensions (ctx : Procgraph.ctx) (data : string) : (int * int * float) option =
  Proc.with_tmp_file data (fun path ->
      let probe args = Proc.run ~proc_mgr:ctx.proc_mgr ~clock:ctx.clock ~timeout:120.0 ([ "ffprobe"; "-v"; "error"; "-probesize"; "10M"; "-select_streams"; "v:0" ] @ args @ [ path ]) in
      let r = probe [ "-show_entries"; "stream" ] in
      if r.status <> 0 then None
      else begin
        let width = ref 0 and height = ref 0 and duration = ref 0.0 and rotation = ref 0 and dar = ref None in
        List.iter
          (fun line ->
            match String.index_opt line '=' with
            | Some i -> (
                let k = String.sub line 0 i and v = String.sub line (i + 1) (String.length line - i - 1) in
                match k with
                | "width" -> width := Option.value (int_of_string_opt v) ~default:0
                | "height" -> height := Option.value (int_of_string_opt v) ~default:0
                | "duration" -> ( match float_of_string_opt v with Some d -> duration := d | None -> ())
                | "rotation" -> rotation := Option.value (int_of_string_opt v) ~default:0
                | "display_aspect_ratio" -> dar := Some v
                | _ -> ())
            | None -> ())
          (String.split_on_char '\n' r.stdout);
        if !duration = 0.0 then begin
          let r2 = probe [ "-show_format" ] in
          if r2.status = 0 then List.iter (fun line -> match String.index_opt line '=' with Some i when String.sub line 0 i = "duration" -> ( match float_of_string_opt (String.sub line (i + 1) (String.length line - i - 1)) with Some d -> duration := d | None -> ()) | _ -> ()) (String.split_on_char '\n' r2.stdout)
        end;
        if !rotation = 90 || !rotation = -90 || !rotation = 270 then (let w = !width in width := !height; height := w)
        else (match !dar with
             | Some d -> ( match String.split_on_char ':' d with [ w; h ] -> ( match (float_of_string_opt w, float_of_string_opt h) with Some dw, Some dh when dh > dw && !width > !height -> let w = !width in width := !height; height := w | _ -> ()) | _ -> ())
             | None -> ());
        if !width = 0 || !height = 0 then None else Some (!width, !height, !duration)
      end)

(* {1 ffmpeg / magick} *)

let magick (ctx : Procgraph.ctx) ~(stdin_data : string) (args : string list) : string option =
  let r = Proc.run ~proc_mgr:ctx.proc_mgr ~clock:ctx.clock ~timeout:300.0 ~stdin_data ("magick" :: args) in
  if r.status = 0 && r.stdout <> "" then Some r.stdout else None

let extract_video_thumbnail (ctx : Procgraph.ctx) (data : string) : string option =
  match parse_video_dimensions ctx data with
  | None -> None
  | Some _ ->
      Proc.with_tmp_file data (fun path ->
          let r = Proc.run ~proc_mgr:ctx.proc_mgr ~clock:ctx.clock ~timeout:300.0 [ "ffmpeg"; "-v"; "error"; "-i"; path; "-vframes"; "1"; "-an"; "-ss"; "0"; "-vf"; "scale=iw*sar:ih,scale='min(1280,iw)':'-1'"; "-c:v"; "png"; "-f"; "image2pipe"; "-" ] in
          if r.status = 0 && r.stdout <> "" then magick ctx ~stdin_data:r.stdout [ "-"; "-quality"; "90"; "jpg:-" ] else None)

let strip_metadata (ctx : Procgraph.ctx) (data : string) : string =
  Proc.with_tmp_file data (fun path ->
      let r = Proc.run ~proc_mgr:ctx.proc_mgr ~clock:ctx.clock ~timeout:120.0 [ "exiftool"; "-ignoreMinorErrors"; "-all="; "-tagsfromfile"; "@"; "-Orientation"; "-overwrite_original"; path ] in
      if r.status = 0 then Pgj.read_file path
      else
        let ext = String.sub (mimetype_ext (parse_mimetype ctx data)) 1 (String.length (mimetype_ext (parse_mimetype ctx data)) - 1) in
        let r = Proc.run ~proc_mgr:ctx.proc_mgr ~clock:ctx.clock ~timeout:300.0 [ "ffmpeg"; "-y"; "-i"; path; "-map_metadata"; "-1"; "-c:v"; "copy"; "-c:a"; "copy"; "-f"; ext; "-" ] in
        if r.status = 0 && r.stdout <> "" then r.stdout else Procgraph.fail "Both exiftool and ffmpeg failed to strip metadata")

(* N frames at evenly spaced positions: (position, image bytes) *)
let extract_video_frames (ctx : Procgraph.ctx) ?(nframes = 5) ?(image_format = "mjpeg") (data : string) : (float * string) list =
  match parse_video_dimensions ctx data with
  | None | Some (_, _, 0.0) -> Procgraph.fail "Cannot extract frames: invalid video duration"
  | Some (_, _, dur) ->
      Proc.with_tmp_file data (fun path ->
          List.filter_map
            (fun i ->
              let pos = float_of_int i *. dur /. float_of_int (nframes + 1) in
              let r = Proc.run ~proc_mgr:ctx.proc_mgr ~clock:ctx.clock ~timeout:300.0 [ "ffmpeg"; "-v"; "error"; "-i"; path; "-vframes"; "1"; "-an"; "-ss"; Pgj.julia_float pos; "-c:v"; image_format; "-f"; "image2pipe"; "-" ] in
              if r.status = 0 && r.stdout <> "" then Option.map (fun d -> (pos, d)) (magick ctx ~stdin_data:r.stdout [ "-"; "-" ]) else None)
            (List.init nframes (fun i -> i + 1)))

let resize_image (ctx : Procgraph.ctx) ?(size = (512, 512)) (data : string) : string option =
  let r = Proc.run ~proc_mgr:ctx.proc_mgr ~clock:ctx.clock ~timeout:300.0 ~stdin_data:data [ "systemd-run"; "--quiet"; "--scope"; "-p"; "MemoryMax=5G"; "--user"; "magick"; "-"; "-resize"; Printf.sprintf "%dx%d" (fst size) (snd size); "-" ] in
  if r.status = 0 && r.stdout <> "" then Some r.stdout else None

let extract_video_beginning (ctx : Procgraph.ctx) ?(duration = 20) ?(timeout = 15.0) (data : string) : string =
  Proc.with_tmp_file data (fun fn1 ->
      let fn2 = fn1 ^ "-2.mp4" in
      Fun.protect ~finally:(fun () -> try Sys.remove fn2 with _ -> ()) (fun () ->
          let r = Proc.run ~proc_mgr:ctx.proc_mgr ~clock:ctx.clock ~timeout:(timeout +. 5.0) [ "timeout"; Printf.sprintf "%.0f" timeout; "ffmpeg"; "-v"; "error"; "-i"; fn1; "-t"; string_of_int duration; "-movflags"; "faststart"; "-c"; "copy"; fn2 ] in
          if r.status = 0 then Pgj.read_file fn2 else Procgraph.fail "extract_video_beginning failed"))

let size_resolution = function "small" -> (200, 200) | "medium" -> (400, 400) | "large" -> (1000, 1000) | _ -> (0, 0)
let build_scale_filter (size : string) : string option =
  let w, h = size_resolution size in
  if w = 0 then None else if size = "small" || size = "medium" then Some (Printf.sprintf "scale=trunc(oh*a/2)*2:min(%d\\,ih)" h) else if size = "large" then Some (Printf.sprintf "scale=min(%d\\,iw):trunc(ow/a/2)*2" w) else None

(* media.rs ffmpeg_resize_to_file: stdin -> outfn; returns ffmpeg's stderr *)
let ffmpeg_resize_to_file (ctx : Procgraph.ctx) ~(input : string) ~(filters : string list) ~(single_frame : bool) ~(outfn : string) : string =
  let args = [ "-v"; "error"; "-y"; "-i"; "-"; "-map_metadata"; "-1" ] @ (if single_frame then [ "-frames:v"; "1"; "-update"; "1" ] else []) @ (if filters <> [] then [ "-vf"; String.concat "," filters ] else []) in
  match ctx.cfg.ffmpeg_remote_host with
  | None ->
      let r = Proc.run ~proc_mgr:ctx.proc_mgr ~clock:ctx.clock ~timeout:600.0 ~stdin_data:input ([ "nice"; "ionice"; "-c3"; "ffmpeg" ] @ args @ [ outfn ]) in
      if r.status <> 0 then Procgraph.fail "ffmpeg resize failed: %s" (String.trim r.stderr);
      r.stderr
  | Some host ->
      let ext = url_ext outfn in
      let fmt = match ext with ".jpg" | ".jpeg" -> "mjpeg" | ".png" -> "image2" | ".webp" -> "webp" | ".gif" -> "gif" | ".mp4" -> "mp4" | _ -> "mjpeg" in
      let args = args @ (if fmt = "mp4" then [ "-movflags"; "frag_keyframe+empty_moov" ] else []) @ [ "-f"; fmt; "pipe:1" ] in
      let remote = String.concat " " (List.map Filename.quote ("nice" :: "ffmpeg" :: args)) in
      let r = Proc.run ~proc_mgr:ctx.proc_mgr ~clock:ctx.clock ~timeout:600.0 ~stdin_data:input [ "ssh"; host; remote ] in
      if r.status <> 0 || r.stdout = "" then Procgraph.fail "remote ffmpeg failed (%s): %s" host (String.trim r.stderr);
      Pushgateway.mkdir_p (Filename.dirname outfn);
      let oc = open_out_bin outfn in
      Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc r.stdout);
      r.stderr

(* {1 link preview} *)
type resource_metadata = { mimetype : string; title : string; description : string; image : string; icon_url : string }
let empty_metadata = { mimetype = ""; title = ""; description = ""; image = ""; icon_url = "" }

let fetch_resource_metadata (ctx : Procgraph.ctx) (url : string) : resource_metadata =
  let proxy = Option.value ctx.cfg.metadata_proxy ~default:"null" in
  if not (Sys.file_exists ctx.cfg.link_preview_script) then empty_metadata
  else
    let r = Proc.run ~proc_mgr:ctx.proc_mgr ~clock:ctx.clock ~timeout:20.0 [ "timeout"; "10"; "nice"; ctx.cfg.python_path; ctx.cfg.link_preview_script; url; proxy ] in
    if r.status <> 0 then empty_metadata
    else
      match Yojson.Safe.from_string r.stdout with
      | `Assoc f ->
          let g k = match List.assoc_opt k f with Some (`String s) -> s | _ -> "" in
          { mimetype = g "mimetype"; title = g "title"; description = g "description"; image = g "image"; icon_url = g "icon_url" }
      | _ -> empty_metadata
      | exception _ -> empty_metadata

(* {1 AI hosts} *)
let post_json (ctx : Procgraph.ctx) ~(timeout : float) (url : string) (body : Pgj.t) : Pgj.t option =
  match Http.request ~net:ctx.net ~clock:ctx.clock ~timeout ~meth:"POST" ~headers:[ ("Content-Type", "application/json") ] ~body:(Yojson.Safe.to_string body) url with
  | Some r when r.status >= 200 && r.status < 300 -> ( try Some (Yojson.Safe.from_string r.body) with _ -> None)
  | _ -> None

(* media_ai.jl image_features / video_features: the embedding vector *)
let image_features (ctx : Procgraph.ctx) ?(model = "google/vit-base-patch16-384") (data : string) : Pgj.t option =
  match post_json ctx ~timeout:ctx.cfg.ai_timeout_s (Printf.sprintf "http://%s:5013/features" ctx.cfg.ai_host) (`Assoc [ ("model", `String model); ("pool", `Bool true); ("image", `String (Base64.encode_string data)) ]) with
  | Some (`Assoc f) when List.assoc_opt "error" f = None -> List.assoc_opt "output" f
  | _ -> None

let video_features (ctx : Procgraph.ctx) ?(model = "google/vivit-b-16x2-kinetics400") (data : string) : Pgj.t option =
  match post_json ctx ~timeout:ctx.cfg.ai_timeout_s (Printf.sprintf "http://%s:5014/features" ctx.cfg.ai_host) (`Assoc [ ("model", `String model); ("video", `String (Base64.encode_string data)) ]) with
  | Some (`Assoc f) when List.assoc_opt "error" f = None -> List.assoc_opt "output" f
  | _ -> None
