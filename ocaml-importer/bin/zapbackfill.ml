(* Dev tool: re-run zap-receipt processing for a past imported_at window.

   During the 2026-07-15 fd-exhaustion incident (see lib/postgres.ml open_connection) kind-9735
   events were still imported into [event], but every LNURL zapper verification failed with
   EMFILE, so none of their import effects were applied: no og_zap_receipts rows, no event_stats
   satszapped/zaps, no pubkey_zapped, no YOUR_POST_WAS_ZAPPED notifications. This tool replays
   exactly the import path (CS.handle_zap_receipt with the ext hooks registered and a synchronous
   cached LNURL verifier) over the receipts imported in the window.

   Deduplication: a receipt whose id already exists in og_zap_receipts is skipped, so re-running
   the tool (or overlapping the window with live processing) cannot double-apply EVENT zaps.
   Pubkey-only zaps (no 'e' tag) leave no such marker, so they are replayed unconditionally —
   keep the window inside the known-broken interval to avoid double-counting pubkey_zapped, or
   pass -e to skip them entirely.

   Usage: zapbackfill.exe <pg-host-ip> <from-epoch> <to-epoch> [-n] [-e]
     <pg-host-ip>  cache-DB host to read events from and write effects to (port/user/database
                   come from the PG* env vars, like the other dev tools; the membership DB uses
                   PGMEMBERSHIP* as usual and is NOT redirected to this host)
     -n            dry run: only report what would be processed
     -e            only replay receipts whose applied/not-applied state og_zap_receipts can
                   actually decide, i.e. those with an 'e' tag AND a human sender. Use this for a
                   wide window over a period of ordinary verification losses (rather than one
                   bounded outage), where most receipts were applied correctly and replaying them
                   would double-count.

                   Both conditions matter, because import_zap_receipt (the only thing that writes
                   the marker) sits inside ext_zap's `if ext_is_human sender` branch, while
                   apply_zap_effects bumps event_stats.zaps and event_pubkey_actions.zapped
                   *outside* it. So for a pubkey-only or non-human-sender receipt the marker is
                   absent whether or not the zap was already applied, and replaying it
                   double-counts those unconditional effects. Their loss when verification failed
                   is a zap count, not sats: satszapped, og_zap_receipts, pubkey_zapped and the
                   YOUR_POST_WAS_ZAPPED notification are all inside the human branch.

   Note: the inline SQL targets primal1's version-hashed table names, so point this only at
   primal1 (or a clone with the same schema). *)
open Eio.Std
module Pg = Importer.Postgres
module PGOCaml = Importer.Postgres.PGOCaml
module CS = Importer.Cache_storage
module N = Importer.Nostr
module Cfg = Importer.Config

let usage () =
  Printf.eprintf "usage: %s <pg-host-ip> <from-epoch> <to-epoch> [-n] [-e]\n%!" Sys.argv.(0)

