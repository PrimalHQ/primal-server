(* App.precalculate_analytics (app_ext.jl:672): every 10 minutes the sixteen explore selectors
   (trending / gm_trending / classic_trending / mostzapped × 24h/12h/4h/1h) are computed through
   the API's scored_content (the primal_api library, with the API's own config), filtered to the
   kinds the clients render, the notes of the gaming-detection selectors prefixed "[G] " when the
   Ollama classifier answers yes, and stored in the cache table as precalculated_analytics_<selector>;
   then the explore topics (hashtag counts of the last day among human-ranked authors). An
   [analytics_key_suffix] writes shadow keys for comparison with Julia's. *)

open Eio.Std
module H = Primal_api.Handlers
module PGOCaml = Postgres.PGOCaml

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [analytics] %s\n%!" (Procinfo.timestamp ()) s) fmt

let precals =
  [ ("trending_24h", true); ("trending_12h", true); ("trending_4h", true); ("trending_1h", true);
    ("gm_trending_24h", false); ("gm_trending_12h", false); ("gm_trending_4h", false); ("gm_trending_1h", false);
    ("classic_trending_24h", false); ("classic_trending_12h", false); ("classic_trending_4h", false); ("classic_trending_1h", false);
    ("mostzapped_24h", true); ("mostzapped_12h", true); ("mostzapped_4h", true); ("mostzapped_1h", true) ]

let kept_kinds = [ 0; 1; Kind.referenced_event; Kind.media_metadata; Kind.user_primal_names; Kind.membership_legend_customization; Kind.membership_cohorts ]

(* scored_(est; selector): explore_global_trending / explore_global_mostzapped with gm_mode *)
let scored_args (selector : string) : H.scored_args option =
  let mk timeframe hours gm_mode =
    Some
      { H.timeframe; scope_pubkeys = []; limit = 100; limit2 = None; created_after = Utils.current_time () - (hours * 3600); since = None; until = None; offset = 0;
        group_by_pubkey = true; user_pubkey = None; kinds = None; gm_mode; pg = false; humaness = false }
  in
  match String.split_on_char '_' selector with
  | [ "trending"; h ] -> mk "trending" (int_of_string (String.sub h 0 (String.length h - 1))) (Some "nogm")
  | [ "gm"; "trending"; h ] -> mk "trending" (int_of_string (String.sub h 0 (String.length h - 1))) (Some "gmonly")
  | [ "classic"; "trending"; h ] -> mk "trending" (int_of_string (String.sub h 0 (String.length h - 1))) None
  | [ "mostzapped"; h ] -> mk "mostzapped" (int_of_string (String.sub h 0 (String.length h - 1))) None
  | _ -> None

let re_mention = Str.regexp {|\b\(nostr:\)?\(\(note\|npub\|naddr\|nevent\|nprofile\)1[A-Za-z0-9_]+\)\b|}
let re_url = Str.regexp {|https?://\(www\.\)?[-a-zA-Z0-9@:%._+~#=\128-\255]+\.[a-zA-Z0-9]+[-a-zA-Z0-9@:%_+.~#?&/=\128-\255]*|}

(* text_query: Ollama /api/chat, gemma3n:e4b, the gaming prompt *)
let does_note_game_trending ~net ~clock ~(ollama_host : string) (content : string) : string =
  let prompt =
    "Does the author of this note explicitly and literally ask users to zap his note, repost his note, or reply to it?\n\
     The response should begin with either \"yes\" or \"no\" as the answer to the question.\n\
     The response's second line should include an explanation. \n\n\
     If note contains phrases like this answer \"no\":\n\
     - \"share this around\"\n\
     - \"do you know anyone who would be willing\"\n\
     - \"would love to hear people's thoughts on this\"\n\n\
     <note>\n" ^ content ^ "\n</note>\n"
  in
  let body =
    Yojson.Safe.to_string
      (`Assoc [ ("model", `String "gemma3n:e4b"); ("options", `Assoc [ ("num_predict", `Int 2048) ]); ("stream", `Bool false); ("messages", `List [ `Assoc [ ("role", `String "user"); ("content", `String prompt) ] ]) ])
  in
  match Http.request ~net ~clock ~timeout:10.0 ~meth:"POST" ~headers:[ ("Content-Type", "application/json") ] ~body ("http://" ^ ollama_host ^ "/api/chat") with
  | Some r when r.Http.status = 200 -> (
      match Yojson.Safe.from_string r.body with
      | `Assoc f -> ( match List.assoc_opt "message" f with Some (`Assoc m) -> ( match List.assoc_opt "content" m with Some (`String s) -> s | _ -> failwith "ollama: no content") | _ -> failwith "ollama: no message")
      | _ -> failwith "ollama: bad json")
  | Some r -> failwith (Printf.sprintf "ollama: HTTP %d" r.Http.status)
  | None -> failwith "ollama: request failed"

let cache_set (dbh : Postgres.dbh) ~(key : string) ~(value_json : string) : unit =
  ignore [%pgsql dbh "insert into cache (key, value, updated_at) values ($key, $value_json::jsonb, now()) on conflict (key) do update set value = excluded.value, updated_at = now()"]

