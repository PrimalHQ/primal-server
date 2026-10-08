(* The relay set: fetching.jl load_relays (relays-active.txt verbatim; relays.txt, relays-paid.txt,
   relays-mined-from-events.txt, relays-mined-from-contact-lists.txt sanitised), the extra relays
   of start_fetcher.jl, and start_relays_from_db's 1 s poll of fetcher_relays (updated_at since the
   previous poll; urls over 300 chars, unparsable, or on private IPv4 ranges skipped). New urls
   are handed to a domain by hash; a Relay_conn starts from the relay's resume file or
   fetcher_since. *)

open Eio.Std

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [relays] %s\n%!" (Procinfo.timestamp ()) s) fmt

let read_lines (path : string) : string list =
  try
    let ic = open_in path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
        let rec go acc = match input_line ic with l -> go (l :: acc) | exception End_of_file -> List.rev acc in
        go [])
  with Sys_error m -> log "%s" m; []

let load_files ~(cfg : Config.t) : string list =
  let urls =
    match cfg.relays_file with
    | Some f -> List.filter (fun l -> l <> "") (read_lines f)
    | None ->
        let active = read_lines (cfg.relays_dir ^ "/relays-active.txt") in
        let others = List.concat_map (fun fn -> read_lines (cfg.relays_dir ^ "/" ^ fn)) [ "relays.txt"; "relays-paid.txt"; "relays-mined-from-events.txt"; "relays-mined-from-contact-lists.txt" ] in
        active @ List.filter_map Relay_url.sanitize_valid others
  in
  let seen = Hashtbl.create 1024 in
  List.filter (fun u -> if Hashtbl.mem seen u then false else (Hashtbl.replace seen u (); true)) (urls @ cfg.extra_relays)

(* [known] is keyed by the sanitised url (Relay_url.sanitize_valid; the raw string when it does
   not sanitise), so "wss://x/" and "wss://x" are one relay; the first spelling seen is the one
   connected (and names the resume file). [paths] counts the accepted non-root variants per host
   for cfg.max_paths_per_host: the mined lists carry hundreds of per-user paths of one relay host
   (haven inboxes, prisms, random suffixes), each a full duplicate stream. *)
type t = {
  cfg : Config.t;
  stats : Stats.t;
  mu : Mutex.t;
  known : (string, Relay_conn.t) Hashtbl.t;
  paths : (string, int) Hashtbl.t;
  domains : Relay_conn.t Eio.Stream.t array;
}

let create ~cfg ~stats ~(domains : Relay_conn.t Eio.Stream.t array) =
  { cfg; stats; mu = Mutex.create (); known = Hashtbl.create 8192; paths = Hashtbl.create 4096; domains }

let default_since (cfg : Config.t) = match cfg.fetcher_since with Some s -> s | None -> Utils.current_time ()

(* update_fetchers!: start a fetcher for every url not yet known (and within the per-host cap) *)
let add (t : t) (urls : string list) : int =
  let added = ref 0 in
  List.iter
    (fun url ->
      let key = match Relay_url.sanitize_valid url with Some k -> k | None -> url in
      let host, root = Relay_url.host_key url in
      let admit =
        Mutex.protect t.mu (fun () ->
            if Hashtbl.mem t.known key then false
            else if root || t.cfg.max_paths_per_host < 0 then true
            else begin
              let n = Option.value (Hashtbl.find_opt t.paths host) ~default:0 in
              if n < t.cfg.max_paths_per_host then (Hashtbl.replace t.paths host (n + 1); true)
              else (Stats.incr t.stats.relays_capped; false)
            end)
      in
      if admit then begin
        let since = match Resume.load ~state_dir:t.cfg.state_dir url with Some s -> s | None -> default_since t.cfg in
        let c = Relay_conn.create ~cfg:t.cfg ~since url in
        Mutex.protect t.mu (fun () -> Hashtbl.replace t.known key c);
        Stats.incr t.stats.relays_total;
        incr added;
        let d = Hashtbl.hash url mod Array.length t.domains in
        Eio.Stream.add t.domains.(d) c
      end)
    urls;
  !added

let conns (t : t) : Relay_conn.t list = Mutex.protect t.mu (fun () -> Hashtbl.fold (fun _ c acc -> c :: acc) t.known [])

(* start_relays_from_db / monitor_relays_from_db *)
let db_poller (t : t) ~clock ~(stop : unit Promise.t) : unit =
  match t.cfg.cache_db with
  | None -> log "cache_db not set; fetcher_relays polling disabled"
  | Some ci ->
      let updated_at = ref 0 in
      let dbh = ref None in
      let get_dbh () = match !dbh with Some d -> d | None -> let d = Postgres.connect ~statement_timeout_ms:30_000 ~application_name:"primal-fetcher" ci in dbh := Some d; d in
      let rec loop () =
        if not (Promise.is_resolved stop) then begin
          (try
             let now = Utils.current_time () in
             let ts = let tm = Unix.gmtime (float_of_int !updated_at) in Printf.sprintf "%d-%02d-%02d %02d:%02d:%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec in
             let rows = Postgres.query (get_dbh ()) "select relay_url from fetcher_relays where updated_at >= $1" [ Some ts ] in
             let urls =
               List.filter_map
                 (function
                   | [ Some url ] when String.length url <= 300 -> (
                       match Relay_url.parse url with
                       | Some p when not (Relay_url.private_ipv4_host p.Relay_url.host) -> Some url
                       | Some _ -> None
                       | None -> None)
                   | _ -> None)
                 rows
             in
             updated_at := now;
             let n = add t urls in
             if n > 0 then log "fetcher_relays: %d new relays (%d rows)" n (List.length rows)
           with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
              log "fetcher_relays: %s" (Printexc.to_string exn);
              (match !dbh with Some d -> (try Postgres.close d with _ -> ()); dbh := None | None -> ()));
          match Fiber.first (fun () -> Promise.await stop; `Stop) (fun () -> Eio.Time.sleep clock t.cfg.relays_db_poll_s; `Tick) with `Stop -> () | `Tick -> loop ()
        end
      in
      loop ()
