(* Focused checks for the Phase-8 additions: filterlist write(membership)->read(local) roundtrip,
   and the scheduled-hooks runner firing expire_hashtag_score_cb. Uses one DB for both roles. *)
open Eio.Std
module Pg = Importer.Postgres
module CS = Importer.Cache_storage
module FL = Importer.Filterlist
module N = Importer.Nostr
module PGOCaml = Importer.Postgres.PGOCaml

let b32 c = String.make 32 c

let () =
  Eio_main.run @@ fun env ->
  Switch.run @@ fun sw ->
  Pg.set_env ~net:(Eio.Stdenv.net env) ~sw;
  Importer.Cache_storage_ext.register ();
  let dbh = Pg.connect (Pg.cache_conninfo ()) in
  let est = { CS.cfg = CS.default_config; dbh; mem_dbh = dbh } in
  let pk = b32 '\xD1' and eid = b32 '\xD2' in
  ignore [%pgsql dbh "delete from filterlist where target = $pk or target = $eid"];

  (* filterlist write (membership) -> read (local) *)
  FL.block_pubkey_spam ~mem_dbh:est.mem_dbh pk ~comment:"phase8check";
  FL.block_event_spam ~mem_dbh:est.mem_dbh eid ~comment:"phase8check";
  Printf.printf "pubkey_blocked_spam=%b import_blocked=%b unblocked=%b event_blocked_spam=%b\n"
    (FL.is_pubkey_blocked_spam dbh pk) (FL.is_import_pubkey_blocked dbh pk)
    (FL.is_pubkey_unblocked dbh pk) (FL.is_event_blocked_spam dbh eid);

  (* scheduled hook: a due expire_hashtag_score_cb decrements the hashtag score *)
  let ht = "phase8tag" in
  ignore [%pgsql dbh "delete from hashtags_1_1e5c72161a where hashtag = $ht"];
  ignore [%pgsql dbh "insert into hashtags_1_1e5c72161a (hashtag, score) values ($ht, 5)"];
  let past = Int64.of_int (Importer.Utils.current_time () - 10) in
  let funcall = {|["expire_hashtag_score_cb","phase8tag",2]|} in
  ignore [%pgsql dbh "insert into scheduled_hooks (execute_at, funcall) values ($past, $funcall)"];
  ignore (CS.run_scheduled_hooks est : int);
  let score = match [%pgsql dbh "select score from hashtags_1_1e5c72161a where hashtag = $ht"] with s :: _ -> s | [] -> -1L in
  let remaining = match [%pgsql dbh "select count(*) from scheduled_hooks where funcall = $funcall"] with Some n :: _ -> n | _ -> -1L in
  Printf.printf "hashtag score after expiry=%Ld (expect 3), due hooks remaining=%Ld (expect 0)\n" score remaining;

  (* import_reporting: a whitelisted reporter's kind-1984 blocks the reported pubkey/event *)
  let reporter = b32 '\xE1' and tpk = b32 '\xE2' and teid = b32 '\xE3' and rid = b32 '\xE4' in
  ignore [%pgsql dbh "delete from filterlist where target = $tpk or target = $teid"];
  let rep_est =
    { est with CS.cfg = { CS.default_config with verification_enabled = false; import_reporting = true; reporting_whitelist = [ reporter ] } }
  in
  let report : N.t =
    { id = rid; pubkey = reporter; created_at = Importer.Utils.current_time (); kind = N.kind_reporting;
      tags =
        [ [ `String "p"; `String (Importer.Hex_util.encode tpk); `String "spam" ];
          [ `String "e"; `String (Importer.Hex_util.encode teid); `String "impersonation" ] ];
      content = "report"; sig_ = b32 '\x00' }
  in
  ignore (CS.import_event rep_est report);
  let n_pk =
    match [%pgsql dbh "select count(*) from filterlist where target = $tpk and target_type = 'pubkey' and grp = 'spam' and blocked"] with Some n :: _ -> n | _ -> 0L
  in
  let n_ev =
    match [%pgsql dbh "select count(*) from filterlist where target = $teid and target_type = 'event' and grp = 'impersonation' and blocked"] with Some n :: _ -> n | _ -> 0L
  in
  Printf.printf "reporting: blocked pubkey rows=%Ld (expect 1), blocked event rows=%Ld (expect 1)\n" n_pk n_ev;

  (* cleanup *)
  ignore [%pgsql dbh "delete from filterlist where target = $pk or target = $eid or target = $tpk or target = $teid"];
  ignore [%pgsql dbh "delete from hashtags_1_1e5c72161a where hashtag = $ht"];
  ignore [%pgsql dbh "delete from scheduled_hooks where funcall = $funcall"];
  ignore [%pgsql dbh "delete from event where id = $rid"];
  ignore [%pgsql dbh "delete from pubkey_ids_1_54b55dd09c where key = $reporter"];
  ignore [%pgsql dbh "delete from pubkey_zapped_1_17f1f622a9 where pubkey = $reporter"]
