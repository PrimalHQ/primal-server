(* The Primal cache WebSocket protocol framing, byte-compatible with what the Julia CacheServer and
   ws-connector sent:

     client:  ["REQ", subid, {"cache": [funcall, kwargs]}, ...]   ["CLOSE", subid]
     server:  ["EVENT", subid, msg]* ["EOSE", subid]
              zlib mode: one BINARY frame zlib(["EVENTS", subid, [msg, ...]]) then text ["EOSE", subid]
              ["NOTICE", subid, text]

   Messages are kept as JSON TEXT (never re-parsed/re-serialized) so what the DB produced is what
   the client gets. *)

type incoming =
  | Req of { subid : string; funcall : string option; kwargs : Yojson.Safe.t; raw : string }
      (** a REQ whose first filter is a {"cache": [funcall, kwargs]} (funcall None: another filter) *)
  | Close of string
  | Other of string  (** anything else (ignored) *)

let parse (text : string) : incoming =
  match Yojson.Safe.from_string text with
  | `List (`String "REQ" :: `String subid :: filters) ->
      let funcall, kwargs =
        match filters with
        | `Assoc f :: _ -> (
            match List.assoc_opt "cache" f with
            | Some (`List (`String fc :: rest)) ->
                (Some fc, match rest with kw :: _ -> kw | [] -> `Assoc [])
            | _ -> (None, `Null))
        | _ -> (None, `Null)
      in
      Req { subid; funcall; kwargs; raw = text }
  | `List [ `String "CLOSE"; `String subid ] -> Close subid
  | _ -> Other text
  | exception _ -> Other text

let json_string (s : string) : string = Yojson.Safe.to_string (`String s)

let eose subid = Printf.sprintf "[\"EOSE\",%s]" (json_string subid)
let notice subid msg = Printf.sprintf "[\"NOTICE\",%s,%s]" (json_string subid) (json_string msg)
let event subid (msg_json : string) = Printf.sprintf "[\"EVENT\",%s,%s]" (json_string subid) msg_json

(* The zlib-mode body: ["EVENTS", subid, [msg, ...]] compressed (RFC 1950, level 6). *)
let events_zlib subid (msgs : string list) : string =
  Zlib_util.compress
    (Printf.sprintf "[\"EVENTS\",%s,[%s]]" (json_string subid) (String.concat "," msgs))

(* {"compression": "zlib"} in set_primal_protocol kwargs *)
let wants_zlib (kwargs : Yojson.Safe.t) : bool =
  match kwargs with
  | `Assoc f -> ( match List.assoc_opt "compression" f with Some (`String "zlib") -> true | _ -> false)
  | _ -> false
