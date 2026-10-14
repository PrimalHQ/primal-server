(* Ported from Julia's postgres.jl server_tracking: every second read the membership discovery
   document ({"postgres": connstr, ...}); when the server it names is in recovery, promote it.
   A singleton through a Postgres advisory lock on the membership DB. It only promotes: no daemon
   re-points its connection pools at the new primary. *)

open Eio.Std
module PGOCaml = Postgres.PGOCaml

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [failover] %s\n%!" (Procinfo.timestamp ()) s) fmt
let lock_key = 0x7072696d616c01 (* "primal" + 1 *)

(* "host=a port=b dbname=c user=d" *)
let conninfo_of_connstr (s : string) : Postgres.conninfo option =
  let kv = List.filter_map (fun tok -> match String.index_opt tok '=' with Some i -> Some (String.sub tok 0 i, String.sub tok (i + 1) (String.length tok - i - 1)) | None -> None) (String.split_on_char ' ' s) in
  match (List.assoc_opt "host" kv, List.assoc_opt "dbname" kv, List.assoc_opt "user" kv) with
  | Some host, Some database, Some user -> Some { Postgres.host; port = (match List.assoc_opt "port" kv with Some p -> int_of_string p | None -> 5432); user; database }
  | _ -> None

let check ~net ~clock ~(url : string) : unit =
  match Http.request ~net ~clock ~timeout:5.0 url with
  | Some r when r.Http.status = 200 -> (
      match Yojson.Safe.from_string r.body with
      | `Assoc f -> (
          match List.assoc_opt "postgres" f with
          | Some (`String cs) -> (
              match conninfo_of_connstr cs with
              | Some ci ->
                  let dbh = Postgres.connect ~application_name:"primal-jobs-failover" ci in
                  Fun.protect ~finally:(fun () -> try Postgres.close dbh with _ -> ()) (fun () ->
                      match Postgres.query dbh "select pg_is_in_recovery()" [] with
                      | [ Some "t" ] :: _ ->
                          log "%s is in recovery: promoting" ci.Postgres.host;
                          ignore (Postgres.query dbh "select pg_promote()" [])
                      | _ -> ())
              | None -> log "discovery: unparsable connstr")
          | _ -> log "discovery: no postgres entry")
      | _ -> log "discovery: not an object")
  | Some r -> log "discovery: HTTP %d" r.Http.status
  | None -> log "discovery: request failed"

let run ~(cfg : Config.t) ~net ~clock ~(stop : unit Promise.t) : unit =
  match cfg.membership_discovery_url with
  | None -> log "membership_discovery_url not set; failover role idle"; Promise.await stop
  | Some url ->
      let lockdbh = Postgres.connect ~application_name:"primal-jobs-failover-lock" cfg.membership_db in
      let rec acquire () = if not (Queries_mem.try_advisory_lock lockdbh ~key:lock_key) then (match Fiber.first (fun () -> Promise.await stop; `Stop) (fun () -> Eio.Time.sleep clock 5.0; `Tick) with `Stop -> false | `Tick -> acquire ()) else true in
      if acquire () then begin
        log "failover watcher active (advisory lock held)";
        Periodic.run ~clock ~stop ~period:1.0 ~label:"failover" (fun () -> check ~net ~clock ~url)
      end
