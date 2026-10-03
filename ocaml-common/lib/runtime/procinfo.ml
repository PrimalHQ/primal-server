(* Process-level numbers for log lines and watchdogs. *)

let fmt_hms s = Printf.sprintf "%02d:%02d:%02d" (s / 3600) (s / 60 mod 60) (s mod 60)

(* Whole-process resident set size (bytes), read from /proc/self/statm (field 2 = resident pages).
   This is process-wide — it covers every worker domain and all C/malloc allocations (TLS buffers,
   etc.), not just the OCaml heap — so it is the number the OOM killer actually acts on. Linux
   x86_64 pages are 4 KiB. Best-effort: any read failure yields 0. *)
let page_size = 4096

let read_rss_bytes () =
  try
    let ic = open_in "/proc/self/statm" in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        match String.split_on_char ' ' (input_line ic) with
        | _size :: resident :: _ -> int_of_string resident * page_size
        | _ -> 0)
  with _ -> 0

(* OCaml major heap size in bytes (shared across domains). quick_stat does not walk the heap, so
   it is cheap enough to sample every second. *)
let heap_bytes () = (Gc.quick_stat ()).Gc.heap_words * (Sys.word_size / 8)

let fmt_bytes b =
  let b = float_of_int b in
  if b >= 1073741824. then Printf.sprintf "%.2fG" (b /. 1073741824.)
  else if b >= 1048576. then Printf.sprintf "%.0fM" (b /. 1048576.)
  else Printf.sprintf "%.0fK" (b /. 1024.)

(* "YYYY-MM-DD HH:MM:SS" local wall-clock stamp for log lines. *)
let timestamp () =
  let tm = Unix.localtime (Unix.gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
