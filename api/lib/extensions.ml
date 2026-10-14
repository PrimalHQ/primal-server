(* The registration points the private extensions (primal-net-server/ext) fill at startup,
   before the daemon serves: extra funcalls (dispatched for names that are not in the public
   catalogue), extra HTTP routes on the internal and moderation ports, and the "ext" object of the
   config file. Append-once: a duplicate or a public name is a
   startup failure. *)

type funcall = { handler : Handlers.ctx -> Kw.t -> Response.outcome; moderate : bool }

let funcalls : (string, funcall) Hashtbl.t = Hashtbl.create 16

let register_funcall ?(moderate = true) (name : string) (handler : Handlers.ctx -> Kw.t -> Response.outcome) : unit =
  if Hashtbl.mem funcalls name then failwith ("Extensions.register_funcall: duplicate " ^ name);
  Hashtbl.replace funcalls name { handler; moderate }

let find_funcall (name : string) : funcall option = Hashtbl.find_opt funcalls name
let has_funcall (name : string) : bool = Hashtbl.mem funcalls name
let funcall_names () : string list = List.sort compare (List.of_seq (Hashtbl.to_seq_keys funcalls))

type port = [ `Internal | `Moderation ]

let routes_internal : Http_server.route list ref = ref []
let routes_moderation : Http_server.route list ref = ref []

let register_http_route (port : port) (r : Http_server.route) : unit =
  let l = match port with `Internal -> routes_internal | `Moderation -> routes_moderation in
  if List.exists (fun (x : Http_server.route) -> x.pattern = r.pattern && x.meth = r.meth) !l then failwith ("Extensions.register_http_route: duplicate " ^ Http_server.pattern_string r.pattern);
  l := !l @ [ r ]

let routes (port : port) : Http_server.route list = match port with `Internal -> !routes_internal | `Moderation -> !routes_moderation
