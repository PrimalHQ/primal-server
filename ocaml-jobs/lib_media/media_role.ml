(* The media role: the executor's context and the scheduler loop. *)

open Eio.Std

let register_all () =
  Nodes_media.register ();
  Nodes_upload.register ();
  Nodes_moderation.register ();
  Nodes_text.register ()

let make_ctx ~(cfg : Media_config.t) ~(cache_db : Postgres.conninfo) ~(membership_db : Postgres.conninfo) ~net ~clock ~proc_mgr : Procgraph.ctx =
  register_all ();
  Proc.ensure_path ();
  { Procgraph.cfg; cache = Postgres.make_pool ~size:48 cache_db; mem = Postgres.make_pool ~size:8 membership_db; net; clock; proc_mgr; verbose = cfg.log }

let run ~(cfg : Media_config.t) ~cache_db ~membership_db ~net ~clock ~proc_mgr ~(stop : unit Promise.t) : unit =
  let ctx = make_ctx ~cfg ~cache_db ~membership_db ~net ~clock ~proc_mgr in
  Pushgateway.mkdir_p cfg.binary_data_cache_dir;
  Pushgateway.mkdir_p cfg.tmp_dir;
  Procgraph.log "media role: handlers %s; claiming %s" (String.concat "," (Procgraph.registered_funcs ())) (String.concat "," cfg.execute_funcs);
  Scheduler.run ctx ~stop
