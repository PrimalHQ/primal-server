(* Advanced search (dag.jl parse_search_query / to_sql / search, app_ext.jl advanced_search):
   a PEG-faithful parser of the query language into [op], a SQL builder over the advsearch view
   and its companion tables, and Julia's windowed execution (fetch_results: hour-wide windows
   walking back from `until`, widening fourfold while empty, a nine-second budget, partial results
   on timeout). The SQL is dynamic, so it runs through [Postgres.query] with text parameters. *)

(* {1 AST} (dag.jl module O) *)

type from = From_pk of string | From_addr of int * string * string | From_word of string
type ref_ = Ref_pk of string | Ref_eid of string

type op =
  | Or of op list
  | And of op list
  | Word of string
  | Phrase of string
  | HashTag of string
  | NotWord of string
  | NotPhrase of string
  | NotHashTag of string
  | Since of int
  | Until of int
  | EventId of string (* raw *)
  | EventAddr of int * string * string (* kind, raw pubkey, identifier *)
  | From of from
  | To of string
  | Mention of string
  | Kind of int
  | RepliesToKind of int
  | PostType of string
  | Filter of string
  | Url of string
  | List of string
  | Orientation of string
  | MinDuration of float
  | MaxDuration of float
  | Emoticon of string
  | Question
  | Category of string
  | MinInteractions of int
  | MaxInteractions of int
  | Scope of string
  | MinWords of int
  | MaxWords of int
  | MaxChars of int
  | MinLongReplies of int
  | Lang of string
  | Ref of ref_
  | ZappedBy of string
  | OrderBy of string
  | EventStatsField of string * string * int (* field, ">=" | "<=", argument *)
  | MinTrustRank of int
  | Features of string list
  | PAS of string list

exception Parse_error of string

(* {1 Parser} *)

type st = { s : string; n : int }

let peek st i = if i < st.n then Some st.s.[i] else None
let starts st i (p : string) = let l = String.length p in i + l <= st.n && String.sub st.s i l = p
let is_digit c = c >= '0' && c <= '9'
let is_alpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
(* Julia isletter: any non-ASCII byte is taken as part of a letter *)
let is_letter c = is_alpha c || Char.code c >= 0x80
let is_word_char c = is_letter c || is_digit c || c = '_' || c = '-'
let is_ts_char c = is_letter c || is_digit c || c = '-' || c = '_' || c = ':'
let is_alnum c = is_letter c || is_digit c
let is_hex c = is_digit c || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')

(* some(satisfy p): greedy, at least one *)
let some st i p =
  let j = ref i in
  while !j < st.n && p st.s.[!j] do incr j done;
  if !j = i then None else Some (String.sub st.s i (!j - i), !j)

let ws st i = let j = ref i in while !j < st.n && st.s.[!j] = ' ' do incr j done; !j

let number st i =
  let neg, i' = if peek st i = Some '-' then (true, i + 1) else (false, i) in
  match some st i' is_digit with
  | Some (d, j) -> ( match int_of_string_opt d with Some v -> Some ((if neg then -v else v), j) | None -> None)
  | None -> None

let keyword st i (kw : string) = if starts st i kw then Some (i + String.length kw) else None

