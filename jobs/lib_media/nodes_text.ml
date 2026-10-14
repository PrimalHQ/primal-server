(* media_analysis.rs import_text_event_pn (PrimalServer.DB): nomic-embed-text embedding of the
   first 500 chars into event_embedding, llama3.1 language / sentiment / categories into
   text_metadata (algo "10"). *)

open Procgraph

let ollama (ctx : ctx) (path : string) (body : Pgj.t) : Pgj.t =
  match Media_tools.post_json ctx ~timeout:ctx.cfg.ai_timeout_s (Printf.sprintf "http://%s:11434%s" ctx.cfg.ai_host path) body with Some j -> j | None -> fail "ollama %s failed" path

let text_features (ctx : ctx) (text : string) : float list =
  match Hls.get (ollama ctx "/api/embeddings" (`Assoc [ ("model", `String "nomic-embed-text"); ("keep_alive", `String "180m"); ("prompt", `String text) ])) [ "embedding" ] with
  | `List l -> List.filter_map Pgj.as_float l
  | _ -> fail "no embedding"

let text_query (ctx : ctx) ?(model = "llama3.1") ~(num_predict : int) (query : string) : string =
  match Hls.gets (ollama ctx "/api/chat" (`Assoc [ ("model", `String model); ("keep_alive", `String "180m"); ("options", `Assoc [ ("num_predict", `Int num_predict) ]); ("stream", `Bool false); ("messages", `List [ `Assoc [ ("role", `String "user"); ("content", `String query) ] ]) ])) [ "message"; "content" ] with
  | Some s -> s
  | None -> fail "no chat response"

let re_nostr = Re.compile (Re.seq [ Re.opt (Re.str "nostr:"); Re.str "nostr1"; Re.rep1 (Re.alt [ Re.rg 'a' 'z'; Re.digit ]) ])
let re_url = Re.compile (Re.seq [ Re.str "http"; Re.opt (Re.char 's'); Re.str "://"; Re.rep1 (Re.compl [ Re.set " \t\n" ]) ])
let re_hashtag = Re.compile (Re.seq [ Re.char '#'; Re.rep1 (Re.compl [ Re.set " \t\n" ]) ])
let re_ws = Re.compile (Re.rep1 (Re.set " \t\n\r"))

let clean_text (t : string) : string =
  let t = Re.replace_string re_nostr ~by:" " t in
  let t = Re.replace_string re_url ~by:" " t in
  Re.replace_string re_hashtag ~by:" " t

let utf8_prefix (s : string) (n : int) : string =
  (* first n code points *)
  let b = Buffer.create n in
  let count = ref 0 and i = ref 0 in
  while !i < String.length s && !count < n do
    let c = Char.code s.[!i] in
    let len = if c < 0x80 then 1 else if c < 0xE0 then 2 else if c < 0xF0 then 3 else 4 in
    Buffer.add_string b (String.sub s !i (min len (String.length s - !i)));
    i := !i + len;
    incr count
  done;
  Buffer.contents b

let words s = List.filter (( <> ) "") (Re.split re_ws s)
let categories = [ "art"; "bitcoin"; "finance"; "food"; "fun and memes"; "gaming"; "health and fitness"; "human rights"; "music"; "news"; "nostr"; "philosophy"; "photography"; "podcasts"; "primal"; "sports"; "tech"; "travel" ]

let import_text_event_pn (ctx : ctx) (n : node) : Pgj.t =
  let eid_hex = match Pgj.as_tuple n.args with e :: _ -> Option.get (Pgj.as_hex_id e) | _ -> fail "invalid args" in
  let content, kind = match q ctx "select content, kind from events where id = decode($1,'hex') limit 1" [ Some eid_hex ] with [ c; k ] :: _ -> (Option.value c ~default:"", Option.value (Option.bind k int_of_string_opt) ~default:0) | _ -> fail "Event not found: %s" eid_hex in
  if kind <> 1 && kind <> 30023 then fail "Event kind %d not supported for text analysis" kind;
  let summary = utf8_prefix content 500 in
  let tstart = Utils.current_time () and t0 = Unix.gettimeofday () in
  let emb = text_features ctx summary in
  let dt = Unix.gettimeofday () -. t0 in
  ignore
    (q ctx "insert into event_embedding (eid, model, md, emb, t) values (decode($1,'hex'), $2, $3::jsonb, $4::float4[]::vector, now()) on conflict (eid, model) do update set md = event_embedding.md || excluded.md, emb = excluded.emb, t = excluded.t"
       [ Some eid_hex; Some "nomic-embed-text"; Some (Pgj.to_string (`Assoc [ ("algo", `String "9"); ("model", `String "nomic-embed-text"); ("size", `Int (List.length emb)); ("tstart", `Int tstart); ("dt", `Float dt) ])); Some ("{" ^ String.concat "," (List.map Pgj.julia_float emb) ^ "}") ]);
  let tstart2 = Utils.current_time () and t1 = Unix.gettimeofday () in
  let sample = utf8_prefix (clean_text summary) 300 in
  let lang = match words (String.lowercase_ascii (text_query ctx ~num_predict:50 (Printf.sprintf "````\n%s\n````\nin what language is this text written in? answer with just one word." sample))) with w :: _ -> Some w | [] -> None in
  let sentiment = List.find_opt (fun w -> List.mem w [ "positive"; "neutral"; "negative" ]) (words (String.lowercase_ascii (text_query ctx ~num_predict:50 (Printf.sprintf "````\n%s\n````\nis sentiment of this text positive, neutral, negative? answer with just one word." sample)))) in
  let cats_unparsed = text_query ctx ~num_predict:500 (Printf.sprintf "````\n%s\n````\nin which categories would you classify this text? possible categories are %s. answer with list of categories. one category name from possible categories per line. each line starts with -" sample (String.concat ", " (List.map (fun c -> "`" ^ c ^ "`") categories))) in
  let cats = List.filter_map (fun line -> let l = String.trim line in let l = String.trim (if String.length l > 0 && l.[0] = '-' then String.sub l 1 (String.length l - 1) else l) in if List.mem l categories then Some (String.map (fun c -> if c = ' ' then '-' else c) l) else None) (String.split_on_char '\n' cats_unparsed) in
  let md = `Assoc [ ("algo", `String "10"); ("model", `String "llama3.1"); ("tstart", `Int tstart2); ("dt", `Float (Unix.gettimeofday () -. t1)); ("clean_text", `String sample); ("lang", Pgj.opt (fun s -> `String s) lang); ("sentiment", Pgj.opt (fun s -> `String s) sentiment); ("categories_unparsed", `String cats_unparsed); ("categories", `List (List.map (fun c -> `String c) cats)) ] in
  ignore
    (q ctx "insert into text_metadata (sha256, model, md, t, text, event_id) values (decode($1,'hex'), $2, $3::jsonb, now(), $4, decode($5,'hex')) on conflict (sha256, model) do update set md = text_metadata.md || excluded.md, t = excluded.t, text = excluded.text, event_id = excluded.event_id"
       [ Some (Pgj.sha256_hex content); Some "llama3.1"; Some (Pgj.to_string md); Some content; Some eid_hex ]);
  `Assoc [ ("event_id", `String eid_hex); ("content_length", `Int (String.length content)); ("embedding_size", `Int (List.length emb)); ("metadata", md) ]

let register () = register ~mod_:"PrimalServer.DB" ~func:"import_text_event_pn" import_text_event_pn
