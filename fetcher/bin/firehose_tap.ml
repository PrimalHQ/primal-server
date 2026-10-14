(* firehose_tap HOST PORT SECONDS: subscribe to a firehose and report what came through — lines,
   EVENT envelopes, distinct event ids, exception/sleep envelopes — for comparing two fetchers
   feeding the same kind of client. *)

open Eio.Std

let () =
  let host, port, secs, ids_out = match Sys.argv with [| _; h; p; s |] -> (h, int_of_string p, float_of_string s, None) | [| _; h; p; s; o |] -> (h, int_of_string p, float_of_string s, Some o) | _ -> prerr_endline "usage: firehose_tap HOST PORT SECONDS [IDS_FILE]"; exit 2 in
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  Switch.run @@ fun sw ->
  let addr = match Eio.Net.getaddrinfo_stream ~service:(string_of_int port) net host with a :: _ -> a | [] -> failwith "resolve" in
  let flow = Eio.Net.connect ~sw net addr in
  Eio.Flow.copy_string "STREAM-NEW-EVENTS\n" flow;
  let r = Eio.Buf_read.of_flow (flow :> _ Eio.Flow.source) ~max_size:(64 * 1024 * 1024) in
  let lines = ref 0 and events = ref 0 and ids = Hashtbl.create 100_000 and kinds = Hashtbl.create 64 and other = Hashtbl.create 16 and bytes = ref 0 and relays = Hashtbl.create 1024 in
  let t0 = Unix.gettimeofday () in
  (try
     Eio.Time.with_timeout_exn clock secs (fun () ->
         while true do
           let l = Eio.Buf_read.line r in
           incr lines;
           bytes := !bytes + String.length l;
           match Yojson.Safe.from_string l with
           | `List (_ :: `Assoc md :: m :: _) -> (
               (match List.assoc_opt "relay_url" md with Some (`String u) -> Hashtbl.replace relays u () | _ -> ());
               match m with
               | `List (`String "EVENT" :: _ :: `Assoc ev :: _) ->
                   incr events;
                   (match List.assoc_opt "id" ev with Some (`String id) -> Hashtbl.replace ids id () | _ -> ());
                   (match List.assoc_opt "kind" ev with Some (`Int k) -> Hashtbl.replace kinds k (1 + Option.value (Hashtbl.find_opt kinds k) ~default:0) | _ -> ())
               | _ ->
                   let ev = match List.assoc_opt "event" md with Some (`String e) -> e | _ -> "?" in
                   let key = match m with `List (`String t :: _) -> ev ^ ":" ^ t | _ -> ev in
                   Hashtbl.replace other key (1 + Option.value (Hashtbl.find_opt other key) ~default:0))
           | _ -> Hashtbl.replace other "unparsed" (1 + Option.value (Hashtbl.find_opt other "unparsed") ~default:0)
           | exception _ -> Hashtbl.replace other "unparsed" (1 + Option.value (Hashtbl.find_opt other "unparsed") ~default:0)
         done)
   with Eio.Time.Timeout -> () | End_of_file -> prerr_endline "EOF from server");
  let dt = Unix.gettimeofday () -. t0 in
  Printf.printf "%s:%d over %.0fs: lines %d (%.0f/s, %.0f KB/s) EVENT %d (%.0f/s) distinct ids %d (%.0f/s) relays %d\n" host port dt !lines (float !lines /. dt) (float !bytes /. dt /. 1024.) !events (float !events /. dt) (Hashtbl.length ids) (float (Hashtbl.length ids) /. dt) (Hashtbl.length relays);
  let top = List.sort (fun (_, a) (_, b) -> compare b a) (Hashtbl.fold (fun k v acc -> (k, v) :: acc) kinds []) in
  Printf.printf "top kinds: %s\n" (String.concat " " (List.map (fun (k, v) -> Printf.sprintf "%d:%d" k v) (List.filteri (fun i _ -> i < 12) top)));
  (match ids_out with Some o -> let oc = open_out o in Hashtbl.iter (fun id _ -> output_string oc (id ^ "\n")) ids; close_out oc | None -> ());
  Printf.printf "other lines: %s\n" (String.concat " " (List.map (fun (k, v) -> Printf.sprintf "%s=%d" k v) (List.sort compare (Hashtbl.fold (fun k v acc -> (k, v) :: acc) other []))))
