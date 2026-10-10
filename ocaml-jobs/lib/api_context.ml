(* The roles that run the cache API's handlers in-process (analytics, dvm_provider) share this
   domain's API DB pools and the handlers' net; set up once, by whichever role starts first. *)

let initialised = Atomic.make false

let init ~(cfg : Config.t) ~net : unit =
  if not (Atomic.exchange initialised true) then begin
    Primal_api_db.Db.init ~cache_db:cfg.cache_db ~membership_db:cfg.membership_db ~cache_size:40 ~membership_size:4;
    Primal_api.Handlers.net_ref := Some net
  end
