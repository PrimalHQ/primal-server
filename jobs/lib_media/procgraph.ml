(* The processing graph: processing_nodes / processing_edges as processing_graph.jl and
   processing_graph.rs use them. A node is (mod, func, args, kwargs) with the id of Pgj.node_id;
   @pn runs it inline (recording the ancestry edge from the current node), @pnd stores it for a
   scheduler to pick up; a run records started_at, then result or the exception, finished_at,
   keeps the node's extra (E() root fields and extralog's log entries), and deletes the binary
   cache files its arguments referenced. Handlers are registered per (mod, func); a node whose func
   has no handler is never claimed. *)

open Eio.Std

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [media] %s\n%!" (Procinfo.timestamp ()) s) fmt

type ctx = {
  cfg : Media_config.t;
  cache : Postgres.pool; (* the media host's cache DB: processing tables, media tables *)
  mem : Postgres.pool; (* membership DB *)
  net : Eio_unix.Net.t;
  clock : float Eio.Time.clock_ty r;
  proc_mgr : Eio_unix.Process.mgr_ty r;
  domain_mgr : Eio.Domain_manager.ty r; (* the scheduler's worker domains *)
  verbose : bool;
}

type node = { id : string (* 32 raw bytes *); mod_ : string; func : string; args : Pgj.t; kwargs : Pgj.t }

let id_hex (n : node) = Hex_util.encode n.id

type handler = ctx -> node -> Pgj.t
let registry : (string * string, handler) Hashtbl.t = Hashtbl.create 32
let register ~(mod_ : string) ~(func : string) (h : handler) : unit = Hashtbl.replace registry (mod_, func) h
let find_handler ~mod_ ~func : handler option = match Hashtbl.find_opt registry (mod_, func) with Some h -> Some h | None -> ( match List.find_opt (fun ((_, f), _) -> f = func) (List.of_seq (Hashtbl.to_seq registry)) with Some (_, h) -> Some h | None -> None)
let registered_funcs () : string list = List.sort_uniq compare (List.map snd (List.of_seq (Hashtbl.to_seq_keys registry)))

exception Node_error of string
let fail fmt = Printf.ksprintf (fun s -> raise (Node_error s)) fmt

(* the fiber-local ancestry stack (Julia task_local_storage :processing_graph_stack) *)
let parent_key : node Fiber.key = Fiber.create_key ()
let current_parent () : node option = Fiber.get parent_key
let with_parent (n : node) f = Fiber.with_binding parent_key n f

(* {1 SQL} *)
let q (ctx : ctx) sql params = Postgres.use ctx.cache (fun dbh -> Postgres.query dbh sql params)
let qm (ctx : ctx) sql params = Postgres.use ctx.mem (fun dbh -> Postgres.query dbh sql params)
let hexp (raw : string) = Some (Hex_util.encode raw)
let js (v : Pgj.t) = Some (Pgj.to_string v)
let ts_now () = let t = Unix.gettimeofday () in let tm = Unix.gmtime t in Printf.sprintf "%04d-%02d-%02d %02d:%02d:%02d.%06d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec (int_of_float ((t -. Float.of_int (int_of_float t)) *. 1e6))
let parse_json (s : string option) : Pgj.t = match s with Some s -> ( try Yojson.Safe.from_string s with _ -> `Null) | None -> `Null

(* processing_graph.jl update_node: the upsert that creates a node or resets it *)
let upsert_node (ctx : ctx) (n : node) ?(result : Pgj.t option) ?(exception_ = false) ?(started_at : string option) ?(finished_at : string option) ?(extra : Pgj.t option) () : unit =
  ignore
    (q ctx
       "insert into processing_nodes (id, created_at, updated_at, mod, func, args, kwargs, result, exception, started_at, finished_at, extra) \
        values (decode($1,'hex'), now(), now(), $2, $3, $4::jsonb, $5::jsonb, $6::jsonb, $7::boolean, $8::timestamp, $9::timestamp, $10::jsonb) \
        on conflict (id) do update set updated_at = now(), mod = excluded.mod, func = excluded.func, args = excluded.args, kwargs = excluded.kwargs, result = excluded.result, exception = excluded.exception, \
        started_at = excluded.started_at, finished_at = excluded.finished_at, extra = excluded.extra"
       [ hexp n.id; Some n.mod_; Some n.func; js n.args; js n.kwargs; Option.map Pgj.to_string result; Some (if exception_ then "t" else "f"); started_at; finished_at; Option.map Pgj.to_string extra ])

let get_extra (ctx : ctx) (id : string) : Pgj.t =
  match q ctx "select extra::text from processing_nodes where id = decode($1,'hex')" [ hexp id ] with [ e ] :: _ -> parse_json e | _ -> `Null

let set_extra (ctx : ctx) (id : string) (extra : Pgj.t) : unit = ignore (q ctx "update processing_nodes set extra = $2::jsonb where id = decode($1,'hex')" [ hexp id; js extra ])

(* E(; k=v, ...): root-level extra fields *)
let extra_merge (ctx : ctx) (id : string) (kvs : (string * Pgj.t) list) : unit =
  let extra = match get_extra ctx id with `Assoc f -> f | _ -> [] in
  let extra = List.fold_left (fun acc (k, v) -> (k, v) :: List.remove_assoc k acc) extra kvs in
  set_extra ctx id (`Assoc (List.rev extra))

(* extralog((; ...)): append a NamedTuple-wrapped entry to extra.log *)
let extralog (ctx : ctx) (id : string) (kvs : (string * Pgj.t) list) : unit =
  try
    let extra = match get_extra ctx id with `Assoc f -> f | _ -> [] in
    let logs = match List.assoc_opt "log" extra with Some (`List l) -> l | _ -> [] in
    let extra = ("log", `List (logs @ [ Pgj.namedtuple kvs ])) :: List.remove_assoc "log" extra in
    set_extra ctx id (`Assoc extra)
  with exn -> log "extralog %s: %s" (Hex_util.encode id) (Printexc.to_string exn)

let elog ctx (n : node) kvs = extralog ctx n.id kvs
let e_root ctx (n : node) kvs = extra_merge ctx n.id kvs

let subnode (ctx : ctx) ~(parent : string) ~(child : string) : unit =
  ignore (q ctx "insert into processing_edges (type, id1, id2, created_at, updated_at, extra) values ('ancestry', decode($1,'hex'), decode($2,'hex'), now(), now(), null) on conflict (type, id1, id2) do update set updated_at = excluded.updated_at" [ hexp parent; hexp child ])

let make_node ~mod_ ~func ~args ~kwargs : node = { id = Hex_util.decode_exn (Pgj.node_id ~mod_ ~func ~args ~kwargs); mod_; func; args; kwargs }

(* {1 execution} *)
let error_json (msg : string) : Pgj.t = `Assoc [ ("error", `String msg) ]

(* run a node whose row exists (started_at already set by the caller or set here) *)
let execute_node (ctx : ctx) (n : node) : (Pgj.t, string) result =
  let started = ts_now () in
  (try ignore (q ctx "update processing_nodes set updated_at = now(), started_at = $2::timestamp, finished_at = null, result = null, exception = false where id = decode($1,'hex')" [ hexp n.id; Some started ]) with _ -> ());
  let finish (res : (Pgj.t, string) result) =
    let result, exc = match res with Ok v -> (v, false) | Error m -> (error_json m, true) in
    (try ignore (q ctx "update processing_nodes set updated_at = now(), result = $2::jsonb, exception = $3::boolean, finished_at = $4::timestamp where id = decode($1,'hex')" [ hexp n.id; js result; Some (if exc then "t" else "f"); Some (ts_now ()) ])
     with exn -> log "finish %s: %s" (id_hex n) (Printexc.to_string exn));
    Pgj.cleanup_binary_cache ~dir:ctx.cfg.binary_data_cache_dir n.args;
    Pgj.cleanup_binary_cache ~dir:ctx.cfg.binary_data_cache_dir n.kwargs;
    res
  in
  match find_handler ~mod_:n.mod_ ~func:n.func with
  | None -> finish (Error (Printf.sprintf "no handler for %s.%s" n.mod_ n.func))
  | Some h -> (
      match with_parent n (fun () -> h ctx n) with
      | v -> finish (Ok v)
      | exception Eio.Cancel.Cancelled e -> raise (Eio.Cancel.Cancelled e)
      | exception Node_error m -> finish (Error m)
      | exception exn -> finish (Error (Printexc.to_string exn)))

(* @pn: create (or reset) the node, link it to the current node, run it now *)
let pn (ctx : ctx) ~mod_ ~func ~args ~kwargs : node * (Pgj.t, string) result =
  let n = make_node ~mod_ ~func ~args ~kwargs in
  upsert_node ctx n ();
  (match current_parent () with Some p -> (try subnode ctx ~parent:p.id ~child:n.id with _ -> ()) | None -> ());
  (n, execute_node ctx n)

(* @pnd: store the node for a scheduler, link it to the current node *)
let pnd (ctx : ctx) ~mod_ ~func ~args ~kwargs : node =
  let n = make_node ~mod_ ~func ~args ~kwargs in
  upsert_node ctx n ();
  (match current_parent () with Some p -> (try subnode ctx ~parent:p.id ~child:n.id with _ -> ()) | None -> ());
  n

(* the scheduler's claim: oldest pending node of [func], marked started atomically *)
let claim_pending (ctx : ctx) (func : string) : (node * string) option =
  match
    q ctx
      "update processing_nodes set started_at = now(), updated_at = now() \
       where id = (select id from processing_nodes where func = $1 and started_at is null and finished_at is null order by created_at limit 1 for update skip locked) \
       returning encode(id,'hex'), coalesce(mod,''), args::text, kwargs::text, created_at::text"
      [ Some func ]
  with
  | [ Some id; Some mod_; args; kwargs; created ] :: _ -> Some ({ id = Hex_util.decode_exn id; mod_; func; args = parse_json args; kwargs = parse_json kwargs }, Option.value created ~default:"")
  | _ -> None

let load_node (ctx : ctx) (id_hex : string) : node option =
  match q ctx "select coalesce(mod,''), func, args::text, kwargs::text from processing_nodes where id = decode($1,'hex')" [ Some id_hex ] with
  | [ Some mod_; Some func; args; kwargs ] :: _ -> Some { id = Hex_util.decode_exn id_hex; mod_; func; args = parse_json args; kwargs = parse_json kwargs }
  | _ -> None

let pending_count (ctx : ctx) (func : string) : int =
  match q ctx "select count(*) from processing_nodes where func = $1 and started_at is null and finished_at is null and created_at > now() - interval '48 hours'" [ Some func ] with [ Some c ] :: _ -> int_of_string c | _ -> 0

let reset_stuck (ctx : ctx) (func : string) : int =
  match q ctx "with u as (update processing_nodes set started_at = null where created_at >= now() - interval '2d' and func = $1 and started_at is not null and finished_at is null returning 1) select count(*) from u" [ Some func ] with
  | [ Some c ] :: _ -> int_of_string c
  | _ -> 0
