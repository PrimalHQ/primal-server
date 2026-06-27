(* PostgreSQL access layer, mirroring Julia src/postgres.jl + psql2.jl.

   PGOCaml is functorized over a THREAD interface; we instantiate it with a NATIVE Eio
   adapter (`type 'a t = 'a`, direct style) so that DB I/O suspends the running fiber
   instead of blocking the domain (pgocaml-eio.md, "path B"). The [%pgsql] ppx resolves
   its generated runtime calls against the [PGOCaml] module defined here.

   Eio resources are bound to the domain that created them, so connections must be created
   and used within the same domain. The worker pool therefore keeps a per-domain pool
   (see Worker_pool); nothing here is shared across domains. *)

open Eio.Std

type net_t = [ `Generic | `Unix ] Eio.Net.ty r

(* Ambient Eio capabilities for the CURRENT DOMAIN. The worker pool runs each worker in its
   own domain (Eio.Domain_manager.run); since switches and sockets are domain-local, these are
   held in domain-local storage and [set_env] must be called once inside each domain before it
   opens connections. The [net] capability itself is shareable across domains — only the socket
   it creates (and the switch holding it) must be domain-local. *)
let net_key : net_t option Domain.DLS.key = Domain.DLS.new_key (fun () -> None)
let sw_key : Switch.t option Domain.DLS.key = Domain.DLS.new_key (fun () -> None)

let set_env ~(net : _ Eio.Net.t) ~sw =
  Domain.DLS.set net_key (Some (net :> net_t));
  Domain.DLS.set sw_key (Some sw)

let get_net () =
  match Domain.DLS.get net_key with Some n -> n | None -> failwith "Postgres: Eio env not set"

let get_sw () =
  match Domain.DLS.get sw_key with Some s -> s | None -> failwith "Postgres: Eio switch not set"

(* A connection's byte channels: one Eio socket, a buffered reader, and an output buffer
   flushed on demand (mirrors the in/out channels PGOCaml expects). *)
type conn_io = {
  flow : Eio_unix.Net.stream_socket_ty r;
  reader : Eio.Buf_read.t;
  out : Buffer.t;
}

module Eio_thread = struct
  type 'a t = 'a

  let return x = x
  let ( >>= ) x f = f x
  let fail = raise

  let catch f handler =
    try f () with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | e -> handler e

  type in_channel = conn_io
  type out_channel = conn_io

  let open_connection (sockaddr : Unix.sockaddr) : in_channel * out_channel =
    let addr = Eio_unix.Net.sockaddr_of_unix_stream sockaddr in
    let sock = Eio.Net.connect ~sw:(get_sw ()) (get_net ()) addr in
    let flow = (sock :> Eio_unix.Net.stream_socket_ty r) in
    let reader =
      Eio.Buf_read.of_flow (flow :> Eio.Flow.source_ty r) ~max_size:(64 * 1024 * 1024)
    in
    let c = { flow; reader; out = Buffer.create 4096 } in
    (c, c)

  let output_char oc c = Buffer.add_char oc.out c
  let output_string oc s = Buffer.add_string oc.out s

  let output_binary_int oc i =
    Buffer.add_char oc.out (Char.chr ((i lsr 24) land 0xff));
    Buffer.add_char oc.out (Char.chr ((i lsr 16) land 0xff));
    Buffer.add_char oc.out (Char.chr ((i lsr 8) land 0xff));
    Buffer.add_char oc.out (Char.chr (i land 0xff))

  let flush oc =
    if Buffer.length oc.out > 0 then begin
      Eio.Flow.copy_string (Buffer.contents oc.out) (oc.flow :> Eio.Flow.sink_ty r);
      Buffer.clear oc.out
    end

  let input_char ic = Eio.Buf_read.any_char ic.reader

  let input_binary_int ic =
    let s = Eio.Buf_read.take 4 ic.reader in
    let b k = Char.code s.[k] in
    (b 0 lsl 24) lor (b 1 lsl 16) lor (b 2 lsl 8) lor b 3

  let really_input ic buf pos len =
    let s = Eio.Buf_read.take len ic.reader in
    Bytes.blit_string s 0 buf pos len

  let close_in ic = ( try Eio.Flow.close ic.flow with _ -> () )
