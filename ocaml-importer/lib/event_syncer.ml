(* Event syncer, mirroring the role of Julia's EventSyncer (relocated to its own process per the
   plan). On a timer it reads the most recent rows from each peer node's `event` table and feeds
   them into the local import queue, so events any single node missed off the firehose still land
   locally.

   Each cycle the lower bound is min(now, local-max-created_at) - overlap (default 10 min): a fixed
   lookback behind the newest event we already hold. Re-importing already-seen events is cheap and
   safe — store_event is an atomic ON CONFLICT claim, so re-sent events just count as duplicates —
   which makes the sync self-healing across restarts and firehose gaps. The window query is backed
   by event(created_at) (event_created_at_idx), so it is an index scan, not a table scan.

   Runs as a fiber on the main domain (where the Postgres Eio env is set); pushed events go onto
   the shared cross-domain worker queue via [submit]. *)

open Eio.Std
module CS = Cache_storage
module Pg = Postgres
module PGOCaml = Postgres.PGOCaml

(* min(now, local max created_at) - overlap (all seconds). Empty local table -> now - overlap. *)
let since_floor (local_dbh : Pg.dbh) ~(overlap : int) : int =
  let now = Utils.current_time () in
  let local_max =
    match [%pgsql local_dbh "select max(created_at) from event"] with
    | Some m :: _ -> Int64.to_int m
    | _ -> now
  in
  min now local_max - overlap

let event_of_row ~id ~pubkey ~created_at ~kind ~tags ~content ~sig_ : Nostr.t =
  {
    Nostr.id;
    pubkey;
    created_at = Int64.to_int created_at;
    kind = Int64.to_int kind;
    tags = CS.parse_tags_json tags;
    content;
    sig_;
  }

(* One pull from one remote: stream events with created_at >= since to [submit]; returns the count.
   [submit] blocks under queue backpressure, throttling the pull to the workers' import rate. *)
let pull_remote (dbh : Pg.dbh) ~(since : int) ~(submit : Nostr.t -> unit) : int =
  let since = Int64.of_int since in
  let rows =
    [%pgsql dbh
      "select id, pubkey, created_at, kind, tags, content, sig from event where created_at >= \
       $since order by created_at"]
  in
  List.iter
    (fun (id, pubkey, created_at, kind, tags, content, sig_) ->
      submit (event_of_row ~id ~pubkey ~created_at ~kind ~tags ~content ~sig_))
    rows;
  List.length rows

(* Loop forever (intended as a fiber). The syncer owns ALL its connections — a dedicated [local]
   handle for the max-created_at read plus one per remote — and never shares them with other fibers:
   a PGOCaml connection is single-threaded, so two fibers issuing queries on the same handle would
   corrupt the wire protocol. Each handle is lazily (re)connected and dropped on error, and the
   whole cycle is guarded so a transient DB failure just skips the cycle rather than killing the
   fiber. *)
let run ~(clock : _ Eio.Time.clock) ~(local : Pg.conninfo) ~(remotes : Pg.conninfo list)
    ~(submit : Nostr.t -> unit) ~(interval : float) ~(overlap : int) () : unit =
  let local_slot = ref None in
  let conns = List.map (fun ci -> (ci, ref None)) remotes in
  let get_conn ci slot =
    match !slot with
    | Some dbh -> dbh
    | None ->
        let dbh = Pg.connect ci in
        slot := Some dbh;
        dbh
  in
  let drop slot =
    (match !slot with Some dbh -> ( try Pg.close dbh with _ -> ()) | None -> ());
    slot := None
  in
  Printf.printf "event_syncer: %d remotes, interval %.0fs, overlap %ds\n%!" (List.length remotes)
    interval overlap;
  while true do
    (try
       let since = since_floor (get_conn local local_slot) ~overlap in
       List.iter
         (fun (ci, slot) ->
           try
             let dbh = get_conn ci slot in
             let n = pull_remote dbh ~since ~submit in
             if n > 0 then Printf.printf "event_syncer: %s +%d events (since %d)\n%!" ci.Pg.host n since
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
               Printf.eprintf "event_syncer: %s: %s\n%!" ci.Pg.host (Printexc.to_string exn);
               drop slot)
         conns
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
         Printf.eprintf "event_syncer: cycle: %s\n%!" (Printexc.to_string exn);
         drop local_slot);
    Eio.Time.sleep clock interval
  done
