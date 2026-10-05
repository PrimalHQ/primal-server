(* media_tool CONFIG check-ids [LIMIT]   recompute node ids of stored nodes (insertion-ordered and
                                       sorted-key JSON) and report matches per func
   media_tool CONFIG execute-node HEX    run one stored node with the registered handlers
   media_tool CONFIG show-node HEX       print a node
   media_tool CONFIG pending             pending counts per func
   media_tool CONFIG import-media URL [EID]   create an import_media_pn node (all variants) and run it now
   media_tool CONFIG import-preview URL EID   create an import_preview_pn node and run it now *)

open Eio.Std
module J = Primal_jobs
module M = Primal_jobs_media

let () =
  let cfg_path, cmd, arg, arg2 = match Array.to_list Sys.argv with [ _; c; cmd ] -> (c, cmd, None, None) | [ _; c; cmd; a ] -> (c, cmd, Some a, None) | [ _; c; cmd; a; b ] -> (c, cmd, Some a, Some b) | _ -> prerr_endline "usage: media_tool CONFIG (check-ids [LIMIT] | execute-node HEX | show-node HEX | pending | import-media URL [EID] | import-preview URL EID)"; exit 2 in
  let cfg = J.Config.of_json_file cfg_path in
  let mcfg = match cfg.media with Some m -> m | None -> prerr_endline "config has no media object"; exit 2 in
  Random.self_init ();
  Eio_main.run @@ fun env ->
  Mirage_crypto_rng_unix.use_default ();
  Http.init_tls ();
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env and proc_mgr = Eio.Stdenv.process_mgr env in
  Switch.run @@ fun sw ->
  Postgres.set_env ~net ~sw;
  let ctx = M.Media_role.make_ctx ~cfg:mcfg ~cache_db:cfg.cache_db ~membership_db:cfg.membership_db ~net ~clock ~proc_mgr ~domain_mgr:(Eio.Stdenv.domain_mgr env) in
  match cmd with
  | "check-ids" ->
      let limit = Option.value (Option.bind arg int_of_string_opt) ~default:10000 in
      let rows = M.Procgraph.q ctx "select encode(id,'hex'), coalesce(mod,''), func, args::text, kwargs::text from processing_nodes order by created_at desc limit $1" [ Some (string_of_int limit) ] in
      let stats = Hashtbl.create 16 in
      List.iter
        (fun row ->
          match row with
          | [ Some id; Some mod_; Some func; args; kwargs ] ->
              let args = M.Procgraph.parse_json args and kwargs = M.Procgraph.parse_json kwargs in
              let jul = M.Pgj.node_id_juliaish ~mod_ ~func ~args ~kwargs = id and srt = M.Pgj.node_id_sorted ~mod_ ~func ~args ~kwargs = id in
              let t, i, s, n = Option.value (Hashtbl.find_opt stats func) ~default:(0, 0, 0, 0) in
              Hashtbl.replace stats func (t + 1, i + (if jul then 1 else 0), s + (if srt then 1 else 0), n + (if jul || srt then 0 else 1))
          | _ -> ())
        rows;
      Printf.printf "%-40s %8s %10s %8s %8s\n" "func" "total" "juliaish" "sorted" "neither";
      Hashtbl.iter (fun f (t, i, s, n) -> Printf.printf "%-40s %8d %10d %8d %8d\n" f t i s n) stats
  | "execute-node" -> (
      let id = Option.get arg in
      match M.Procgraph.load_node ctx id with
      | Some n -> ( match M.Procgraph.execute_node ctx n with Ok v -> print_endline (Yojson.Safe.pretty_to_string v) | Error m -> Printf.printf "FAILED: %s\n" m; exit 1)
      | None -> prerr_endline "node not found"; exit 1)
  | "show-node" -> (
      match M.Procgraph.q ctx "select encode(id,'hex'), mod, func, args::text, kwargs::text, result::text, exception::text, started_at::text, finished_at::text, extra::text from processing_nodes where id = decode($1,'hex')" [ arg ] with
      | row :: _ -> List.iter2 (fun k v -> Printf.printf "%s: %s\n" k (Option.value v ~default:"null")) [ "id"; "mod"; "func"; "args"; "kwargs"; "result"; "exception"; "started_at"; "finished_at"; "extra" ] row
      | [] -> prerr_endline "node not found"; exit 1)
  | "pending" ->
      List.iter (fun row -> match row with [ Some f; Some c; oldest ] -> Printf.printf "%-40s %8s  oldest %s\n" f c (Option.value oldest ~default:"") | _ -> ())
        (M.Procgraph.q ctx "select func, count(*), min(created_at)::text from processing_nodes where started_at is null and finished_at is null and created_at > now() - interval '3 days' group by 1 order by 2 desc" [])
  | "import-media" ->
      let url = Option.get arg in
      let eid = match arg2 with Some h -> M.Pgj.event_id_hex h | None -> `Null in
      let n, r = M.Procgraph.pn ctx ~mod_:"PrimalServer.DB" ~func:"import_media_pn" ~args:(M.Pgj.tuple [ M.Pgj.cache_storage; eid; `String url; M.Pgj.all_variants ]) ~kwargs:(`Assoc []) in
      Printf.printf "node %s\n" (M.Procgraph.id_hex n);
      (match r with Ok v -> print_endline (Yojson.Safe.pretty_to_string v) | Error m -> Printf.printf "FAILED: %s\n" m; exit 1)
  | "import-preview" ->
      let url = Option.get arg and eid = Option.get arg2 in
      let n, r = M.Procgraph.pn ctx ~mod_:"PrimalServer.DB" ~func:"import_preview_pn" ~args:(M.Pgj.tuple [ M.Pgj.cache_storage; M.Pgj.event_id_hex eid; `String url ]) ~kwargs:(`Assoc []) in
      Printf.printf "node %s\n" (M.Procgraph.id_hex n);
      (match r with Ok v -> print_endline (Yojson.Safe.pretty_to_string v) | Error m -> Printf.printf "FAILED: %s\n" m; exit 1)
  | _ -> prerr_endline "unknown command"; exit 2
