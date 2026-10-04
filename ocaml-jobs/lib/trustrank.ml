(* trustrank_maker.jl make_2 + TrustRank.import_trustrank: personalized PageRank over the follow
   graph, seeded at the verified users (membership verified_users.default_name), blocked
   (spam/csam) pubkeys zeroed, alpha 0.85, 20 iterations, ranks > 0 kept, then written to
   pubkey_trustrank_new and swapped under the live name (the dependent view recreated) — or, in
   shadow mode, written to another table for comparison. The graph is read once through a cursor
   from pubkey_followers (follower -> pubkey) into CSR arrays; Julia walked the contact lists from
   the seeds, which reaches the same nodes that can hold rank. *)

open Eio.Std
module PGOCaml = Postgres.PGOCaml

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [trustrank] %s\n%!" (Procinfo.timestamp ()) s) fmt

type graph = {
  ids : (string, int) Hashtbl.t; (* raw pubkey -> node *)
  mutable keys : string array; (* node -> raw pubkey *)
  mutable n : int;
  src : (int32, Bigarray.int32_elt, Bigarray.c_layout) Bigarray.Array1.t;
  dst : (int32, Bigarray.int32_elt, Bigarray.c_layout) Bigarray.Array1.t;
  mutable m : int;
}

let unhex (s : string) : string = if String.length s > 2 && String.sub s 0 2 = "\\x" then Hex_util.decode_exn (String.sub s 2 (String.length s - 2)) else s

let node (g : graph) (pk : string) : int =
  match Hashtbl.find_opt g.ids pk with
  | Some i -> i
  | None ->
      let i = g.n in
      if i >= Array.length g.keys then begin
        let k = Array.make (max 1024 (2 * Array.length g.keys)) "" in
        Array.blit g.keys 0 k 0 g.n;
        g.keys <- k
      end;
      g.keys.(i) <- pk;
      Hashtbl.replace g.ids pk i;
      g.n <- i + 1;
      i

(* follower -> pubkey edges, one cursor pass *)
let load_graph (dbh : Postgres.dbh) ~(stop : unit Promise.t) ~(seeds : string list) : graph =
  let cap = 80_000_000 in
  let g = { ids = Hashtbl.create 4_000_000; keys = Array.make 1_000_000 ""; n = 0; src = Bigarray.Array1.create Bigarray.int32 Bigarray.c_layout cap; dst = Bigarray.Array1.create Bigarray.int32 Bigarray.c_layout cap; m = 0 } in
  List.iter (fun pk -> ignore (node g pk)) seeds;
  Postgres.exec dbh "begin";
  Fun.protect
    ~finally:(fun () -> try Postgres.exec dbh "rollback" with _ -> ())
    (fun () ->
      ignore (Postgres.query dbh "declare tr_cur no scroll cursor for select follower_pubkey, pubkey from pubkey_followers" []);
      let rec loop () =
        if Promise.is_resolved stop then raise Exit;
        let rows = Postgres.query dbh "fetch 200000 from tr_cur" [] in
        if rows <> [] then begin
          List.iter
            (fun row ->
              match row with
              | [ Some f; Some p ] ->
                  let s = node g (unhex f) and d = node g (unhex p) in
                  if s <> d && g.m < cap then begin
                    Bigarray.Array1.unsafe_set g.src g.m (Int32.of_int s);
                    Bigarray.Array1.unsafe_set g.dst g.m (Int32.of_int d);
                    g.m <- g.m + 1
                  end
              | _ -> ())
            rows;
          if g.m mod 5_000_000 < 200_000 then log "loaded %d edges, %d nodes" g.m g.n;
          Fiber.yield ();
          loop ()
        end
      in
      loop ());
  g

