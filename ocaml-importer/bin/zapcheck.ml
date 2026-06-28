(* Dev tool: exercise LNURL zapper verification (Lnurl.verify) against real zap receipts, to
   confirm the SOCKS5 + TLS + HTTP egress path actually works on a networked host.

   Point PG* at a DB that holds metadata + kind-9735 events (e.g. the Julia importer's:
     PGHOST=192.168.44.7 PGDATABASE=primal1), and set PRIMALSERVER_PROXY to the same SOCKS5 proxy
   the Julia importer uses. For each recent zap receipt we take the receipt author as the expected
   LNURL nostrPubkey and the receipt's `p` tag as the zapped user, look up that user's lnurl-pay
   endpoint, fetch it, and check the advertised nostrPubkey matches — exactly Lnurl.verify. *)
open Eio.Std
module Pg = Importer.Postgres
module PGOCaml = Importer.Postgres.PGOCaml
module CS = Importer.Cache_storage
module Cfg = Importer.Config

let hx = Importer.Hex_util.encode

let () =
  let limit = if Array.length Sys.argv > 1 then int_of_string Sys.argv.(1) else 20 in
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  Pg.set_env ~net ~sw;
  let cfg = Cfg.from_env () in
  let proxy = Cfg.proxy_endpoint cfg in
  (match proxy with
  | Some (h, p) -> Printf.printf "proxy %s:%d\n%!" h p
  | None -> Printf.printf "no proxy (direct egress)\n%!");
  let dbh = Pg.connect (Pg.cache_conninfo ()) in
  let est = { CS.cfg = cfg.cs; dbh; mem_dbh = dbh } in
  (* most recent zap receipts: (author pubkey, tags json) *)
  let rows =
    [%pgsql dbh "select pubkey, tags from event where kind = 9735 order by imported_at desc limit 50"]
  in
  let zapped_of_tags tags_json =
    match Yojson.Safe.from_string tags_json with
    | `List ts ->
        List.find_map
          (function
            | `List (`String "p" :: `String h :: _) when String.length h = 64 ->
                Importer.Hex_util.decode_opt h
            | _ -> None)
          ts
    | _ -> None
    | exception _ -> None
  in
  let n = ref 0 and ok = ref 0 and no_md = ref 0 in
  (try
     List.iter
       (fun (author, tags_json) ->
         if !n >= limit then raise Exit;
         match zapped_of_tags tags_json with
         | None -> ()
         | Some zapped_pk ->
             incr n;
             let has_md = CS.get_meta_data_event est zapped_pk <> None in
             if not has_md then incr no_md;
             let r = Importer.Lnurl.verify ~net ~clock ?proxy ~timeout:15.0 est ~zapped_pk ~zapper_pubkey:author in
             if r then incr ok;
             Printf.printf "zap author=%s zapped=%s meta=%b verify=%b\n%!" (hx author)
               (hx zapped_pk) has_md r)
       rows
   with Exit -> ());
  Printf.printf "\nLNURL verify: %d/%d verified (%d had no metadata)\n%!" !ok !n !no_md
