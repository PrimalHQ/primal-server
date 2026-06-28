(* Focused check of the score_event_cb firing path (Phase 3): import a note, then a like to it
   from a trusted (human) pubkey, and confirm event_stats.score / score24h / score_expiry land.
   Verification is disabled so we can use synthetic (unsigned) events. *)
open Eio.Std
module Pg = Importer.Postgres
module CS = Importer.Cache_storage
module N = Importer.Nostr
module PGOCaml = Importer.Postgres.PGOCaml

let b32 c = String.make 32 c (* a distinct 32-byte id/pubkey *)

let () =
  Eio_main.run @@ fun env ->
  Switch.run @@ fun sw ->
  Pg.set_env ~net:(Eio.Stdenv.net env) ~sw;
  Importer.Cache_storage_ext.register ();
  let dbh = Pg.connect (Pg.cache_conninfo ()) in
  let est = { CS.cfg = { CS.default_config with verification_enabled = false }; dbh; mem_dbh = dbh } in
  let parent_id = b32 '\xA1' and parent_pk = b32 '\xB1' in
  let liker_pk = b32 '\xC1' in
  let now = Importer.Utils.current_time () in
  (* trust the liker so ext_is_human is true *)
  ignore [%pgsql dbh "delete from pubkey_trustrank where pubkey = $liker_pk"];
  let rank = 1.0 in
  ignore [%pgsql dbh "insert into pubkey_trustrank (pubkey, rank) values ($liker_pk, $rank) on conflict (pubkey) do update set rank = excluded.rank"];
  let parent : N.t =
    { id = parent_id; pubkey = parent_pk; created_at = now; kind = N.kind_text_note;
      tags = []; content = "hello world"; sig_ = b32 '\x00' }
  in
  let reaction : N.t =
    { id = b32 '\xA2'; pubkey = liker_pk; created_at = now; kind = N.kind_reaction;
      tags = [ [ `String "e"; `String (Importer.Hex_util.encode parent_id) ] ];
      content = "+"; sig_ = b32 '\x00' }
  in
  assert (CS.import_event est parent);
  assert (CS.import_event est reaction);
  let row =
    [%pgsql dbh "select likes, score, score24h from event_stats_1_1b380f4869 where event_id = $parent_id"]
  in
  let se = [%pgsql dbh "select count(*) from score_expiry where event_id = $parent_id"] in
  (match row with
  | (likes, score, score24h) :: _ ->
      Printf.printf "event_stats parent: likes=%Ld score=%Ld score24h=%Ld\n" likes score score24h
  | [] -> print_endline "NO event_stats row!");
  (match se with Some n :: _ -> Printf.printf "score_expiry rows: %Ld\n" n | _ -> ());
  (* cleanup so reruns are clean *)
  List.iter
    (fun q -> ignore (q ()))
    [
      (fun () -> [%pgsql dbh "delete from event where id = $parent_id"]);
      (fun () -> [%pgsql dbh "delete from event_stats_1_1b380f4869 where event_id = $parent_id"]);
      (fun () -> [%pgsql dbh "delete from score_expiry where event_id = $parent_id"]);
      (fun () -> [%pgsql dbh "delete from pubkey_trustrank where pubkey = $liker_pk"]);
    ]
