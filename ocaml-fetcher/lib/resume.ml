(* Per-relay resume point: <state_dir>/<escaped url>/latest_timestamp, the file Julia's
   update_fetchers! reads at start and its Throttle(period=5) safe_save writes — same escaping
   (every char outside [a-zA-Z0-9] becomes '_'), so the first OCaml start resumes where Julia
   stopped. *)

let okchar c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
let relay_dir ~state_dir (url : string) : string = state_dir ^ "/" ^ String.map (fun c -> if okchar c then c else '_') url
let path ~state_dir url = relay_dir ~state_dir url ^ "/latest_timestamp"

let load ~state_dir (url : string) : int option =
  let p = path ~state_dir url in
  try
    let ic = open_in p in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () -> int_of_string_opt (String.trim (input_line ic)))
  with _ -> None

(* Utils.safe_save: tmp + rename *)
let save ~state_dir (url : string) (ts : int) : unit =
  let dir = relay_dir ~state_dir url in
  try
    Pushgateway.mkdir_p dir;
    let p = dir ^ "/latest_timestamp" in
    let tmp = p ^ ".tmp" in
    let oc = open_out tmp in
    Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc (string_of_int ts ^ "\n"));
    Sys.rename tmp p
  with exn -> Printf.eprintf "resume: save %s: %s\n%!" url (Printexc.to_string exn)