let () =
  let host, t_from, t_to, flags =
    match Array.to_list Sys.argv with
    | _ :: h :: f :: t :: flags when List.for_all (fun s -> s = "-n" || s = "-e") flags -> (
        match (int_of_string_opt f, int_of_string_opt t) with
        | Some f, Some t -> (h, f, t, flags)
        | _ ->
            usage ();
            exit 2)
    | _ ->
        usage ();
        exit 2
  in
  let dry_run = List.mem "-n" flags and e_only = List.mem "-e" flags in
  Printexc.record_backtrace true;
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  Pg.set_env ~net ~sw;
  let cfg = Cfg.from_env () in
  let proxy = Cfg.proxy_endpoint cfg in
  Importer.Cache_storage_ext.register ();
  let dbh = Pg.connect { cfg.cache_db with Pg.host } in
  let mem_dbh = Pg.connect cfg.membership_db in
  let est = { CS.cfg = cfg.cs; dbh; mem_dbh } in
  (* Same serving-layer initialisation as bin/main.ml, so notification gating and the
     sender-humanness check behave exactly as they would have during live import. *)
  Importer.Cache_storage_ext.set_humaness_override cfg.humaness_threshold;
  ignore (Importer.Cache_storage_ext.load_humaness_threshold est);
  let gating = Importer.Cache_storage_ext.init_notification_gating est in
  Printf.printf "zapbackfill: db %s:%d/%s, window %d..%d%s, notification gates %s\n%!" host
    cfg.cache_db.Pg.port cfg.cache_db.Pg.database t_from t_to
    (if dry_run then " (DRY RUN)" else "")
    (if gating then "ON" else "OFF");
  (* Synchronous LNURL verifier with a url -> advertised-nostrPubkey cache (most zaps go to a
     few popular users). CS.handle_zap_receipt falls back to this because no Zap_verifier pool
     is wired in this tool. *)
  let url_cache : (string, string option) Hashtbl.t = Hashtbl.create 1024 in
  let fetches = ref 0 in
  CS.set_zapper_verifier (fun est ~zapped_pk ~zap_receipt ->
      match Importer.Lnurl.endpoint_url est ~zapped_pk with
      | None -> false
      | Some u -> (
          let url =
            Printf.sprintf "https://%s:%d%s" u.Importer.Http.host u.Importer.Http.port
              u.Importer.Http.path
          in
          let advertised =
            match Hashtbl.find_opt url_cache url with
            | Some v -> v
            | None ->
                incr fetches;
                let v =
                  match Importer.Lnurl.timed_get ~net ~clock ?proxy u with
                  | None -> None
                  | Some body -> Importer.Lnurl.extract_nostr_pubkey body
                in
                Hashtbl.replace url_cache url v;
                v
          in
          match advertised with
          | Some pk -> pk = zap_receipt.N.pubkey
          | None -> false));
  let f64 = Int64.of_int t_from and t64 = Int64.of_int t_to in
  let rows =
    [%pgsql dbh
        "select id, pubkey, created_at, kind, tags, content, sig from event \
         where kind = 9735 and imported_at >= $f64 and imported_at <= $t64 order by created_at"]
  in
  Printf.printf "zapbackfill: %d zap receipts in window\n%!" (List.length rows);
  let total = ref 0 and skipped = ref 0 and replayed = ref 0 and pubkey_only = ref 0
  and undecidable = ref 0 and errors = ref 0 in
  List.iter
    (fun (id, pubkey, created_at, kind, tags, content, sig_) ->
      incr total;
      match
        [%pgsql dbh
            "select zap_receipt_id from og_zap_receipts_1_dc85307383 where zap_receipt_id = $id \
             limit 1"]
      with
      | _ :: _ -> incr skipped (* effects already applied (live import or a previous run) *)
      | [] ->
          let e =
            {
              N.id;
              pubkey;
              created_at = Int64.to_int created_at;
              kind = Int64.to_int kind;
              tags = CS.parse_tags_json tags;
              content;
              sig_;
            }
          in
          let has_e = List.exists (fun tg -> N.tag_name tg = Some "e") e.N.tags in
          if not has_e then incr pubkey_only;
          (* Undecidable = the og_zap_receipts marker would have been absent even on a successful
             import, so its absence proves nothing and replaying may double-count. See the -e
             note at the top. *)
          let decidable =
            has_e
            && match CS.zap_sender e with
               | Some sender -> Importer.Cache_storage_ext.ext_is_human est sender
               | None -> false
          in
          if not decidable then incr undecidable;
          if (not decidable) && e_only then ()
          else if dry_run then incr replayed
          else begin
            (try
               CS.handle_zap_receipt est e;
               incr replayed
             with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn ->
                incr errors;
                (* Backtrace too: a PGOCaml error only carries the server message, so without
                   the raising frame there is no way to tell which of the dozen statements in
                   the apply path produced it. *)
                Printf.eprintf "zapbackfill: %s: %s\n%s%!" (Importer.Hex_util.encode id)
                  (Printexc.to_string exn) (Printexc.get_backtrace ()));
            if !total mod 100 = 0 then
              Printf.printf "zapbackfill: %d/%d done (%d replayed, %d already applied, %d fetches)\n%!"
                !total (List.length rows) !replayed !skipped !fetches
          end)
    rows;
  Printf.printf
    "zapbackfill: done. total %d, %s %d, no marker %d (of which pubkey-only %d) %s, already \
     applied %d, errors %d, lnurl fetches %d (%d urls cached)\n%!"
    !total
    (if dry_run then "would replay" else "replayed")
    !replayed !undecidable !pubkey_only
    (if e_only then "-> skipped (-e)" else "-> replayed")
    !skipped !errors !fetches (Hashtbl.length url_cache)
