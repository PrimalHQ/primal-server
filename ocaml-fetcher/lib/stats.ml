(* Process-wide counters: the per-Fetcher fields of fetching.jl summed (message_count,
   exception_count, chars_received, chars_sent — the pushgateway metrics) and the
   DeduplicatedEventStorage stats (seen, seenearly, parseerr, verifyerr, any; persisted in
   stats.json). *)

type t = {
  message_count : int Atomic.t;
  exception_count : int Atomic.t;
  chars_received : int Atomic.t;
  chars_sent : int Atomic.t;
  relays_total : int Atomic.t;
  relays_connected : int Atomic.t;
  connecting : int Atomic.t;
  relays_waiting : int Atomic.t;
  relays_providing : int Atomic.t; (* message_count > 0 at least once *)
  seen : int Atomic.t;
  seenearly : int Atomic.t;
  parseerr : int Atomic.t;
  verifyerr : int Atomic.t;
  any : int Atomic.t;
  archive_errors : int Atomic.t;
  firehose_sent : int Atomic.t;
  firehose_dropped : int Atomic.t;
  processor_queue_full : int Atomic.t;
}

let create () =
  let z () = Atomic.make 0 in
  { message_count = z (); exception_count = z (); chars_received = z (); chars_sent = z (); relays_total = z (); relays_connected = z (); connecting = z (); relays_waiting = z (); relays_providing = z (); seen = z (); seenearly = z (); parseerr = z (); verifyerr = z (); any = z (); archive_errors = z (); firehose_sent = z (); firehose_dropped = z (); processor_queue_full = z () }

let add a n = ignore (Atomic.fetch_and_add a n)
let incr a = add a 1
let decr a = add a (-1)

let persisted_keys = [ "seen"; "seenearly"; "parseerr"; "verifyerr"; "any" ]

let to_json (t : t) : Yojson.Safe.t =
  `Assoc
    [ ("message_count", `Int (Atomic.get t.message_count)); ("exception_count", `Int (Atomic.get t.exception_count)); ("chars_received", `Int (Atomic.get t.chars_received)); ("chars_sent", `Int (Atomic.get t.chars_sent));
      ("relays_total", `Int (Atomic.get t.relays_total)); ("relays_connected", `Int (Atomic.get t.relays_connected)); ("connecting", `Int (Atomic.get t.connecting)); ("relays_waiting", `Int (Atomic.get t.relays_waiting)); ("relays_providing", `Int (Atomic.get t.relays_providing));
      ("seen", `Int (Atomic.get t.seen)); ("seenearly", `Int (Atomic.get t.seenearly)); ("parseerr", `Int (Atomic.get t.parseerr)); ("verifyerr", `Int (Atomic.get t.verifyerr)); ("any", `Int (Atomic.get t.any));
      ("archive_errors", `Int (Atomic.get t.archive_errors)); ("firehose_sent", `Int (Atomic.get t.firehose_sent)); ("firehose_dropped", `Int (Atomic.get t.firehose_dropped)); ("processor_queue_full", `Int (Atomic.get t.processor_queue_full)) ]

(* stats.json: the whole object is kept verbatim; the persisted counters are baseline + session. *)
let load_baseline (path : string) : (string * Yojson.Safe.t) list * (string * int) list =
  match Yojson.Safe.from_file path with
  | `Assoc fields ->
      let get k = match List.assoc_opt k fields with Some (`Int n) -> n | Some (`Intlit s) -> ( try int_of_string s with _ -> 0) | Some (`Float f) -> int_of_float f | _ -> 0 in
      (fields, List.map (fun k -> (k, get k)) persisted_keys)
  | _ -> ([], [])
  | exception _ -> ([], [])

let save (path : string) (fields : (string * Yojson.Safe.t) list) (baseline : (string * int) list) (t : t) : unit =
  let session k = match k with "seen" -> Atomic.get t.seen | "seenearly" -> Atomic.get t.seenearly | "parseerr" -> Atomic.get t.parseerr | "verifyerr" -> Atomic.get t.verifyerr | "any" -> Atomic.get t.any | _ -> 0 in
  let value k = `Int (Option.value (List.assoc_opt k baseline) ~default:0 + session k) in
  let fields = List.map (fun (k, v) -> if List.mem k persisted_keys then (k, value k) else (k, v)) fields in
  let fields = List.fold_left (fun acc k -> if List.mem_assoc k acc then acc else acc @ [ (k, value k) ]) fields persisted_keys in
  try
    Pushgateway.mkdir_p (Filename.dirname path);
    let tmp = path ^ ".tmp" in
    let oc = open_out tmp in
    Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc (Yojson.Safe.to_string (`Assoc fields)));
    Sys.rename tmp path
  with exn -> Printf.eprintf "stats: save %s: %s\n%!" path (Printexc.to_string exn)
