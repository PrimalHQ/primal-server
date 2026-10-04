(* External tools (file, ffprobe, ffmpeg, magick, exiftool, python, ssh) under Eio.Process: stdin
   from a string, stdout/stderr captured, a deadline (SIGKILL past it), LD_LIBRARY_PATH stripped
   from the child's environment (the nix dev shell's libraries must not leak into system tools).
   A child that stops reading stdin early (file(1) after ~7 MiB) is not an error: the write
   failure is swallowed and whatever it printed is used. *)

open Eio.Std

type result = { status : int; stdout : string; stderr : string }

let clean_env () : string array =
  Array.of_list (List.filter (fun kv -> not (String.length kv >= 16 && String.sub kv 0 16 = "LD_LIBRARY_PATH=")) (Array.to_list (Unix.environment ())))

let run ~proc_mgr ~clock ?(timeout = 600.0) ?(stdin_data = "") ?(max_out = 256 * 1024 * 1024) (argv : string list) : result =
  Switch.run @@ fun sw ->
  let in_r, in_w = Eio.Process.pipe ~sw proc_mgr in
  let out_r, out_w = Eio.Process.pipe ~sw proc_mgr in
  let err_r, err_w = Eio.Process.pipe ~sw proc_mgr in
  let child = Eio.Process.spawn ~sw proc_mgr ~stdin:in_r ~stdout:out_w ~stderr:err_w ~env:(clean_env ()) argv in
  Eio.Flow.close in_r;
  Eio.Flow.close out_w;
  Eio.Flow.close err_w;
  let out = ref "" and err = ref "" in
  let writer () =
    (try if stdin_data <> "" then Eio.Flow.copy_string stdin_data in_w with _ -> ());
    try Eio.Flow.close in_w with _ -> ()
  in
  let reader r dst () = dst := (try Eio.Buf_read.take_all (Eio.Buf_read.of_flow ~max_size:max_out (r :> _ Eio.Flow.source)) with _ -> "") in
  let status = ref (-1) in
  let body () =
    Fiber.all [ writer; reader out_r out; reader err_r err ];
    status := (match Eio.Process.await child with `Exited n -> n | `Signaled n -> 128 + n)
  in
  (match Eio.Time.with_timeout clock timeout (fun () -> Ok (body ())) with
  | Ok () -> ()
  | Error `Timeout ->
      (try Eio.Process.signal child Sys.sigkill with _ -> ());
      (try ignore (Eio.Process.await child) with _ -> ());
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
