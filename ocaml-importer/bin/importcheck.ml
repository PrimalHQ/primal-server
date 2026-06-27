(* End-to-end check: import event JSON (one per line) into the cache DB and report counts.
   Usage: importcheck [path-to-events.jsonl] *)
open Eio.Std
module Pg = Importer.Postgres
module CS = Importer.Cache_storage
module N = Importer.Nostr

let read_lines path =
  let ic = open_in path in
  let rec loop acc =
    match input_line ic with
    | l -> loop (l :: acc)
    | exception End_of_file ->
        close_in ic;
        List.rev acc
  in
  loop []

let () =
  let path = if Array.length Sys.argv > 1 then Sys.argv.(1) else "test/events.jsonl" in
  Eio_main.run @@ fun env ->
  Switch.run @@ fun sw ->
  Pg.set_env ~net:(Eio.Stdenv.net env) ~sw;
  Importer.Cache_storage_ext.register ();
  let dbh = Pg.connect (Pg.cache_conninfo ()) in
  (* staging/test: cache and membership tables share the reference DB, so reuse the handle *)
  let est = { CS.cfg = CS.default_config; dbh; mem_dbh = dbh } in
  let n = ref 0 and ok = ref 0 in
  List.iter
    (fun line ->
      if String.trim line <> "" then begin
        incr n;
        let e = N.of_json (Yojson.Safe.from_string line) in
        if CS.import_event est e then incr ok
      end)
    (read_lines path);
  Printf.printf "imported %d/%d events; events table now has %Ld rows\n%!" !ok !n
    (CS.count_events est)
