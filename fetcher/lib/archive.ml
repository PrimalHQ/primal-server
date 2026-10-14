(* The message archive of DeduplicatedEventStorage: <archive_dir>/messages/YYYY/MM/DD.log, the
   firehose line appended under the UTC day of the event's created_at (dedup_message_log_filename),
   flushed per line; files idle for 2 min are closed (checked every 10 s). *)

type opened = { fd : Unix.file_descr; mutable last_write : float }
type t = { root : string; mu : Mutex.t; files : (string, opened) Hashtbl.t; mutable last_sweep : float; max_open_age : float }

let create ~root = { root; mu = Mutex.create (); files = Hashtbl.create 8; last_sweep = 0.0; max_open_age = 120.0 }

let filename (t : t) (created_at : int) : string =
  let tm = Unix.gmtime (float_of_int created_at) in
  Printf.sprintf "%s/messages/%d/%02d/%02d.log" t.root (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday

let write_all fd (s : string) : unit =
  let n = String.length s and off = ref 0 in
  while !off < n do
    off := !off + Unix.write_substring fd s !off (n - !off)
  done

let sweep (t : t) (now : float) : unit =
  let closed = Hashtbl.fold (fun fn o acc -> if now -. o.last_write >= t.max_open_age then (fn, o) :: acc else acc) t.files [] in
  List.iter (fun (fn, o) -> (try Unix.close o.fd with _ -> ()); Hashtbl.remove t.files fn) closed;
  t.last_sweep <- now

let append (t : t) ~(created_at : int) (line : string) : unit =
  let fn = filename t created_at in
  Mutex.protect t.mu (fun () ->
      let now = Unix.gettimeofday () in
      let o =
        match Hashtbl.find_opt t.files fn with
        | Some o -> o
        | None ->
            Pushgateway.mkdir_p (Filename.dirname fn);
            let fd = Unix.openfile fn [ Unix.O_WRONLY; Unix.O_APPEND; Unix.O_CREAT ] 0o644 in
            let o = { fd; last_write = now } in
            Hashtbl.replace t.files fn o;
            o
      in
      write_all o.fd (line ^ "\n");
      o.last_write <- now;
      if now -. t.last_sweep >= 10.0 then sweep t now)

let close_all (t : t) : unit = Mutex.protect t.mu (fun () -> Hashtbl.iter (fun _ o -> try Unix.close o.fd with _ -> ()) t.files; Hashtbl.reset t.files)