end

module PGOCaml = PGOCaml_generic.Make (Eio_thread)

(* PGOCaml's connection phantom type IS the type of its private data; the [%pgsql] ppx
   stores its prepared-statement cache there as a (string, bool) Hashtbl.t. The dbh type
   must therefore expose that, or queries fail to type-check. *)
type dbh = (string, bool) Hashtbl.t PGOCaml.t

(* {1 Connection settings} (mirror Julia connection selectors :p0 / :membership) *)

type conninfo = { host : string; port : int; user : string; database : string }

let getenv_opt = Sys.getenv_opt

(* Local cache DB: the importer's :p0. Defaults follow the nix devShell PG* vars. *)
let cache_conninfo () =
  {
    host = Option.value (getenv_opt "PGHOST") ~default:"127.0.0.1";
    port = int_of_string (Option.value (getenv_opt "PGPORT") ~default:"54017");
    user = Option.value (getenv_opt "PGUSER") ~default:"pr";
    database = Option.value (getenv_opt "PGDATABASE") ~default:"primal_importer_ref";
  }

(* Membership DB: the importer's :membership (filterlist / human_override). Defaults to the
   cache conninfo so that, on a staging box where everything lives in one DB, no extra env is
   needed; override with PGMEMBERSHIP* to point at a separate server. *)
let membership_conninfo () =
  let c = cache_conninfo () in
  {
    host = Option.value (getenv_opt "PGMEMBERSHIPHOST") ~default:c.host;
    port = (match getenv_opt "PGMEMBERSHIPPORT" with Some p -> int_of_string p | None -> c.port);
    user = Option.value (getenv_opt "PGMEMBERSHIPUSER") ~default:c.user;
    database = Option.value (getenv_opt "PGMEMBERSHIPDATABASE") ~default:c.database;
  }

(* Remote DB for verification (bin/compare.ml): the Julia importer's Postgres. Defaults to the
   local port/credentials with only the host differing (default 192.168.44.7), but each field can
   be overridden independently with COMPARE_* since the Julia box often uses a different database
   name (e.g. primal1) than the local reference DB. *)
let remote_conninfo () =
  let c = cache_conninfo () in
  {
    host = Option.value (getenv_opt "COMPARE_HOST") ~default:"192.168.44.7";
    port = (match getenv_opt "COMPARE_PORT" with Some p -> int_of_string p | None -> c.port);
    user = Option.value (getenv_opt "COMPARE_USER") ~default:c.user;
    database = Option.value (getenv_opt "COMPARE_DATABASE") ~default:c.database;
  }

let connect (ci : conninfo) : dbh =
  PGOCaml.connect ~host:ci.host ~port:ci.port ~user:ci.user ~database:ci.database ()

let close (dbh : dbh) = PGOCaml.close dbh

(* {1 Bounded connection pool} (exclusive lease per in-flight query; per domain).

   Eio.Stream acts as a bounded blocking queue of idle connections: [take] suspends the
   fiber until one is free, giving us the exclusive-lease semantics from the plan. *)
type pool = { conns : dbh Eio.Stream.t }

let make_pool ~size (ci : conninfo) : pool =
  let conns = Eio.Stream.create size in
  for _ = 1 to size do
    Eio.Stream.add conns (connect ci)
  done;
  { conns }

let use (p : pool) (f : dbh -> 'a) : 'a =
  let dbh = Eio.Stream.take p.conns in
  Fun.protect ~finally:(fun () -> Eio.Stream.add p.conns dbh) (fun () -> f dbh)

(* Low-level ping that exercises the Eio THREAD adapter without the [%pgsql] ppx (so it
   does not depend on the compile-time reference schema). *)
let ping (dbh : dbh) : string option list list =
  PGOCaml.prepare dbh ~query:"select 1" ();
  let rows = PGOCaml.execute dbh ~params:[] () in
  PGOCaml.close_statement dbh ();
  rows