(* Julia's `score(v)`: percentile of the 24-hour trending scores, 0..100 -> score24h *)
let trending_scores : (unit -> int list) ref = ref (fun () -> [])

let score_of_pct v =
  let v = Float.max 0.0 (Float.min 1.0 (float_of_int v /. 100.0)) in
  match !trending_scores () with
  | [] -> 0
  | l ->
      let n = List.length l in
      let i = int_of_float (float_of_int (n - 1) *. v) in
      List.nth l (max 0 (min (n - 1) i))

let decode_pubkey (s : string) : string option =
  if String.length s = 64 && String.for_all is_hex s then Hex_util.decode_opt s
  else match Bech32.nip19_decode s with Some (Bech32.Npub pk) | Some (Bech32.Nprofile pk) -> Some pk | _ -> None

(* yyyy-mm-dd[_HH:MM:SS] to unix (Julia DateTime(replace(ts, '_' => 'T'))) *)
let parse_ts (s : string) : int =
  let s = String.map (fun c -> if c = '_' then 'T' else c) s in
  let date, time = match String.index_opt s 'T' with Some k -> (String.sub s 0 k, String.sub s (k + 1) (String.length s - k - 1)) | None -> (s, "") in
  match List.map int_of_string_opt (String.split_on_char '-' date) with
  | [ Some y; Some mo; Some d ] ->
      let h, mi, se =
        match List.map int_of_string_opt (String.split_on_char ':' time) with
        | [ Some h; Some mi; Some se ] -> (h, mi, se)
        | [ Some h; Some mi ] -> (h, mi, 0)
        | _ -> (0, 0, 0)
      in
      let t, _ = Unix.mktime { Unix.tm_sec = se; tm_min = mi; tm_hour = h; tm_mday = d; tm_mon = mo - 1; tm_year = y - 1900; tm_wday = 0; tm_yday = 0; tm_isdst = false } in
      (* mktime is local time; Julia's datetime2unix is UTC: correct by the zone offset *)
      let utc = Unix.gmtime t and loc = Unix.localtime t in
      let off = ((loc.Unix.tm_hour - utc.Unix.tm_hour) * 3600) + ((loc.Unix.tm_min - utc.Unix.tm_min) * 60) in
      let off = if loc.Unix.tm_yday <> utc.Unix.tm_yday then (if loc.Unix.tm_yday > utc.Unix.tm_yday || loc.Unix.tm_year > utc.Unix.tm_year then off + 86400 else off - 86400) else off in
      int_of_float t + off
  | _ -> raise (Parse_error ("bad timestamp " ^ s))

let since_of (ts : string) ~(now : int) : int =
  match ts with
  | "last1h" -> now - 3600
  | "last4h" -> now - (4 * 3600)
  | "last12h" -> now - (12 * 3600)
  | "yesterday" -> now - (24 * 3600)
  | "lastweek" -> now - (7 * 24 * 3600)
  | "last2weeks" -> now - (14 * 24 * 3600)
  | "lastmonth" -> now - (30 * 24 * 3600)
  | "lastyear" -> now - (365 * 24 * 3600)
  | t -> parse_ts t

let rec or_expr st i ~now : (op * int) option =
  match exprs st i ~now with
  | None -> None
  | Some (left, j) -> (
      match keyword st j "OR " with
      | Some k -> ( match or_expr st (ws st k) ~now with Some (right, l) -> Some (Or [ left; right ], l) | None -> Some (left, j))
      | None -> Some (left, j))

and exprs st i ~now : (op * int) option =
  let rec loop i acc =
    match expr st i ~now with
    | Some (e, j) -> loop (ws st j) (e :: acc)
    | None -> (List.rev acc, i)
  in
  match loop i [] with [], _ -> None | [ e ], j -> Some (e, j) | es, j -> Some (And es, j)

and expr st i ~now : (op * int) option =
  if starts st i "OR " then None
  else
    let word j = some st j is_word_char in
    let num kw f = match keyword st i kw with Some j -> ( match number st j with Some (v, k) -> Some (f v, k) | None -> None) | None -> None in
    let wordop kw f = match keyword st i kw with Some j -> ( match word j with Some (w, k) -> Some (f w, k) | None -> None) | None -> None in
    let pubkey j =
      (* hex64 | npub... | nprofile... *)
      if j + 64 <= st.n && String.for_all is_hex (String.sub st.s j 64) && (j + 64 = st.n || not (is_word_char st.s.[j + 64])) then
        Some (Hex_util.decode_exn (String.sub st.s j 64), j + 64)
      else if starts st j "npub" || starts st j "nprofile" then
        match some st j is_alnum with
        | Some (tok, k) -> ( match decode_pubkey tok with Some pk -> Some (pk, k) | None -> raise (Parse_error ("bad pubkey " ^ tok)))
        | None -> None
      else None
    in
    let event j =
      if starts st j "note" || starts st j "nevent" || starts st j "naddr" then
        match some st j is_alnum with
        | Some (tok, k) -> (
            match Bech32.nip19_decode tok with
            | Some (Bech32.Note eid) | Some (Bech32.Nevent eid) -> Some (EventId eid, k)
            | Some (Bech32.Naddr { kind; author; identifier }) -> Some (EventAddr (kind, author, identifier), k)
            | _ -> raise (Parse_error ("bad event " ^ tok)))
        | None -> None
      else None
    in
    let alts : (unit -> (op * int) option) list =
      [
        (fun () -> match keyword st i "(" with Some j -> ( match or_expr st (ws st j) ~now with Some (e, k) -> ( match keyword st k ")" with Some l -> Some (e, l) | None -> None) | None -> None) | None -> None);
        (fun () -> match keyword st i "-\"" with Some j -> ( match some st j (fun c -> c <> '"') with Some (p, k) -> ( match keyword st k "\"" with Some l -> Some (NotPhrase p, l) | None -> None) | None -> None) | None -> None);
        (fun () -> match keyword st i "-" with Some j -> ( match word j with Some (w, k) -> Some (NotWord w, k) | None -> None) | None -> None);
        (fun () -> match keyword st i "-#" with Some j -> ( match word j with Some (w, k) -> Some (NotHashTag w, k) | None -> None) | None -> None);
        (fun () -> match keyword st i "#" with Some j -> ( match word j with Some (w, k) -> Some (HashTag w, k) | None -> None) | None -> None);
        (fun () -> match keyword st i "since:" with Some j -> ( match some st j is_ts_char with Some (t, k) -> Some (Since (since_of t ~now), k) | None -> None) | None -> None);
        (fun () -> match keyword st i "until:" with Some j -> ( match some st j is_ts_char with Some (t, k) -> Some (Until (parse_ts t), k) | None -> None) | None -> None);
        (fun () ->
          match keyword st i "from:" with
          | Some j -> (
              match pubkey j with
              | Some (pk, k) -> Some (From (From_pk pk), k)
              | None -> (
                  match event j with
                  | Some (EventAddr (kind, pk, id), k) -> Some (From (From_addr (kind, pk, id)), k)
                  | _ -> ( match word j with Some (w, k) -> Some (From (From_word w), k) | None -> None)))
          | None -> None);
        (fun () -> match keyword st i "to:" with Some j -> ( match pubkey j with Some (pk, k) -> Some (To pk, k) | None -> None) | None -> None);
        (fun () -> match keyword st i "@" with Some j -> ( match pubkey j with Some (pk, k) -> Some (Mention pk, k) | None -> None) | None -> None);
        (fun () -> num "kind:" (fun v -> Kind v));
        (fun () -> num "repliestokind:" (fun v -> RepliesToKind v));
        (fun () -> wordop "post:" (fun w -> PostType w));
        (fun () -> event i);
        (fun () -> num "minduration:" (fun v -> MinDuration (float_of_int v)));
        (fun () -> num "maxduration:" (fun v -> MaxDuration (float_of_int v)));
        (fun () -> wordop "filter:" (fun w -> Filter w));
        (fun () -> wordop "url:" (fun w -> Url w));
        (fun () -> wordop "orientation:" (fun w -> Orientation w));
        (fun () -> wordop "list:" (fun w -> List w));
        (fun () -> match List.find_map (fun e -> match keyword st i e with Some j -> Some (Emoticon e, j) | None -> None) [ ":)"; ":("; ":|" ] with Some r -> Some r | None -> None);
        (fun () -> match keyword st i "?" with Some j -> Some (Question, j) | None -> None);
        (fun () -> wordop "category:" (fun w -> Category w));
        (fun () -> num "mininteractions:" (fun v -> MinInteractions v));
        (fun () -> num "maxinteractions:" (fun v -> MaxInteractions v));
        (fun () -> wordop "scope:" (fun w -> Scope w));
        (fun () -> num "minwords:" (fun v -> MinWords v));
        (fun () -> num "maxwords:" (fun v -> MaxWords v));
        (fun () -> num "maxchars:" (fun v -> MaxChars v));
        (fun () -> num "minlongreplies:" (fun v -> MinLongReplies v));
        (fun () -> wordop "lang:" (fun w -> Lang w));
        (fun () -> match keyword st i "features:" with Some j -> ( match some st j (fun c -> is_alnum c || c = '-' || c = '_' || c = ',') with Some (f, k) -> Some (Features (String.split_on_char ',' f), k) | None -> None) | None -> None);
        (fun () ->
          match keyword st i "ref:" with
          | Some j -> (
              match word j with
              | Some (w, k) -> (
                  match Bech32.nip19_decode w with
                  | Some (Bech32.Npub pk) -> Some (Ref (Ref_pk pk), k)
                  | Some (Bech32.Note eid) -> Some (Ref (Ref_eid eid), k)
                  | _ -> raise (Parse_error ("bad ref " ^ w)))
              | None -> None)
          | None -> None);
        (fun () -> match keyword st i "zappedby:" with Some j -> ( match pubkey j with Some (pk, k) -> Some (ZappedBy pk, k) | None -> None) | None -> None);
        (fun () -> wordop "orderby:" (fun w -> OrderBy w));
        (fun () -> num "minscore:" (fun v -> EventStatsField ("score", ">=", score_of_pct v)));
        (fun () -> num "maxscore:" (fun v -> EventStatsField ("score", "<=", score_of_pct v)));
        (fun () -> num "minlikes:" (fun v -> EventStatsField ("likes", ">=", v)));
        (fun () -> num "maxlikes:" (fun v -> EventStatsField ("likes", "<=", v)));
        (fun () -> num "minzaps:" (fun v -> EventStatsField ("zaps", ">=", v)));
        (fun () -> num "maxzaps:" (fun v -> EventStatsField ("zaps", "<=", v)));
        (fun () -> num "minreplies:" (fun v -> EventStatsField ("replies", ">=", v)));
        (fun () -> num "maxreplies:" (fun v -> EventStatsField ("replies", "<=", v)));
        (fun () -> num "minreposts:" (fun v -> EventStatsField ("reposts", ">=", v)));
        (fun () -> num "maxreposts:" (fun v -> EventStatsField ("reposts", "<=", v)));
        (fun () -> num "minsatszapped:" (fun v -> EventStatsField ("satszapped", ">=", v)));
        (fun () -> num "maxsatszapped:" (fun v -> EventStatsField ("satszapped", "<=", v)));
        (fun () -> num "mintrustrank:" (fun v -> MinTrustRank v));
        (fun () -> match keyword st i "pas:" with Some j -> ( match some st j (fun c -> is_alnum c || c = '-' || c = '_' || c = ',') with Some (f, k) -> Some (PAS (String.split_on_char ',' f), k) | None -> None) | None -> None);
        (fun () -> match word i with Some (w, k) -> Some (Word w, k) | None -> None);
        (fun () -> match keyword st i "\"" with Some j -> ( match some st j (fun c -> c <> '"') with Some (p, k) -> ( match keyword st k "\"" with Some l -> Some (Phrase p, l) | None -> None) | None -> None) | None -> None);
      ]
    in
    List.find_map (fun f -> f ()) alts

let parse ?(now = Utils.current_time ()) (query : string) : op =
  let query = String.map (fun c -> if c = '\n' then ' ' else c) query in
  let st = { s = query; n = String.length query } in
  match or_expr st (ws st 0) ~now with
  | Some (e, j) when ws st j = st.n -> e
  | _ -> raise (Parse_error "query does not parse")

let rec ops (e : op) : op list = match e with Or l | And l -> List.concat_map ops l | o -> [ o ]

(* {1 SQL} (dag.jl to_sql) *)

type sql = { text : string; params : string option list; orderby_key : string }

let hex_param (raw : string) = "\\x" ^ Hex_util.encode raw

let to_sql ~(user_pubkey : string) (expr : op) ~since ~until ~(kinds : int list) : sql =
  let expr = match expr with Or _ | And _ -> expr | o -> And [ o ] in
  let params = ref [] and np = ref 0 in
  let p (v : string) = incr np; params := Some v :: !params; Printf.sprintf "$%d" !np in
  let pi (v : int) = p (string_of_int v) in
  let pb (raw : string) = p (hex_param raw) in
  let tables = ref [] in
  let t (name : string) = if not (List.mem name !tables) then tables := !tables @ [ name ]; name in
  let conds = ref [] and ctes = ref [] in
  let cond s = conds := !conds @ [ s ] in
  let cte s = ctes := !ctes @ [ s ] in
  let follows_cte table = ignore (t table); cte (Printf.sprintf "with %s as (select pf1.pubkey from pubkey_followers pf1 where pf1.follower_pubkey = %s)" table (pb user_pubkey)) in
  let network_cte table =
    ignore (t table);
    cte
      (Printf.sprintf
         "with %s as ((select pf1.pubkey from pubkey_followers pf1 where pf1.follower_pubkey = %s) union (select pf3.pubkey from pubkey_followers pf2, pubkey_followers pf3 where pf2.follower_pubkey = %s and pf3.follower_pubkey = pf2.pubkey))"
         table (pb user_pubkey) (pb user_pubkey))
  in
  let top = match expr with Or l | And l -> l | o -> [ o ] in
  let adv = t "advsearch" in
  let kind, explicit = match List.find_map (function Kind k -> Some k | _ -> None) top with Some k -> (k, true) | None -> (1, false) in
  if explicit then cond (Printf.sprintf "%s.kind = %s" adv (pi kind));
  let orderkey = ref "" and orderby = ref "" in
  (if kind = 1 then begin
     if not explicit then cond (Printf.sprintf "%s.kind IN (%s, %s, %s)" adv (pi 1) (pi 1068) (pi 6969));
     orderkey := adv ^ ".created_at";
     cond (Printf.sprintf "%s.created_at >= %s" adv (pi since));
     cond (Printf.sprintf "%s.created_at <= %s" adv (pi until));
     orderby := adv ^ ".created_at"
   end
   else if kind = 30023 then begin
     let reads = t "reads" in
     orderkey := reads ^ ".published_at";
     cond (Printf.sprintf "%s.id = %s.latest_eid" adv reads);
     cond (Printf.sprintf "%s.published_at >= %s" reads (pi since));
     cond (Printf.sprintf "%s.published_at <= %s" reads (pi until));
     orderby := reads ^ ".published_at"
   end
   else begin
     orderkey := adv ^ ".created_at";
     cond (Printf.sprintf "%s.created_at >= %s" adv (pi since));
     cond (Printf.sprintf "%s.created_at <= %s" adv (pi until));
     orderby := adv ^ ".created_at"
   end);
  if kinds <> [] then cond (Printf.sprintf "%s.kind IN (%s)" adv (String.concat ", " (List.map pi kinds)));
  (match List.find_map (function OrderBy f -> Some f | _ -> None) top with
  | Some "interactions" ->
      let es = t "event_stats" in
      cond (Printf.sprintf "%s.event_id = %s.id" es adv);
      orderby := Printf.sprintf "(%s.likes + %s.replies + %s.reposts + %s.zaps)" es es es es;
      orderkey := !orderby
  | Some f when List.mem f [ "score"; "likes"; "replies"; "reposts"; "zaps"; "satszapped" ] ->
      let es = t "event_stats" in
      cond (Printf.sprintf "%s.event_id = %s.id" es adv);
      cond (Printf.sprintf "%s.%s > 0" es f);
      orderby := Printf.sprintf "%s.%s" es f;
      orderkey := !orderby
  | Some "score2" -> ()
  | Some f -> raise (Parse_error ("unsupported orderby " ^ f))
  | None -> ());
  cond (Printf.sprintf "NOT EXISTS (SELECT 1 FROM filterlist WHERE grp in ('csam', 'impersonation') AND target_type = 'event' AND target = %s.id AND blocked LIMIT 1)" adv);
  cond
    (Printf.sprintf
       "NOT EXISTS (SELECT 1 FROM events es, filterlist fl WHERE es.id = %s.id AND fl.target = es.pubkey AND fl.target_type = 'pubkey' AND fl.grp in ('csam', 'impersonation') AND fl.blocked LIMIT 1)"
       adv);
  List.iter
    (function
      | RepliesToKind k ->
          ignore (t "basic_tags btrtk"); ignore (t "events esrtk");
          cond (Printf.sprintf "btrtk.id = %s.id" adv);
          cond "btrtk.kind = 1";
          cond (Printf.sprintf "btrtk.tag = 'e' and btrtk.arg1 = esrtk.id and esrtk.kind = %s" (pi k))
      | PostType "root" ->
          cond (Printf.sprintf "not exists (select 1 from basic_tags btpt where btpt.id = %s.id and btpt.kind in (1, 1068, 6969, 20, 34235, 34236, 1111) and btpt.tag = 'e' and btpt.arg3 = 'root' limit 1)" adv)
      | Scope "myfollows" -> follows_cte "scope_pks"; cond (Printf.sprintf "%s.pubkey = scope_pks.pubkey" adv)
      | Scope "mynetwork" -> network_cte "scope_pks"; cond (Printf.sprintf "%s.pubkey = scope_pks.pubkey" adv)
      | Scope "myfollowsinteractions" ->
          cond
            (Printf.sprintf
               "(exists (with scope_pks as (select pf2.pubkey from pubkey_followers pf2 where pf2.follower_pubkey = %s) select 1 from basic_tags btscopeint2, scope_pks where btscopeint2.kind in (1, 6, 7) and btscopeint2.pubkey = scope_pks.pubkey and btscopeint2.tag = 'e' and btscopeint2.arg1 = %s.id) \
                or exists (with scope_pks2 as (select pf2.pubkey from pubkey_followers pf2 where pf2.follower_pubkey = %s) select 1 from scope_pks2 where %s.pubkey = scope_pks2.pubkey) \
                or (%s.pubkey = %s))"
               (pb user_pubkey) adv (pb user_pubkey) adv adv (pb user_pubkey))
      | Scope "mynetworkinteractions" ->
          cond
            (Printf.sprintf
               "exists (select 1 from basic_tags btscopeint2 where btscopeint2.kind in (1, 6, 7) and btscopeint2.tag = 'e' and btscopeint2.arg1 = %s.id and \
                (exists (select 1 from pubkey_followers pf1 where pf1.follower_pubkey = %s and pf1.pubkey = btscopeint2.pubkey limit 1) \
                 or exists (select 1 from pubkey_followers pf2, pubkey_followers pf3 where pf2.follower_pubkey = %s and pf3.follower_pubkey = pf2.pubkey and pf3.pubkey = btscopeint2.pubkey limit 1)))"
               adv (pb user_pubkey) (pb user_pubkey))
      | Scope "notmyfollows" -> follows_cte "scope_pks"; cond (Printf.sprintf "not exists (select 1 from scope_pks where scope_pks.pubkey = %s.pubkey)" adv)
      | Scope "mutedbyothers" -> ignore (t "cmr_pubkeys_scopes scope_cmrpks"); cond (Printf.sprintf "%s.pubkey = scope_cmrpks.pubkey" adv)
      | Scope "mynotifications" ->
          let pn = t "pubkey_notifications" in
          cond (Printf.sprintf "%s.pubkey = %s" pn (pb user_pubkey));
          cond (Printf.sprintf "%s.type != 1" pn);
          cond (Printf.sprintf "%s.type != 2" pn);
          cond (Printf.sprintf "(%s.id = %s.arg1 or %s.id = %s.arg2)" adv pn adv pn);
          if String.ends_with ~suffix:".created_at" !orderkey then begin
            cond (Printf.sprintf "%s.created_at >= %s" pn (pi since));
            cond (Printf.sprintf "%s.created_at <= %s" pn (pi until))
          end
      | Scope s -> raise (Parse_error ("unsupported scope: " ^ s))
      | Ref r ->
          ignore (t "basic_tags btref");
          cond "btref.kind in (1, 6, 30023)";
          (match r with
          | Ref_eid eid -> cond (Printf.sprintf "btref.arg1 = %s and btref.id = %s.id" (pb eid) adv); cond "btref.tag = 'e'"
          | Ref_pk pk -> cond (Printf.sprintf "btref.arg1 = %s and btref.id = %s.id" (pb pk) adv); cond "btref.tag = 'p'")
      | _ -> ())
    top;
  let rec tosql (o : op) : string option =
    let cs = ref [] in
    let c s = cs := !cs @ [ s ] in
    (match o with
    | And l -> List.iter (fun s -> c s) (List.filter_map tosql l)
    | Or l -> ( match List.filter_map tosql l with [] -> () | subs -> c (String.concat " or " subs))
    | Word w -> c (Printf.sprintf "%s.content_tsv @@ plainto_tsquery('simple', %s)" adv (p w))
    | Phrase ph -> c (Printf.sprintf "%s.content_tsv @@ phraseto_tsquery('simple', %s)" adv (p ph))
    | HashTag h ->
        if kind = 1 then c (Printf.sprintf "%s.hashtag_tsv @@ plainto_tsquery('simple', %s)" adv (p h))
        else if kind = 30023 then c (Printf.sprintf "%s.topics @@ plainto_tsquery('simple', %s)" (t "reads") (p h))
    | NotWord w -> c (Printf.sprintf "%s.content_tsv @@ to_tsquery('simple', %s)" adv (p ("! " ^ w)))
    | NotPhrase ph -> c (Printf.sprintf "not (%s.content_tsv @@ phraseto_tsquery('simple', %s))" adv (p ph))
    | NotHashTag h ->
        if kind = 1 then c (Printf.sprintf "not (%s.hashtag_tsv @@ plainto_tsquery('simple', %s))" adv (p h))
        else if kind = 30023 then c (Printf.sprintf "not (%s.topics @@ plainto_tsquery('simple', %s))" (t "reads") (p h))
    | Since ts -> c (Printf.sprintf "%s.created_at >= %s" adv (pi ts))
    | Until ts -> c (Printf.sprintf "%s.created_at <= %s" adv (pi ts))
    | From (From_pk pk) -> c (Printf.sprintf "%s.pubkey = %s" adv (pb pk))
    | From (From_addr (k, pk, id)) ->
        if k <> 39089 then raise (Parse_error "from: naddr must be a follow list");
        c (Printf.sprintf "%s.pubkey in (select follow_pubkey from follow_lists where pubkey = %s and identifier = %s)" adv (pb pk) (p id))
    | From (From_word w) -> c (Printf.sprintf "%s.pubkey = (select pubkey from verified_users where name = %s and default_name limit 1)" adv (p w))
    | To pk -> c (Printf.sprintf "%s.reply_tsv @@ plainto_tsquery('simple', %s)" adv (p (Hex_util.encode pk)))
    | Mention pk -> c (Printf.sprintf "%s.mention_tsv @@ plainto_tsquery('simple', %s)" adv (p (Hex_util.encode pk)))
    | EventId eid -> c (Printf.sprintf "%s.id = %s" adv (pb eid))
    | EventAddr (_, pk, id) ->
        let reads = t "reads" in
        c (Printf.sprintf "%s.pubkey = %s and %s.identifier = %s and %s.latest_eid = %s.id" reads (pb pk) reads (p id) reads adv)
    | Filter f ->
        if String.length f > 0 && f.[0] = '-' then c (Printf.sprintf "%s.filter_tsv @@ to_tsquery('simple', %s)" adv (p ("! " ^ f)))
        else c (Printf.sprintf "%s.filter_tsv @@ plainto_tsquery('simple', %s)" adv (p f))
    | Url w -> c (Printf.sprintf "%s.url_tsv @@ plainto_tsquery('simple', %s)" adv (p w))
    | Orientation o ->
        let em = t "event_media" and m = t "media" in
        c (Printf.sprintf "%s.event_id = %s.id and %s.url = %s.url and %s.height %s 1.8 * %s.width" em adv em m m (if o = "vertical" then ">" else "<") m)
    | MinDuration d ->
        let em = t "event_media" and m = t "media" in
        c (Printf.sprintf "%s.event_id = %s.id and %s.url = %s.url and %s.duration >= %s and %s.duration > 0" em adv em m m (p (Printf.sprintf "%.17g" d)) m)
    | MaxDuration d ->
        let em = t "event_media" and m = t "media" in
        c (Printf.sprintf "%s.event_id = %s.id and %s.url = %s.url and %s.duration <= %s and %s.duration > 0" em adv em m m (p (Printf.sprintf "%.17g" d)) m)
    | Emoticon e ->
        let tm = t "text_metadata" in
        let sentiment = match e with ":)" -> "positive" | ":(" -> "negative" | _ -> "neutral" in
        c (Printf.sprintf "%s.event_id = %s.id and %s.md->>'sentiment' = %s" tm adv tm (p sentiment))
    | Question ->
        let tm = t "text_metadata" in
        c (Printf.sprintf "%s.event_id = %s.id and %s.md->>'sentiment' = %s" tm adv tm (p "?"))
    | Category cat ->
        let tm = t "text_metadata" in
        c (Printf.sprintf "%s.event_id = %s.id and exists (select 1 where %s = any (select jsonb_array_elements_text(%s.md->'categories')))" tm adv (p cat) tm)
    | EventStatsField (field, oper, arg) ->
        let es = t "event_stats" in
        c (Printf.sprintf "%s.event_id = %s.id and %s.%s %s %s" es adv es field oper (pi arg));
        if String.ends_with ~suffix:".created_at" !orderby then begin
          c (Printf.sprintf "%s.created_at >= %s" es (pi since));
          c (Printf.sprintf "%s.created_at <= %s" es (pi until))
        end
    | MinInteractions n ->
        let es = t "event_stats" in
        c (Printf.sprintf "%s.event_id = %s.id and %s.likes + %s.replies + %s.reposts + %s.zaps >= %s" es adv es es es es (pi n))
    | MaxInteractions n ->
        let es = t "event_stats" in
        c (Printf.sprintf "%s.event_id = %s.id and %s.likes + %s.replies + %s.reposts + %s.zaps <= %s" es adv es es es es (pi n))
    | MinWords n -> let r = t "reads" in c (Printf.sprintf "%s.id = %s.latest_eid and %s.words >= %s" adv r r (pi n))
    | MaxWords n -> let r = t "reads" in c (Printf.sprintf "%s.id = %s.latest_eid and %s.words <= %s" adv r r (pi n))
    | MaxChars n -> let nl = t "note_length" in c (Printf.sprintf "%s.id = %s.eid and %s.length <= %s" adv nl nl (pi n))
    | MinLongReplies n -> let ns = t "note_stats" in c (Printf.sprintf "%s.id = %s.eid and %s.long_replies >= %s" adv ns ns (pi n))
    | MinTrustRank n -> let tr = t "pubkey_trustrank" in c (Printf.sprintf "%s.pubkey = %s.pubkey and %s.rank >= %s" adv tr tr (p (Printf.sprintf "%.17g" (10.0 ** float_of_int n))))
    | Lang l ->
        if kind = 1 then (let tm = t "text_metadata" in c (Printf.sprintf "%s.event_id = %s.id and %s.md->>'lang' = %s" tm adv tm (p l)))
        else if kind = 30023 then (let r = t "reads" in c (Printf.sprintf "%s.id = %s.latest_eid and %s.lang = %s and %s.lang_prob = 1.0" adv r r (p l) r))
    | ZappedBy pk -> let zr = t "zap_receipts" in c (Printf.sprintf "%s.sender = %s and %s.target_eid = %s.id" zr (pb pk) zr adv)
    | Features feats ->
        List.iter
          (function
            | "summary" -> let r = t "reads" in c (Printf.sprintf "%s.summary != '' and %s.image != ''" r r)
            | "bookmarked-by-follows" ->
                follows_cte "bookmarked_by_follows_pks";
                let pb_ = t "pubkey_bookmarks" in
                c (Printf.sprintf "%s.id = %s.ref_event_id and %s.pubkey = bookmarked_by_follows_pks.pubkey" adv pb_ pb_)
            | "cdnmedia" ->
                c (Printf.sprintf "exists (select 1 from event_media cdnmedia_em, media cdnmedia_m where advsearch.id = cdnmedia_em.event_id and cdnmedia_em.url = cdnmedia_m.url and cdnmedia_m.size = 'small' and cdnmedia_m.animated = 1 limit 1)")
            | "mediamemes" ->
                c "exists (select 1 from event_media mediamemes_em, media mediamemes_m, media_metadata mediamemes_md where advsearch.id = mediamemes_em.event_id and mediamemes_em.url = mediamemes_m.url and mediamemes_m.orig_sha256 = mediamemes_md.sha256 and mediamemes_md.model = 'primal' and (mediamemes_md.md->>'meme')::bool limit 1)"
            | _ -> ())
          feats
    | Kind _ | RepliesToKind _ | PostType _ | Scope _ | Ref _ | OrderBy _ | List _ | PAS _ -> ());
    match !cs with [] -> None | l -> Some ("(" ^ String.concat " and " l ^ ")")
  in
  (match tosql expr with Some c -> cond c | None -> ());
  let text =
    Printf.sprintf " %s select %s.id, %s as orderkey from %s where %s order by %s desc " (String.concat ", " !ctes) adv !orderkey (String.concat ", " !tables)
      (String.concat " and " !conds) !orderby
  in
  let orderby_key = match String.rindex_opt !orderby '.' with Some k -> String.sub !orderby (k + 1) (String.length !orderby - k - 1) | None -> !orderby in
  { text; params = List.rev !params; orderby_key }

(* {1 Execution} (dag.jl search + App.fetch_results) *)

type result = { posts : (string * int) list (* hex id, orderkey *); orderby_key : string }

let strip_nostr_prefix (q : string) : string =
  (* nostr:(?=n(pub|profile|ote|event|addr)) -> "" *)
  let re = Str.regexp {|nostr:\(n\(pub\|profile\|ote\|event\|addr\)\)|} in
  Str.global_replace re {|\1|} q

(* DB.re_url: wrap URLs in quotes so they parse as phrases *)
let quote_urls (q : string) : string =
  let hi = String.init 128 (fun i -> Char.chr (128 + i)) in
  let re = Str.regexp ("https?://\\(www\\.\\)?[-a-zA-Z0-9@:%._+~#=" ^ hi ^ "]+\\.[a-zA-Z0-9]+[-a-zA-Z0-9@:%_+.~#?&/=" ^ hi ^ "]*") in
  Str.global_substitute re (fun s -> "\"" ^ Str.matched_string s ^ "\"") q

let has_pas1 (expr : op) : bool =
  match expr with And l -> List.exists (function PAS f -> List.mem "1" f | _ -> false) l | _ -> false

(* the parsed query and whether it carries an orderby (which makes the windows start at [since]) *)
let prepare ~(now : int) (query : string) : op * bool =
  let has_orderby = (try ignore (Str.search_forward (Str.regexp_string "orderby:") query 0); true with Not_found -> false) in
  let query = strip_nostr_prefix query in
  (parse ~now query, has_orderby)

let run ~(dbh : Postgres.dbh) ~(user_pubkey : string) ~(expr : op) ~(has_orderby : bool) ~since ~until ~limit ~offset ~(kinds : int list) ~(now : int) : result =
  let until = match until with Some u -> u | None -> if has_orderby then 1 lsl 61 else now in
  let deadline = Unix.gettimeofday () +. 9.0 in
  let res = ref [] and seen = Hashtbl.create 64 in
  let t = ref until and dt = ref 3600 in
  let want = limit + offset in
  let orderby_key = ref "created_at" in
  (* Julia reads each window through a no-scroll cursor and stops after enough rows: the planner
     then picks a fast-start plan (the GIN index first), where a LIMIT query over a wide window
     bitmap-scans the whole created_at range. A statement timeout ends the search with what it has. *)
  Postgres.exec dbh "begin";
  Fun.protect
    ~finally:(fun () ->
      (try Postgres.exec dbh "rollback" with _ -> ());
      try Postgres.exec dbh "set statement_timeout=30000" with _ -> ())
    (fun () ->
      try
        while List.length !res < want && since <= !t && Unix.gettimeofday () < deadline do
          let s, u = if has_orderby then (since, !t) else (!t - !dt, !t) in
          let sql = to_sql ~user_pubkey expr ~since:s ~until:u ~kinds in
          orderby_key := sql.orderby_key;
          let budget_ms = int_of_float ((deadline -. Unix.gettimeofday ()) *. 1000.) in
          if budget_ms <= 0 then raise Exit;
          Postgres.exec dbh (Printf.sprintf "set statement_timeout=%d" budget_ms);
          let rows =
            try
              ignore (Postgres.query dbh ("declare cur no scroll cursor for " ^ sql.text) sql.params);
              let rows = Postgres.query dbh (Printf.sprintf "fetch %d from cur" (want - List.length !res + Hashtbl.length seen)) [] in
              Postgres.exec dbh "close cur";
              rows
            with e -> if Postgres.is_connection_error e then raise e else raise Exit
          in
          let added = ref 0 and last = ref None in
          List.iter
            (fun row ->
              match row with
              | [ Some id; Some ok ] when List.length !res < want ->
                  let id = if String.length id > 2 && String.sub id 0 2 = "\\x" then String.sub id 2 (String.length id - 2) else Hex_util.encode id in
                  let okv = int_of_string_opt ok |> Option.value ~default:0 in
                  if not (Hashtbl.mem seen id) then begin
                    Hashtbl.replace seen id ();
                    res := (id, okv) :: !res;
                    last := Some okv;
                    incr added
                  end
              | _ -> ())
            rows;
          if !added > 0 && !last <> None then begin
            t := Option.get !last;
            dt := 3600
          end
          else begin
            t := !t - !dt;
            dt := !dt * 4
          end
        done
      with Exit -> ());
  let all = List.rev !res in
  { posts = List.filteri (fun i _ -> i >= offset) all; orderby_key = !orderby_key }
