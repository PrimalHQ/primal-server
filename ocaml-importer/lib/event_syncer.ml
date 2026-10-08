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

(* Max rows per remote per pull. PGOCaml materializes the whole result, and a failed pull doesn't
   advance the high-water, so an uncapped catch-up window (e.g. after a stall) grows every cycle until
   it blows the cgroup memory limit or the remote's statement timeout. Events cost ~1.3KB each in the
   heap, so this bounds a cycle to ~250MB per remote; a backlog drains over successive cycles. *)
let pull_limit = 200_000

(* One pull from one remote: up to [pull_limit] events with imported_at >= since. Returns
   (events, high_water, full) where high_water is the largest imported_at seen (>= since), so the
   caller continues strictly forward next cycle, and [full] says the limit was hit (more is pending).
   Rows sharing the high-water second are re-read next pull and count as duplicates. Events are
   returned (not submitted) so the caller can merge all remotes and submit in created_at order. *)
let pull_remote (dbh : Pg.dbh) ~(since : int) : Nostr.t list * int * bool =
  let since64 = Int64.of_int since in
  let limit64 = Int64.of_int pull_limit in
  let rows =
    [%pgsql dbh
      "select id, pubkey, created_at, kind, tags, content, sig, imported_at from event \
       where imported_at >= $since64 order by imported_at limit $limit64"]
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
  let full = List.length rows >= pull_limit in
  (* A full pull that never left the [since] second would re-read the same rows forever; step past
     it (dropping that second's unread rows). Needs > pull_limit imports in one second, so rare. *)
  if full && !hw = since then begin
    Printf.eprintf "event_syncer: >= %d events at imported_at %d; skipping ahead\n%!" pull_limit since;
    hw := since + 1
  end;
  (evs, !hw, full)

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
    let batch = ref [] and total = ref 0 and backlog = ref false in
    List.iter
      (fun (ci, slot, last) ->
        try
          let dbh = get_conn ci slot in
          let since = !last in
          let evs, hw, full = pull_remote dbh ~since in
          if hw > !last then last := hw;
          if full then backlog := true;
          let n = List.length evs in
          if n > 0 then begin
            batch := List.rev_append evs !batch;
            total := !total + n;
            Printf.printf "event_syncer: %s +%d events (imported_at %d..%d)%s\n%!" ci.Pg.host n since
              hw
              (if full then " [limit hit, backlog]" else "")
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
    (* While some remote is behind, go again right away; submit blocks on the full worker queue, so
       catch-up is paced by the import rate rather than by [interval]. *)
    Eio.Time.sleep clock (if !backlog then 1.0 else interval)
  done

(* {1 Backfill}

   Replay one peer's event table over a past imported_at range into the import queue: the repair
   for a node that imported nothing for a while (the stage host, 2026-07-11..09-29). Keyset pagination on
   (imported_at, id) — event_imported_at_id_idx on the peer — in batches of [batch] rows, each
   batch submitted in created_at order (parents before replies, as the live syncer does); the
   bounded worker queue applies the backpressure (Eio.Stream.add blocks when it is full). The
   cursor is written to [state_file] after every batch, so a restart resumes where it stopped; the
   file holds "<imported_at> <id hex>". Finished = cursor past [to_ts]; the fiber then returns. *)

let read_state (file : string) : (int * string) option =
  try
    let ic = open_in file in
    let line = Fun.protect ~finally:(fun () -> close_in ic) (fun () -> input_line ic) in
    match String.split_on_char ' ' (String.trim line) with
    | [ t; id ] -> Some (int_of_string t, Hex_util.decode_exn id)
    | _ -> None
  with _ -> None

let write_state (file : string) (t : int) (id : string) : unit =
  let tmp = file ^ ".tmp" in
  let oc = open_out tmp in
  Fun.protect ~finally:(fun () -> close_out oc) (fun () -> Printf.fprintf oc "%d %s\n" t (Hex_util.encode id));
  Sys.rename tmp file

let backfill ~(clock : _ Eio.Time.clock) ~(remote : Pg.conninfo) ~(from_ts : int) ~(to_ts : int) ~(batch : int)
    ~(state_file : string) ~(submit : Nostr.t -> unit) ?(headroom : unit -> bool = fun () -> true) () : unit =
  let cursor_t, cursor_id =
    match read_state state_file with
    | Some (t, id) when t >= from_ts -> (ref t, ref id)
    | _ -> (ref from_ts, ref "")
  in
  let started = Unix.gettimeofday () and total = ref 0 and last_log = ref 0.0 in
  Printf.printf "backfill: %s imported_at %d..%d from (%d, %s), batch %d\n%!" remote.Pg.host from_ts to_ts !cursor_t
    (if !cursor_id = "" then "-" else Hex_util.encode !cursor_id) batch;
  let dbh = ref None in
  let conn () = match !dbh with Some d -> d | None -> let d = Pg.connect remote in dbh := Some d; d in
  let drop () = (match !dbh with Some d -> (try Pg.close d with _ -> ()) | None -> ()); dbh := None in
  let finished = ref false in
  while not !finished do
    match
      let d = conn () in
      let t = Int64.of_int !cursor_t and id = !cursor_id and lim = Int64.of_int batch and to64 = Int64.of_int to_ts in
      [%pgsql d
        "select id, pubkey, created_at, kind, tags, content, sig, imported_at from event \
         where (imported_at, id) > ($t, $id) and imported_at < $to64 order by imported_at, id limit $lim"]
    with
    | exception (Eio.Cancel.Cancelled _ as e) -> raise e
    | exception exn ->
        Printf.eprintf "backfill: %s: %s (retry in 30 s)\n%!" remote.Pg.host (Printexc.to_string exn);
        drop ();
        Eio.Time.sleep clock 30.0
    | [] ->
        finished := true;
        write_state state_file to_ts "";
        Printf.printf "backfill: done, %d events in %.0f s\n%!" !total (Unix.gettimeofday () -. started)
    | rows ->
        let last_t = ref !cursor_t and last_id = ref !cursor_id in
        let evs =
          List.map
            (fun (id, pubkey, created_at, kind, tags, content, sig_, imported_at) ->
              let ia = Int64.to_int imported_at in
              if ia > !last_t || (ia = !last_t && id > !last_id) then (last_t := ia; last_id := id);
              event_of_row ~id ~pubkey ~created_at ~kind ~tags ~content ~sig_)
            rows
        in
        (* the live firehose and the regular syncer share the bounded queue: a backfill that keeps it full
           starves them (the stage host received no live events for 25 h on 2026-10-06), so wait until the
           queue has room before each batch *)
        while not (headroom ()) do Eio.Time.sleep clock 0.2 done;
        List.sort (fun (a : Nostr.t) (b : Nostr.t) -> Int.compare a.created_at b.created_at) evs |> List.iter submit;
        total := !total + List.length evs;
        cursor_t := !last_t;
        cursor_id := !last_id;
        write_state state_file !cursor_t !cursor_id;
        let now = Unix.gettimeofday () in
        if now -. !last_log >= 60.0 then begin
          last_log := now;
          let el = now -. started in
          let rate = float_of_int !total /. el in
          let span = float_of_int (to_ts - from_ts) and done_ = float_of_int (!cursor_t - from_ts) in
          Printf.printf "backfill: at imported_at %d (%.1f%% of range), %d events, %.0f/s, %.1f h elapsed\n%!" !cursor_t
            (100.0 *. done_ /. span) !total rate (el /. 3600.)
        end
  done;
  drop ()
