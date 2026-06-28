(* Verification tool (plan milestone 6): diff recent rows in the importer's relevant tables
   between the LOCAL Postgres (this host's OCaml importer) and a REMOTE one (the Julia importer,
   default 192.168.44.7, same port/credentials/dbname — override host with COMPARE_HOST).

   Both importers consume the same firehose, so recent rows should match closely; larger diffs
   flag bugs to fix. We window on the event's created_at (intrinsic and identical across both,
   unlike imported_at) and skip the leading [margin] seconds where one importer may still be
   catching up.

   Usage: compare [window_seconds=3600] [margin_seconds=60]
   Score / score24h are intentionally NOT compared (time-decayed, expected to differ). *)

open Eio.Std
module Pg = Importer.Postgres
module PGOCaml = Importer.Postgres.PGOCaml

let hx = Importer.Hex_util.encode
let i64 = Int64.of_int

module SM = Map.Make (String)

(* Compare two (key, value) row sets; print counts and a few sample differences. *)
let report (label : string) (lp : (string * string) list) (rp : (string * string) list) : unit =
  let lm = SM.of_seq (List.to_seq lp) and rm = SM.of_seq (List.to_seq rp) in
  let only_local = ref 0 and only_remote = ref 0 and mism = ref 0 in
  let samples = ref [] in
  let add_sample s = if List.length !samples < 3 then samples := s :: !samples in
  SM.iter
    (fun k v ->
      match SM.find_opt k rm with
      | None ->
          incr only_local;
          add_sample (Printf.sprintf "only-local  %s" k)
      | Some v2 ->
          if v <> v2 then begin
            incr mism;
            add_sample (Printf.sprintf "mismatch    %s : L=[%s] R=[%s]" k v v2)
          end)
    lm;
  SM.iter
    (fun k _ ->
      if not (SM.mem k lm) then begin
        incr only_remote;
        add_sample (Printf.sprintf "only-remote %s" k)
      end)
    rm;
  Printf.printf "%-34s local=%-6d remote=%-6d  only_local=%-5d only_remote=%-5d mismatch=%d\n%!"
    label (SM.cardinal lm) (SM.cardinal rm) !only_local !only_remote !mism;
  List.iter (fun s -> Printf.printf "      %s\n%!" s) (List.rev !samples)

(* {1 Per-table row extractors -> (key, value) pairs} *)

let events dbh ~since ~until =
  List.map (fun id -> (hx id, ""))
    [%pgsql dbh "select id from event where created_at > $since and created_at < $until"]

let event_stats dbh ~since ~until =
  List.map
    (fun (eid, likes, replies, mentions, reposts, zaps, satszapped) ->
      (hx eid, Printf.sprintf "%Ld/%Ld/%Ld/%Ld/%Ld/%Ld" likes replies mentions reposts zaps satszapped))
    [%pgsql dbh
      "select event_id, likes, replies, mentions, reposts, zaps, satszapped from event_stats_1_1b380f4869 \
       where created_at > $since and created_at < $until"]

let pubkey_events dbh ~since ~until =
  List.map
    (fun (pk, eid, is_reply) -> (hx pk ^ "|" ^ hx eid, Int64.to_string is_reply))
    [%pgsql dbh
      "select pubkey, event_id, is_reply from pubkey_events_1_1dcbfe1466 where created_at > $since and created_at < $until"]

let event_replies dbh ~since ~until =
  List.map
    (fun (eid, reid) -> (hx eid ^ "|" ^ hx reid, ""))
    [%pgsql dbh
      "select event_id, reply_event_id from event_replies_1_9d033b5bb3 where reply_created_at > $since and reply_created_at < $until"]

let event_pubkey_actions dbh ~since ~until =
  List.map
    (fun (eid, pk, replied, liked, reposted, zapped) ->
      (hx eid ^ "|" ^ hx pk, Printf.sprintf "%Ld%Ld%Ld%Ld" replied liked reposted zapped))
    [%pgsql dbh
      "select event_id, pubkey, replied, liked, reposted, zapped from event_pubkey_actions_1_d62afee35d \
       where created_at > $since and created_at < $until"]

let meta_data dbh ~since ~until =
  List.map
    (fun (k, v) -> (hx k, hx v))
    [%pgsql dbh
      "select m.key, m.value from meta_data_1_323bc43167 m, event e where e.id = m.value and e.created_at > $since and e.created_at < $until"]

let contact_lists dbh ~since ~until =
  List.map
    (fun (k, v) -> (hx k, hx v))
    [%pgsql dbh
      "select c.key, c.value from contact_lists_1_1abdf474bd c, event e where e.id = c.value and e.created_at > $since and e.created_at < $until"]

let og_zap_receipts dbh ~since ~until =
  List.map
    (fun (zid, amount, eid) -> (hx zid, Printf.sprintf "%Ld|%s" amount (hx eid)))
    [%pgsql dbh
      "select zap_receipt_id, amount_sats, event_id from og_zap_receipts_1_dc85307383 where created_at > $since and created_at < $until"]

let parametrized_replaceable_events dbh ~since ~until =
  List.map
    (fun (pk, kind, ident, eid) -> (hx pk ^ "|" ^ Int64.to_string kind ^ "|" ^ ident, hx eid))
    [%pgsql dbh
      "select pubkey, kind, identifier, event_id from parametrized_replaceable_events_1_cbe75c8d53 \
       where created_at > $since and created_at < $until"]

let () =
  let arg n d = if Array.length Sys.argv > n then int_of_string Sys.argv.(n) else d in
  let window = arg 1 3600 and margin = arg 2 60 in
  Eio_main.run @@ fun env ->
  Switch.run @@ fun sw ->
  Pg.set_env ~net:(Eio.Stdenv.net env) ~sw;
  let now = Importer.Utils.current_time () in
  let since = i64 (now - window) and until = i64 (now - margin) in
  let lci = Pg.cache_conninfo () and rci = Pg.remote_conninfo () in
  Printf.printf "comparing created_at in [now-%ds, now-%ds]\n  local  = %s:%d/%s\n  remote = %s:%d/%s\n\n%!"
    window margin lci.host lci.port lci.database rci.host rci.port rci.database;
  let local = Pg.connect lci in
  let remote =
    try Pg.connect rci
    with exn ->
      Printf.eprintf "cannot connect to remote %s: %s\n%!" rci.host (Printexc.to_string exn);
      exit 1
  in
  let cmp label f = report label (f local ~since ~until) (f remote ~since ~until) in
  cmp "events" events;
  cmp "event_stats(likes..satszapped)" event_stats;
  cmp "pubkey_events" pubkey_events;
  cmp "event_replies" event_replies;
  cmp "event_pubkey_actions" event_pubkey_actions;
  cmp "meta_data" meta_data;
  cmp "contact_lists" contact_lists;
  cmp "og_zap_receipts" og_zap_receipts;
  cmp "parametrized_replaceable_events" parametrized_replaceable_events;
  Pg.close local;
  Pg.close remote