(* explore_topics_: the hashtags of the last day among authors above the humaness threshold *)
let explore_topics (dbh : Postgres.dbh) ~created_after : string =
  let created_after = Int64.of_int created_after in
  (* the threshold is fetched once and passed as a parameter, as Julia passes TrustRank.humaness_threshold[]:
     inline, humaness_threshold_trustrank() (a table-reading SQL function, not inlinable) runs its
     top-50000 sort once per joined row and holds the table's share lock for many minutes *)
  let threshold = match [%pgsql dbh "select humaness_threshold_trustrank()"] with Some t :: _ -> t | _ -> 0.0 in
  let rows =
    [%pgsql dbh
      "select eh.hashtag, count(1) as cnt from event_hashtags eh, events es, pubkey_trustrank tr \
       where eh.created_at >= $created_after and eh.event_id = es.id and es.pubkey = tr.pubkey and tr.rank > $threshold \
         and not (eh.hashtag = any (array['nsfw', 'sexpervertsyndicate']::varchar[])) \
       group by eh.hashtag order by cnt desc limit 200"]
  in
  let d = List.filter_map (function Some h, Some c -> Some (h, `Int (Int64.to_int c)) | _ -> None) rows in
  Yojson.Safe.to_string (`List [ `Assoc [ ("kind", `Int Kind.hashtags_2); ("content", `String (Yojson.Safe.to_string (`Assoc d))) ] ])

let message_kind (m : string) : int option = match Yojson.Safe.from_string m with `Assoc f -> ( match List.assoc_opt "kind" f with Some (`Int k) -> Some k | _ -> None) | _ -> None | exception _ -> None

let run_once ~(cfg : Config.t) ~(api_cfg : Primal_api.Config.t) ~net ~clock ~proc_mgr : unit =
  let ctx = { H.cfg = api_cfg; clock; conn_id = 0; subid = "jobs" } in
  let report = ref [ Printf.sprintf "updated at %s" (Procinfo.timestamp ()) ] in
  let report_lock = Mutex.create () in
  let cached : (string, string * string) Hashtbl.t = Hashtbl.create 64 in
  let process_content (content : string) : string * string =
    match Hashtbl.find_opt cached content with
    | Some r -> r
    | None ->
        let c = Str.global_replace re_url "" (Str.global_replace re_mention "" content) in
        let r = (c, does_note_game_trending ~net ~clock ~ollama_host:(Option.get cfg.ollama_host) c) in
        Hashtbl.replace cached content r;
        r
  in
  Fiber.List.iter ~max_fibers:8
    (fun (selector, gaming_detection) ->
      try
        let gaming_detection = gaming_detection && cfg.ollama_host <> None in
        let a = match scored_args selector with Some a -> a | None -> failwith selector in
        let msgs = match H.scored_content ctx a with Some m -> m | None -> failwith (selector ^ ": scored_content failed") in
        let msgs =
          List.map
            (fun m ->
              match Yojson.Safe.from_string m with
              | `Assoc f when gaming_detection && List.assoc_opt "kind" f = Some (`Int 1) -> (
                  match List.assoc_opt "content" f with
                  | Some (`String content) ->
                      let c, r = process_content content in
                      if String.starts_with ~prefix:"yes" (String.lowercase_ascii r) then begin
                        Mutex.lock report_lock;
                        report := r :: "------" :: c :: "-------------------------------" :: !report;
                        Mutex.unlock report_lock;
                        Yojson.Safe.to_string (`Assoc (List.map (fun (k, v) -> if k = "content" then (k, `String ("[G] " ^ content)) else (k, v)) f))
                      end
                      else m
                  | _ -> m)
              | _ -> m)
            msgs
        in
        let kept = List.filter (fun m -> match message_kind m with Some k -> List.mem k kept_kinds | None -> false) msgs in
        H.with_cache ctx (fun c -> cache_set (Primal_api_db.Db.raw c) ~key:("precalculated_analytics_" ^ selector ^ cfg.analytics_key_suffix) ~value_json:("[" ^ String.concat "," kept ^ "]"));
        log "%s: %d messages" selector (List.length kept)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> log "%s: %s" selector (Printexc.to_string exn))
    precals;
  (match cfg.gaming_report_command with
  | Some (prog :: args) when prog <> "" -> (
      let text = "<pre>" ^ String.concat "\n" (List.rev !report) ^ "</pre>\n" in
      try
        Switch.run (fun sw ->
            let r, w = Eio.Process.pipe ~sw proc_mgr in
            let child = Eio.Process.spawn ~sw proc_mgr ~stdin:r (prog :: args) in
            Eio.Flow.copy_string text w;
            Eio.Flow.close w;
            match Eio.Process.await child with `Exited 0 -> () | s -> log "gaming report: %s" (Fmt.str "%a" Eio.Process.pp_status s))
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> log "gaming report: %s" (Printexc.to_string exn))
  | _ -> ());
  (* explore_topics scans a day of event_hashtags: its own connection, no statement timeout (the API pool's 15 s wraps the whole call) *)
  (try
     let dbh = Postgres.connect ~statement_timeout_ms:0 ~application_name:"primal-jobs-analytics" cfg.cache_db in
     Fun.protect ~finally:(fun () -> try Postgres.close dbh with _ -> ()) (fun () ->
         cache_set dbh ~key:("precalculated_analytics_explore_topics" ^ cfg.analytics_key_suffix) ~value_json:(explore_topics dbh ~created_after:(Utils.current_time () - (24 * 3600))))
   with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn -> log "explore_topics: %s" (Printexc.to_string exn))

let run ~(cfg : Config.t) ~net ~clock ~proc_mgr ~(stop : unit Promise.t) : unit =
  let api_cfg = Primal_api.Config.of_json_file cfg.api_config_path in
  Api_context.init ~cfg ~net;
  Periodic.run ~clock ~stop ~period:cfg.analytics_period_s ~label:"analytics" (fun () -> run_once ~cfg ~api_cfg ~net ~clock ~proc_mgr)
