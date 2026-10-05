(* External tools (file, ffprobe, ffmpeg, magick, exiftool, python, ssh) under Eio.Process: stdin
   from a string, stdout/stderr captured, a deadline (SIGKILL past it), LD_LIBRARY_PATH stripped
   from the child's environment (the nix dev shell's libraries must not leak into system tools).
   A child that stops reading stdin early (file(1) after ~7 MiB) is not an error: the write
   failure is swallowed and whatever it printed is used. *)

open Eio.Std

type result = { status : int; stdout : string; stderr : string }

(* the tools live in the user's nix profile and the system path; a systemd --user unit's PATH may
   have neither *)
let ensure_path () : unit =
  let home = try Sys.getenv "HOME" with Not_found -> "/home/pr" in
  let want = [ home ^ "/.nix-profile/bin"; "/run/current-system/sw/bin"; "/usr/bin"; "/bin" ] in
  let cur = try String.split_on_char ':' (Sys.getenv "PATH") with Not_found -> [] in
  let missing = List.filter (fun d -> (not (List.mem d cur)) && Sys.file_exists d) want in
  if missing <> [] then Unix.putenv "PATH" (String.concat ":" (cur @ missing))

let clean_env () : string array =
  Array.of_list (List.filter (fun kv -> not (String.length kv >= 16 && String.sub kv 0 16 = "LD_LIBRARY_PATH=")) (Array.to_list (Unix.environment ())))

(* Children are created with Unix.create_process_env (posix_spawn, i.e. clone(CLONE_VFORK) on
   Linux), NOT Eio.Process.spawn: eio_linux spawns with fork(), which copies the page tables of
   this multi-GB, multi-domain process for every `file`/`ffmpeg`/`identify` child (20+ a second
   under load) while holding the mmap lock, stalling every other thread on its next page fault
   (2026-10-05, the media role's throughput collapse). The pipes are Eio pipes so reading and
   writing stay non-blocking; the wait polls waitpid(WNOHANG). *)
let run ~proc_mgr:_ ~clock ?(timeout = 600.0) ?(stdin_data = "") ?(max_out = 256 * 1024 * 1024) (argv : string list) : result =
  Switch.run @@ fun sw ->
  (* plain blocking pipes: the child's ends must stay blocking (an Eio pipe sets O_NONBLOCK on
     both ends and the child inherits it); only the parent's ends become Eio flows *)
  let in_r, in_w = Unix.pipe ~cloexec:true () in
  let out_r, out_w = Unix.pipe ~cloexec:true () in
  let err_r, err_w = Unix.pipe ~cloexec:true () in
  let prog = match argv with p :: _ -> p | [] -> invalid_arg "Proc.run: empty argv" in
  let pid =
    match Unix.create_process_env prog (Array.of_list argv) (clean_env ()) in_r out_w err_w with
    | pid -> pid
    | exception e -> List.iter (fun fd -> try Unix.close fd with _ -> ()) [ in_r; in_w; out_r; out_w; err_r; err_w ]; raise e
  in
  Unix.close in_r;
  Unix.close out_w;
  Unix.close err_w;
  let in_w = Eio_unix.Net.import_socket_stream ~sw ~close_unix:true in_w in
  let out_r = Eio_unix.Net.import_socket_stream ~sw ~close_unix:true out_r in
  let err_r = Eio_unix.Net.import_socket_stream ~sw ~close_unix:true err_r in
  let out = ref "" and err = ref "" in
  let writer () =
    (try if stdin_data <> "" then Eio.Flow.copy_string stdin_data in_w with _ -> ());
    try Eio.Flow.close in_w with _ -> ()
  in
  let reader r dst () = dst := (try Eio.Buf_read.take_all (Eio.Buf_read.of_flow ~max_size:max_out (r :> _ Eio.Flow.source)) with _ -> "") in
  let status_of = function Unix.WEXITED n -> n | Unix.WSIGNALED n -> 128 + n | Unix.WSTOPPED n -> 128 + n in
  let rec wait delay =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ -> Eio.Time.sleep clock delay; wait (Float.min 0.2 (delay *. 1.5))
    | _, st -> status_of st
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait delay
  in
  let status = ref (-1) in
  let body () =
    Fiber.all [ writer; reader out_r out; reader err_r err ];
    status := wait 0.005
  in
  (match Eio.Time.with_timeout clock timeout (fun () -> Ok (body ())) with
  | Ok () -> ()
  | Error `Timeout ->
      (try Unix.kill pid Sys.sigkill with _ -> ());
      (try ignore (Eio_unix.run_in_systhread ~label:"proc-reap" (fun () -> Unix.waitpid [] pid)) with _ -> ());
      status := 124;
      err := !err ^ Printf.sprintf "\n[timeout after %.0fs]" timeout);
  { status = !status; stdout = !out; stderr = !err }

let ok (r : result) = r.status = 0

(* a temp file holding [data], removed after [f] *)
let with_tmp_file ?(dir = Filename.get_temp_dir_name ()) ?(suffix = "") (data : string) (f : string -> 'a) : 'a =
  Pushgateway.mkdir_p dir;
  let path = Filename.temp_file ~temp_dir:dir "primal-media-" suffix in
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc data);
  Fun.protect ~finally:(fun () -> try Sys.remove path with _ -> ()) (fun () -> f path)