(* make_2's iteration: tr'[f] += a * tr[u] / outdeg(u) for every follow u -> f; tr'[u] += (1-a) d[u] *)
let pagerank (g : graph) ~(seeds : string list) ~(blocked : string list) ~alpha ~iterations ~(stop : unit Promise.t) : (string * float) array =
  let n = g.n in
  (* CSR by source *)
  let outdeg = Array.make (n + 1) 0 in
  for e = 0 to g.m - 1 do
    let s = Int32.to_int (Bigarray.Array1.unsafe_get g.src e) in
    outdeg.(s + 1) <- outdeg.(s + 1) + 1
  done;
  let off = outdeg in
  for i = 1 to n do off.(i) <- off.(i) + off.(i - 1) done;
  let adj = Bigarray.Array1.create Bigarray.int32 Bigarray.c_layout (max 1 g.m) in
  let fill = Array.sub off 0 n in
  for e = 0 to g.m - 1 do
    let s = Int32.to_int (Bigarray.Array1.unsafe_get g.src e) in
    Bigarray.Array1.unsafe_set adj fill.(s) (Bigarray.Array1.unsafe_get g.dst e);
    fill.(s) <- fill.(s) + 1
  done;
  let is_blocked = Array.make n false in
  List.iter (fun pk -> match Hashtbl.find_opt g.ids pk with Some i -> is_blocked.(i) <- true | None -> ()) blocked;
  let d = Array.make n 0.0 in
  List.iter (fun pk -> match Hashtbl.find_opt g.ids pk with Some i when not is_blocked.(i) -> d.(i) <- 1.0 | _ -> ()) seeds;
  let dsum = Array.fold_left ( +. ) 0.0 d in
  if dsum > 0. then Array.iteri (fun i v -> d.(i) <- v /. dsum) d;
  let tr = ref (Array.copy d) in
  for it = 1 to iterations do
    if Promise.is_resolved stop then raise Exit;
    let cur = !tr in
    let next = Array.make n 0.0 in
    for u = 0 to n - 1 do
      let deg = off.(u + 1) - off.(u) in
      if deg > 0 then begin
        let share = alpha *. cur.(u) /. float_of_int deg in
        for k = off.(u) to off.(u + 1) - 1 do
          let f = Int32.to_int (Bigarray.Array1.unsafe_get adj k) in
          next.(f) <- next.(f) +. share
        done
      end;
      next.(u) <- next.(u) +. ((1.0 -. alpha) *. d.(u))
    done;
    let delta = ref 0.0 and energy = ref 0.0 in
    for i = 0 to n - 1 do
      delta := !delta +. Float.abs (next.(i) -. cur.(i));
      energy := !energy +. next.(i)
    done;
    log "iteration %d/%d  E:%g  D:%g" it iterations !energy !delta;
    tr := next;
    Fiber.yield ()
  done;
  let res = ref [] in
  Array.iteri (fun i v -> if (not is_blocked.(i)) && v > 0.0 then res := (g.keys.(i), v) :: !res) !tr;
  let a = Array.of_list !res in
  Array.sort (fun (_, x) (_, y) -> compare y x) a;
  a

let hex = Hex_util.encode

(* TrustRank.import_trustrank: fill the new table in batches, analyze, swap under the view *)
let import (dbh : Postgres.dbh) ~(table : string) ~(live : bool) (rows : (string * float) array) : unit =
  let newt = if live then "pubkey_trustrank_new" else table in
  Postgres.exec dbh (Printf.sprintf "drop table if exists %s" newt);
  Postgres.exec dbh (Printf.sprintf "create unlogged table %s (like pubkey_trustrank including all)" newt);
  let batch = 10_000 in
  let n = Array.length rows in
  let i = ref 0 in
  Postgres.exec dbh "begin";
  (try
     while !i < n do
       let j = min n (!i + batch) in
       let items = List.init (j - !i) (fun k -> let pk, r = rows.(!i + k) in `List [ `String (hex pk); `Float r ]) in
       ignore
         (Postgres.query dbh
            (Printf.sprintf "insert into %s (pubkey, rank) select decode(a->>0, 'hex'), (a->>1)::float8 from jsonb_array_elements($1::jsonb) x(a)" newt)
            [ Some (Yojson.Safe.to_string (`List items)) ]);
       i := j;
       if !i mod 200_000 < batch then log "import: %d / %d" !i n
     done;
     Postgres.exec dbh "commit"
   with e ->
     (try Postgres.exec dbh "rollback" with _ -> ());
     raise e);
  Postgres.exec dbh (Printf.sprintf "analyze %s" newt);
  if live then begin
    Postgres.exec dbh "begin";
    (try
       Postgres.exec dbh "drop view if exists trusted_users_trusted_followers";
       Postgres.exec dbh "alter table pubkey_trustrank rename to pubkey_trustrank_old";
       Postgres.exec dbh "alter table pubkey_trustrank_new rename to pubkey_trustrank";
       Postgres.exec dbh "drop table pubkey_trustrank_old";
       Postgres.exec dbh
         "create view trusted_users_trusted_followers as select pf.pubkey, tr1.rank as pubkey_rank, pf.follower_pubkey, tr2.rank as follower_pubkey_rank from pubkey_followers pf, pubkey_trustrank tr1, pubkey_trustrank tr2 where pf.pubkey = tr1.pubkey and pf.follower_pubkey = tr2.pubkey";
       Postgres.exec dbh "commit"
     with e ->
       (try Postgres.exec dbh "rollback" with _ -> ());
       raise e)
  end

let run_make ~(cfg : Config.t) ~(stop : unit Promise.t) : unit =
  let dbh = Postgres.connect ~statement_timeout_ms:0 ~application_name:"primal-jobs-trustrank" cfg.cache_db in
  let mem = Postgres.connect ~application_name:"primal-jobs-trustrank" cfg.membership_db in
  Fun.protect
    ~finally:(fun () -> (try Postgres.close dbh with _ -> ()); try Postgres.close mem with _ -> ())
    (fun () ->
      let seeds = Queries_mem.verified_default_pubkeys mem and blocked = Queries_mem.blocked_pubkeys mem in
      log "seeds %d, blocked %d" (List.length seeds) (List.length blocked);
      let t0 = Unix.gettimeofday () in
      let g = load_graph dbh ~stop ~seeds in
      log "graph: %d nodes, %d edges (%.0fs)" g.n g.m (Unix.gettimeofday () -. t0);
      let rows = pagerank g ~seeds ~blocked ~alpha:cfg.trustrank_alpha ~iterations:cfg.trustrank_iterations ~stop in
      Hashtbl.reset g.ids;
      log "ranked %d pubkeys (%.0fs)" (Array.length rows) (Unix.gettimeofday () -. t0);
      let live = cfg.trustrank_target_table = "pubkey_trustrank" in
      import dbh ~table:cfg.trustrank_target_table ~live rows;
      log "%s %s (%.0fs)" (if live then "swapped into" else "written to") cfg.trustrank_target_table (Unix.gettimeofday () -. t0))

let run ~(cfg : Config.t) ~(stop : unit Promise.t) ~clock : unit =
  (* Julia sleeps one period before the first run *)
  if not cfg.trustrank_run_at_start then (match Fiber.first (fun () -> Promise.await stop; `Stop) (fun () -> Eio.Time.sleep clock cfg.trustrank_period_s; `Tick) with `Stop -> () | `Tick -> ());
  if not (Promise.is_resolved stop) then
    Periodic.run ~clock ~stop ~period:cfg.trustrank_period_s ~label:"trustrank" (fun () ->
        (try run_make ~cfg ~stop with Exit -> ());
        Gc.compact ())
