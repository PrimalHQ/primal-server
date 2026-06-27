(* Smoke-test the Eio-native PGOCaml adapter against the reference DB. *)
open Eio.Std
module Pg = Importer.Postgres

let () =
  Eio_main.run @@ fun env ->
  Switch.run @@ fun sw ->
  Pg.set_env ~net:(Eio.Stdenv.net env) ~sw;
  let ci = Pg.cache_conninfo () in
  Printf.printf "connecting to %s:%d/%s as %s\n%!" ci.host ci.port ci.database ci.user;
  let dbh = Pg.connect ci in
  let rows = Pg.ping dbh in
  Pg.close dbh;
  let first = match rows with [ [ Some s ] ] -> s | _ -> "?" in
  Printf.printf "ping ok: %d row(s), select 1 => %s\n%!" (List.length rows) first
