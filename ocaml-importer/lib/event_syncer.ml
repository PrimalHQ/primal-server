(* Event syncer, mirroring the role of Julia's EventSyncer (relocated to its own process per the
   plan). On a timer it reads recently-imported rows from each peer node's `event` table and feeds
   them into the local import queue, so events any single node missed off the firehose still land
   locally.

   It tails by imported_at (each node's local insert time), statefully: the FIRST lower bound is
   min(now, max(imported_at) in the local event table) - overlap (default 10 min), and thereafter
   each remote continues from the highest imported_at it has yielded so far (an in-memory high-water
   mark that survives reconnects). So each cycle pulls only what the remote imported since last time,
   not the whole window — unlike a fixed created_at lookback, there is no per-cycle re-scan.

   Re-importing an already-seen event is cheap and safe (store_event is an atomic ON CONFLICT claim,
   so it just counts as a duplicate), so the overlap/boundary re-reads are harmless and make the
   sync self-healing across restarts and gaps. The window query is backed by event(imported_at)
   (event_imported_at), so it is an index range scan, not a table scan.

   Each cycle's events from all remotes are merged and submitted to the worker queue ordered by
   created_at asc, so parents land before their replies. Runs as a fiber on the main domain (where
   the Postgres Eio env is set); pushed events go onto the shared cross-domain worker queue via
   [submit]. The syncer owns all its connections and never shares a handle with another fiber (a
   PGOCaml connection is single-threaded). *)

open Eio.Std
module CS = Cache_storage
module Pg = Postgres
module PGOCaml = Postgres.PGOCaml

(* Initial lower bound (seconds): min(now, max(imported_at) in the local event table) - overlap.
   Empty local table -> now - overlap. Used once at startup; thereafter each remote advances by its
   own high-water mark. *)
let initial_floor (local_dbh : Pg.dbh) ~(overlap : int) : int =
  let now = Utils.current_time () in
  let local_max =
    match [%pgsql local_dbh "select max(imported_at) from event"] with
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

(* One pull from one remote: events with imported_at >= since. Returns (events, high_water) where
   high_water is the largest imported_at seen (>= since), so the caller continues strictly forward
   next cycle. Events are returned (not submitted) so the caller can merge all remotes and submit in
   created_at order. *)
let pull_remote (dbh : Pg.dbh) ~(since : int) : Nostr.t list * int =
  let since64 = Int64.of_int since in
  let rows =
    [%pgsql dbh
      "select id, pubkey, created_at, kind, tags, content, sig, imported_at from event \
       where imported_at >= $since64 order by imported_at"]
  in
  let hw = ref since in
  let evs =
    List.map
      (fun (id, pubkey, created_at, kind, tags, content, sig_, imported_at) ->
        let ia = Int64.to_int imported_at in
        if ia > !hw then hw := ia;
        event_of_row ~id ~pubkey ~created_at ~kind ~tags ~content ~sig_)
      rows
  in
  (evs, !hw)

(* Loop forever (intended as a fiber). Per-remote state = a lazily-(re)connected handle plus a
   high-water imported_at; both are kept across cycles, and the high-water survives a reconnect
   (only the connection slot is dropped on error). The whole cycle per remote is guarded so a
   transient DB failure just skips that remote rather than killing the fiber. *)
let run ~(clock : _ Eio.Time.clock) ~(local : Pg.conninfo) ~(remotes : Pg.conninfo list)
    ~(submit : Nostr.t -> unit) ~(interval : float) ~(overlap : int) () : unit =
  (* Compute the initial floor once from the local event table (guarded; falls back to now-overlap). *)
  let floor =
    try
      let dbh = Pg.connect local in
      Fun.protect
        ~finally:(fun () -> try Pg.close dbh with _ -> ())
        (fun () -> initial_floor dbh ~overlap)
    with exn ->
      Printf.eprintf "event_syncer: initial floor: %s\n%!" (Printexc.to_string exn);
      Utils.current_time () - overlap
  in
  let conns = List.map (fun ci -> (ci, ref None, ref floor)) remotes in
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
  Printf.printf "event_syncer: %d remotes, interval %.0fs, overlap %ds, start imported_at >= %d\n%!"
    (List.length remotes) interval overlap floor;
  while true do
    (* Pull each remote's new events (advancing its per-remote high-water), accumulate the whole
       cycle's batch, then submit ordered by created_at asc — so a parent is enqueued before its
       replies (created_at(reply) >= created_at(parent)), which lets reply/mention notifications and
       the deferred event_stats hooks resolve on first import instead of waiting for a later event. *)
    let batch = ref [] and total = ref 0 in
    List.iter
      (fun (ci, slot, last) ->
        try
          let dbh = get_conn ci slot in
          let since = !last in
          let evs, hw = pull_remote dbh ~since in
          if hw > !last then last := hw;
          let n = List.length evs in
          if n > 0 then begin
            batch := List.rev_append evs !batch;
            total := !total + n;
            Printf.printf "event_syncer: %s +%d events (imported_at %d..%d)\n%!" ci.Pg.host n since hw
          end
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
            Printf.eprintf "event_syncer: %s: %s\n%!" ci.Pg.host (Printexc.to_string exn);
            drop slot)
      conns;
    if !total > 0 then
      !batch
      |> List.sort (fun (a : Nostr.t) (b : Nostr.t) -> Int.compare a.created_at b.created_at)
      |> List.iter submit;
    Eio.Time.sleep clock interval
  done
