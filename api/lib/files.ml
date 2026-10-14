(* Content-moderation repo files read at request time (default-settings.json, app-releases.json,
   …), cached by mtime so a request never pays a disk read unless the file changed. Julia and
   ws-connector re-read these files on every request. *)

let cache : (string, float * string) Hashtbl.t = Hashtbl.create 16
let lock = Mutex.create ()

let read (path : string) : string =
  let mtime = try (Unix.stat path).Unix.st_mtime with Unix.Unix_error _ -> 0. in
  Mutex.lock lock;
  let cached = Hashtbl.find_opt cache path in
  Mutex.unlock lock;
  match cached with
  | Some (m, s) when m = mtime -> s
  | _ ->
      let s = In_channel.with_open_bin path In_channel.input_all in
      Mutex.lock lock;
      Hashtbl.replace cache path (mtime, s);
      Mutex.unlock lock;
      s

let read_opt (path : string) : string option = try Some (read path) with Sys_error _ -> None
