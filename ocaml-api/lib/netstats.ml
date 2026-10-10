(* App.network_stats: the "content" of the net_stats message, a JSON object text of the importer's
   counters (users, pubkeys, pubnotes, reactions, reposts, any, zaps, satszapped). Two sources:
   - network_stats_url (App.NETWORK_STATS_URL): another node's HTTP /api answering network_stats;
   - network_stats_file: the importer's persisted stats dict (src/cache_storage.jl save_stats, the
     <storage>/primalnode<N>/cache/db/stats.json the OCaml importer keeps "any" in), read here the way
     the Julia node owning it answered from est.commons.stats.
   The URL wins when both are set. *)

let keys = [ "users"; "pubkeys"; "pubnotes"; "reactions"; "reposts"; "any"; "zaps"; "satszapped" ]

let of_file (path : string) : string =
  let fields = match Yojson.Safe.from_file path with `Assoc f -> f | _ -> failwith (path ^ ": not a JSON object") in
  let num k =
    match List.assoc_opt k fields with
    | Some (`Int _ as n) | Some (`Intlit _ as n) -> n
    | Some (`Float f) -> `Int (int_of_float f)
    | _ -> `Int 0
  in
  Yojson.Safe.to_string (`Assoc (List.map (fun k -> (k, num k)) keys))

let of_url ~net ~clock (url : string) : string =
  match Http.parse_url url with
  | None -> failwith ("network_stats_url: " ^ url)
  | Some u -> (
      match Http.plain_request ~net ~clock ~timeout:5.0 ~meth:"GET" ~body:{|["network_stats",{}]|} ~host:u.Http.host ~port:u.Http.port ~path:u.Http.path () with
      | 200, body -> (
          match Yojson.Safe.from_string body with
          | `List [ `Int _; `String content ] -> content (* Julia's /api: [kind, content] *)
          | `List [ `Assoc m ] -> ( (* this API's /api: [message] *)
              match List.assoc_opt "content" m with Some (`String content) -> content | _ -> failwith "network_stats: no content")
          | _ -> failwith "network_stats: unexpected answer")
      | status, _ -> failwith (Printf.sprintf "network_stats: HTTP %d" status))

let configured (cfg : Config.t) : bool = cfg.network_stats_url <> None || cfg.network_stats_file <> None

(* the content text; raises when the source fails; None when no source is configured *)
let content ~net ~clock (cfg : Config.t) : string option =
  match (cfg.network_stats_url, cfg.network_stats_file) with
  | Some url, _ -> Some (of_url ~net ~clock url)
  | None, Some path -> Some (of_file path)
  | None, None -> None

let users ~net ~clock (cfg : Config.t) : int option =
  match content ~net ~clock cfg with
  | Some c -> ( match Yojson.Safe.from_string c with `Assoc f -> ( match List.assoc_opt "users" f with Some (`Int n) -> Some n | _ -> None) | _ -> None)
  | None -> None
  | exception _ -> None
