(* Protocol framing and zlib tests for primal-api (no network, no DB). *)

module P = Primal_api.Protocol

let test_parse () =
  (match P.parse {|["REQ","s1",{"cache":["user_infos",{"pubkeys":["ab"]}]}]|} with
  | P.Req { subid; funcall = Some "user_infos"; kwargs = `Assoc _; _ } ->
      Alcotest.(check string) "subid" "s1" subid
  | _ -> Alcotest.fail "cache REQ not parsed");
  (match P.parse {|["REQ","s2",{"ids":["ab"]}]|} with
  | P.Req { funcall = None; _ } -> ()
  | _ -> Alcotest.fail "non-cache REQ should have funcall = None");
  (match P.parse {|["CLOSE","s3"]|} with P.Close "s3" -> () | _ -> Alcotest.fail "CLOSE");
  (match P.parse "garbage" with P.Other "garbage" -> () | _ -> Alcotest.fail "Other");
  match P.parse {|["EVENT",{}]|} with P.Other _ -> () | _ -> Alcotest.fail "Other 2"

let test_frames () =
  Alcotest.(check string) "eose" {|["EOSE","s"]|} (P.eose "s");
  Alcotest.(check string) "event" {|["EVENT","s",{"content":"x"}]|} (P.event "s" {|{"content":"x"}|});
  Alcotest.(check string) "notice" {|["NOTICE","s","unknown api request"]|} (P.notice "s" "unknown api request");
  Alcotest.(check string) "escaped subid" {|["EOSE","a\"b"]|} (P.eose "a\"b")

(* The zlib EVENTS frame must inflate to exactly ws-connector's / Julia's uncompressed body. *)
let test_events_zlib () =
  let body = P.events_zlib "x" [ {|{"content":"wscm"}|}; {|{"kind":1}|} ] in
  Alcotest.(check string) "inflates"
    {|["EVENTS","x",[{"content":"wscm"},{"kind":1}]]|} (Zlib_util.uncompress body);
  (* RFC 1950 header: CMF 0x78, FLG with FCHECK (0x9c for level 6 default window) *)
  Alcotest.(check int) "zlib CMF" 0x78 (Char.code body.[0]);
  Alcotest.(check int) "zlib FLG" 0x9c (Char.code body.[1]);
  let big = String.concat "," (List.init 2000 (fun i -> Printf.sprintf {|{"kind":%d,"content":"hello world %d"}|} i i)) in
  Alcotest.(check string) "roundtrip big" big (Zlib_util.uncompress (Zlib_util.compress big))

module Kw = Primal_api.Kw
module H = Primal_api.Handlers

let kw s = Yojson.Safe.from_string s

let test_kw () =
  let k = kw {|{"limit":5,"until":1.0e9,"pubkey":"ab","user_pubkey":"zz","kinds":[1,"x",6],"b":true}|} in
  Alcotest.(check int) "int" 5 (Kw.int k "limit" ~default:20);
  Alcotest.(check int) "int default" 20 (Kw.int k "nope" ~default:20);
  Alcotest.(check (option int)) "float integer" (Some 1_000_000_000) (Kw.int_opt k "until");
  Alcotest.(check (option string)) "hex_any" (Some "\xab") (Kw.hex_any_opt k "pubkey");
  Alcotest.(check (option string)) "hex_any invalid" None (Kw.hex_any_opt k "user_pubkey");
  Alcotest.(check (option (list int))) "int list skips non-ints" (Some [ 1; 6 ]) (Kw.int_list_opt k "kinds");
  Alcotest.(check bool) "bool" true (Kw.bool k "b" ~default:false);
  Alcotest.(check string) "set/remove/merge"
    {|{"c":3,"limit":5,"b":true}|}
    (Yojson.Safe.to_string
       (Kw.merge (Kw.remove (Kw.remove (Kw.remove (Kw.remove (Kw.set k "c" (`Int 3)) "until") "pubkey") "user_pubkey") "kinds") []))

let test_fixup () =
  let e = {|{"kind":30311,"tags":[["p","aa","wss://r","Host","proof"],["d","x"]],"content":""}|} in
  Alcotest.(check string) "role lowercased, keys sorted"
    {|{"content":"","kind":30311,"tags":[["p","aa","wss://r","host","proof"],["d","x"]]}|}
    (H.fixup_live_event_p_tags e);
  let other = {|{"kind":1,"tags":[["p","aa","","HOST"]]}|} in
  Alcotest.(check string) "other kinds untouched" other (H.fixup_live_event_p_tags other)

let test_funcall_names () =
  let open Primal_api.Funcall in
  List.iter
    (fun n -> Alcotest.(check string) n n (to_string (of_string n)))
    [ "thread_view"; "feed"; "live_feed"; "events"; "server_name"; "something_else" ];
  match of_string "something_else" with Proxied _ -> () | _ -> Alcotest.fail "unknown names must be Proxied"

let test_wants_zlib () =
  Alcotest.(check bool) "zlib" true (P.wants_zlib (`Assoc [ ("compression", `String "zlib") ]));
  Alcotest.(check bool) "none" false (P.wants_zlib (`Assoc []));
  Alcotest.(check bool) "null" false (P.wants_zlib `Null)

(* {1 Phase 3b} *)

module M = Primal_api.Moderation

let test_funcall_catalogue () =
  let open Primal_api.Funcall in
  let names = native_names () in
  List.iter (fun n -> Alcotest.(check string) n n (to_string (of_string n))) names;
  Alcotest.(check bool) "no duplicates" true (List.length (List.sort_uniq compare names) = List.length names);
  match of_string "upload_chunk" with Proxied _ -> () | _ -> Alcotest.fail "upload_chunk is still proxied"

let test_nip19 () =
  let j = Yojson.Safe.to_string in
  (match H.nip19_ser "npub12vkcxr0luzwp8e673v29eqjhrr7p9vqq8asav85swaepclllj09sylpugg" with
  | Some v -> Alcotest.(check string) "npub" {|[["PubKeyId","532d830dffe09c13e75e8b145c825718fc12b0003f61d61e9077721c7fff93cb"]]|} (j v)
  | None -> Alcotest.fail "npub");
  (match H.nip19_ser "note1zp7mjj5548xuxp3cusfxxm6t5708s2ggvvr8y4yzudr4sw5nh65qd2fagf" with
  | Some v -> Alcotest.(check string) "note" {|[["EventId","107db94a94a9cdc30638e412636f4ba79e7829086306725482e347583a93bea8"]]|} (j v)
  | None -> Alcotest.fail "note");
  Alcotest.(check (option string)) "unknown prefix -> [null]" (Some "[null]") (Option.map j (H.nip19_ser "lnurl1xyz"));
  Alcotest.(check bool) "garbage npub -> Julia error" true (H.nip19_ser "npub1xyz" = None)

let test_relays_normalize () =
  let m = {|{"kind":10000139,"pubkey":"ab","tags":[["r","wss://b"],["r","wss://a","read"],["r","wss://b"]]}|} in
  Alcotest.(check string) "sorted, deduplicated, Julia key order"
    {|{"kind":10000139,"pubkey":"ab","tags":[["r","wss://a","read"],["r","wss://b"]]}|} (H.normalize_relays_msg m)

let test_range_msg () =
  Alcotest.(check string) "empty" {|{"kind":10000113,"content":"{\"order_by\":\"amount_sats\",\"elements\":[]}"}|}
    (H.range_msg ~order_by:"amount_sats" []);
  Alcotest.(check string) "since/until from first and last, elements by amount desc"
    {|{"kind":10000113,"content":"{\"since\":5,\"until\":100,\"order_by\":\"amount_sats\",\"elements\":[\"a\",\"c\",\"b\"]}"}|}
    (H.range_msg ~order_by:"amount_sats" [ ("a", 100L); ("c", 50L); ("b", 5L) ])

let test_moderation_scope () =
  Alcotest.(check bool) "feed is content scope" true (M.scope_of_funcall "feed" = M.Content);
  Alcotest.(check bool) "scored is trending scope" true (M.scope_of_funcall "scored" = M.Trending);
  Alcotest.(check bool) "user_profile has no scope" true (M.scope_of_funcall "user_profile" = M.No_scope);
  Alcotest.(check bool) "author_exempt" true (M.author_exempt (kw {|{"notes":"authored","pubkey":"ab"}|}) = None);
  Alcotest.(check bool) "author_exempt needs a 32-byte pubkey" true
    (M.author_exempt (kw {|{"notes":"authored","pubkey":"532d830dffe09c13e75e8b145c825718fc12b0003f61d61e9077721c7fff93cb"}|}) <> None);
  Alcotest.(check bool) "no exemption for follows" true
    (M.author_exempt (kw {|{"notes":"follows","pubkey":"532d830dffe09c13e75e8b145c825718fc12b0003f61d61e9077721c7fff93cb"}|}) = None)

let test_event_from_user () =
  let signed =
    kw
      {|{"event_from_user":{"id":"3153082ad107b3589145b6cf3ec215a5c492ff2ab6f1534fbeb63ebfd8e42c47","pubkey":"fce7597c60d22555fd4fddb21ab4efe6cfba5dab48f9b6b95f7a02e95c8b8c76","created_at":1791101895,"kind":30078,"tags":[],"content":"{\"subkey\":\"user-home-feeds\"}","sig":"d70629d32020f8f10411f5aa7af7a987884046223cadb21aca872651d64abad24ced46f85a511a3b14d480bddb9700fbcaa465d141f32bc8da30bd5afdd69759"}}|}
  in
  (match H.event_from_user signed with
  | Ok e -> Alcotest.(check int) "kind" 30078 e.Nostr.kind
  | Error s -> Alcotest.fail s);
  let bad = kw {|{"event_from_user":{"id":"00","pubkey":"fce7597c60d22555fd4fddb21ab4efe6cfba5dab48f9b6b95f7a02e95c8b8c76","created_at":1,"kind":1,"tags":[],"content":"","sig":"00"}}|} in
  match H.event_from_user bad with Error _ -> () | Ok _ -> Alcotest.fail "unsigned event accepted"

(* {1 Phase 4a} *)

(* DB.notif2namedtuple parity: a YOUR_POST_WAS_ZAPPED row rendered by Julia on 2026-10-04 *)
let test_notif_json () =
  let row =
    { Primal_api.Queries.n_created_at = 1791104973L; n_type = 3L;
      arg1 = Some (Hex_util.decode_exn "4b9c7c6ec7987bff73e1043d437e205bc52b74248752324505326ea1e0ee517e");
      arg2 = Some (Hex_util.decode_exn "bfccad6fb7ce0810043b7027ca1bfc82d5c01f62389f7aaa005978a07478a76f");
      arg3 = Some "69"; arg4 = Some "\"\"" }
  in
  match H.notif_of_row ~pubkey_hex:"8fb140b4e8ddef97ce4b821d247278a1a4353362623f64021484b372f948000c" row with
  | None -> Alcotest.fail "no notif"
  | Some n ->
      Alcotest.(check string) "julia json"
        {|{"id":"c8998d037e4c31e84f51519958392f0ea88585da0141d4e2c523b2b62ca4f844","created_at":1791104973,"message":"","pubkey":"8fb140b4e8ddef97ce4b821d247278a1a4353362623f64021484b372f948000c","satszapped":69,"type":3,"who_zapped_it":"bfccad6fb7ce0810043b7027ca1bfc82d5c01f62389f7aaa005978a07478a76f","your_post":"4b9c7c6ec7987bff73e1043d437e205bc52b74248752324505326ea1e0ee517e"}|}
        (Yojson.Safe.to_string (`Assoc n.fields));
      Alcotest.(check (list string)) "pks" [ "bfccad6fb7ce0810043b7027ca1bfc82d5c01f62389f7aaa005978a07478a76f" ] n.pks;
      Alcotest.(check (list string)) "eids" [ "4b9c7c6ec7987bff73e1043d437e205bc52b74248752324505326ea1e0ee517e" ] n.eids

let test_broadcast_msgs () =
  let module B = Primal_api.Broadcasts in
  let counts = List.map Int64.of_int [ 13093; 0; 2289; 12798; 1082; 6338; 278; 582; 0; 0; 0; 0; 0; 0; 0; 0; 2; 168; 159; 836; 2417 ] in
  Alcotest.(check string) "notification_counts (Julia key order)"
    {|{"kind":10000112,"pubkey":"8f","1":13093,"2":0,"3":2289,"4":12798,"5":1082,"6":6338,"7":278,"8":582,"101":0,"102":0,"103":0,"104":0,"201":0,"202":0,"203":0,"204":0,"301":2,"302":168,"401":159,"501":836,"601":2417}|}
    (B.notification_counts_msg ~pubkey_hex:"8f" counts);
  Alcotest.(check string) "directmsg_count" {|{"kind":10000117,"cnt":624}|} (B.directmsg_count_msg 624L);
  Alcotest.(check string) "directmsg_count_2" {|{"kind":10000134,"content":"624"}|} (B.directmsg_count_2_msg 624L)

let test_filter_funcall () =
  let module C = Primal_api.Conn in
  (match C.filter_funcall {|["REQ","s",{"ids":["107db94a94a9cdc30638e412636f4ba79e7829086306725482e347583a93bea8","zz"]}]|} with
  | `Call (Primal_api.Funcall.Events, kw) -> Alcotest.(check int) "one valid id" 1 (List.length (Option.get (Kw.str_list_opt kw "event_ids")))
  | _ -> Alcotest.fail "ids");
  (match C.filter_funcall {|["REQ","s",{"search":"jack","kinds":[0],"limit":5}]|} with
  | `Reject "kinds or authors filter is not supported" -> ()
  | _ -> Alcotest.fail "kinds are rejected like Julia does");
  (match C.filter_funcall {|["REQ","s",{"cache":["feed",{}]},{"authors":["ab"]}]|} with `Reject _ -> () | _ -> Alcotest.fail "authors in any filter");
  (match C.filter_funcall {|["REQ","s",{"search":"x"}]|} with `None -> () | _ -> Alcotest.fail "search stays proxied");
  match C.filter_funcall {|["REQ","s",{"since":1,"until":2,"limit":3,"idsonly":true}]|} with
  | `Call (Primal_api.Funcall.Events, kw) -> Alcotest.(check bool) "idsonly" true (Kw.bool kw "idsonly" ~default:false)
  | _ -> Alcotest.fail "since/until"

(* {1 Phase 4b} *)

let test_f32 () =
  Alcotest.(check string) "integer" "0.0" (H.f32_string 0.0);
  Alcotest.(check string) "one third as Float32" "0.33333334" (H.f32_string (1.0 /. 3.0));
  Alcotest.(check string) "ratio" "1.5" (H.f32_string 1.5);
  Alcotest.(check string) "0.1 as Float32" "0.1" (H.f32_string 0.1)

let test_mega_ids () =
  let open Primal_api.Funcall in
  List.iter (fun n -> Alcotest.(check string) n n (to_string (of_string n))) [ "explore"; "explore_zaps"; "trending_hashtags_7d" ];
  Alcotest.(check bool) "julia_exposed has explore_people" true (List.mem "explore_people" H.julia_exposed);
  Alcotest.(check bool) "julia_exposed has no bogus" false (List.mem "video-reels" H.julia_exposed)

let test_advsearch () =
  let module A = Primal_api.Advsearch in
  let now = 1_700_000_000 in
  let has s sub = try ignore (Str.search_forward (Str.regexp_string sub) s 0); true with Not_found -> false in
  Alcotest.(check int) "words" 2 (List.length (A.ops (A.parse ~now "hello world")));
  (match A.parse ~now "kind:30023 scope:myfollowsinteractions minwords:100 features:summary" with
  | A.And [ A.Kind 30023; A.Scope "myfollowsinteractions"; A.MinWords 100; A.Features [ "summary" ] ] -> ()
  | _ -> Alcotest.fail "reads query");
  (match A.parse ~now "kind:20 OR kind:34236" with A.Or [ A.Kind 20; A.Kind 34236 ] -> () | _ -> Alcotest.fail "or");
  (match A.parse ~now "\"exact phrase\" -spam #nostr since:yesterday" with
  | A.And [ A.Phrase "exact phrase"; A.NotWord "spam"; A.HashTag "nostr"; A.Since t ] when t = now - 86400 -> ()
  | _ -> Alcotest.fail "mixed");
  (match A.parse ~now "from:532d830dffe09c13e75e8b145c825718fc12b0003f61d61e9077721c7fff93cb orderby:score" with
  | A.And [ A.From (A.From_pk pk); A.OrderBy "score" ] when Hex_util.encode pk = "532d830dffe09c13e75e8b145c825718fc12b0003f61d61e9077721c7fff93cb" -> ()
  | _ -> Alcotest.fail "from hex");
  (match A.parse ~now "(bitcoin OR lightning) -\"shit coin\" :) ?" with
  | A.And [ A.Or [ A.Word "bitcoin"; A.Word "lightning" ]; A.NotPhrase "shit coin"; A.Emoticon ":)"; A.Question ] -> ()
  | _ -> Alcotest.fail "parens");
  Alcotest.(check bool) "parse error" true (match A.parse ~now "scope:" with exception A.Parse_error _ -> true | _ -> false);
  let sql = A.to_sql ~user_pubkey:(String.make 32 '\000') (A.parse ~now "bitcoin minlikes:3") ~since:0 ~until:now ~kinds:[] in
  Alcotest.(check bool) "event_stats joined" true (has sql.A.text "event_stats.likes >= ");
  Alcotest.(check bool) "default kinds" true (has sql.A.text "advsearch.kind IN (");
  Alcotest.(check string) "orderkey" "created_at" sql.A.orderby_key;
  Alcotest.(check int) "params" 9 (List.length sql.A.params);
  Alcotest.(check string) "urls quoted" "x \"https://a.b/c?d=1\" y" (A.quote_urls "x https://a.b/c?d=1 y");
  Alcotest.(check string) "nostr prefix" "from:npub1abc note1xyz" (A.strip_nostr_prefix "from:nostr:npub1abc nostr:note1xyz")

let test_internal_http () =
  let module I = Primal_api.Internal_http in
  Alcotest.(check string) "julia pretty" "{\n  \"names\": {\n    \"emma\": \"1c\"\n  }\n}" (Primal_api.Jsonfmt.julia_pretty (`Assoc [ ("names", `Assoc [ ("emma", `String "1c") ]) ]));
  Alcotest.(check string) "julia pretty empty" "{\n  \"names\": {}\n}" (Primal_api.Jsonfmt.julia_pretty (`Assoc [ ("names", `Assoc []) ]));
  Alcotest.(check string) "julia pretty list" "{\n  \"a\": [\n    \"x\",\n    \"y\"\n  ],\n  \"b\": []\n}" (Primal_api.Jsonfmt.julia_pretty (`Assoc [ ("a", `List [ `String "x"; `String "y" ]); ("b", `List []) ]));
  Alcotest.(check string) "escape uri" "https%3A%2F%2Fa.b%2Fc%3Fd%3D1%20e" (I.escape_uri "https://a.b/c?d=1 e");
  Alcotest.(check string) "strip urls" "see  now" (I.strip_urls "see https://example.com/x?y=1 now");
  Alcotest.(check string) "ext of url" ".jpg" (I.ext_of_url "https://m.primal.net/claude-test.JPG?x=1");
  Alcotest.(check bool) "short path is letters" true (String.for_all (fun c -> (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) (I.short_path_of_idx 12345));
  let page = "<html><head><meta property=\"og:title\" content=\"Primal\">\n<title>Primal</title></head><body></body></html>" in
  let m = { I.m_title = "Emma"; m_description = "a \"b\"\nc"; m_image = I.Cached "https://x/y.jpg"; m_url = "https://primal.net/emma"; twitter_card = "summary"; twitter_image = "https://x/y.jpg" } in
  let out = I.og_page page m in
  Alcotest.(check bool) "old og removed" false (Primal_api.Handlers.has_sub out "content=\"Primal\"");
  Alcotest.(check bool) "title replaced" true (Primal_api.Handlers.has_sub out "<title>Emma</title>");
  Alcotest.(check bool) "description escaped" true (Primal_api.Handlers.has_sub out "content=\"a &quot;b&quot;&#10;c\"");
  Alcotest.(check bool) "image cached" true (Primal_api.Handlers.has_sub out "og:image\" content=\"https://primal.net/media-cache?u=https%3A%2F%2Fx%2Fy.jpg\"");
  Alcotest.(check bool) "twitter image raw" true (Primal_api.Handlers.has_sub out "twitter:image\" content=\"https://x/y.jpg\"/></head>");
  let html = "<html><head><link rel=\"icon\" href=\"/fav.ico\"><meta property=\"og:title\" content=\"T &amp; U\"><meta name=\"description\" content='D'><meta property=\"og:image\" content=\"img/p.png\"></head><body><meta property=\"og:title\" content=\"ignored\"></body></html>" in
  let p = I.parse_preview ~url:"https://ex.com/a/b.html" html in
  Alcotest.(check string) "title" "T & U" p.I.p_title;
  Alcotest.(check string) "description" "D" p.I.p_description;
  Alcotest.(check string) "image joined" "https://ex.com/a/img/p.png" p.I.p_image;
  Alcotest.(check string) "urljoin abs" "https://ex.com/x" (Http.urljoin "https://ex.com/a/b" "/x")

let test_p_tags () =
  let e = {|{"id":"ab","tags":[["p","532d830dffe09c13e75e8b145c825718fc12b0003f61d61e9077721c7fff93cb"],["p","2895c330c23f383196c0ef988de6da83b83b4583ed5f9c1edb0a559cecd1f900","wss://r"],["e","zz"]]}|} in
  Alcotest.(check int) "all p tags" 2 (List.length (H.p_tag_pubkeys e));
  Alcotest.(check int) "exactly two fields" 1 (List.length (H.p_tag_pubkeys ~exactly_two:true e))

let () =
  Alcotest.run "primal_api"
    [
      ( "protocol",
        [
          Alcotest.test_case "parse" `Quick test_parse;
          Alcotest.test_case "frames" `Quick test_frames;
          Alcotest.test_case "events zlib" `Quick test_events_zlib;
          Alcotest.test_case "funcall catalogue" `Quick test_funcall_catalogue;
          Alcotest.test_case "nip19 ser" `Quick test_nip19;
          Alcotest.test_case "relays normalize" `Quick test_relays_normalize;
          Alcotest.test_case "range msg" `Quick test_range_msg;
          Alcotest.test_case "moderation scope" `Quick test_moderation_scope;
          Alcotest.test_case "event_from_user" `Quick test_event_from_user;
          Alcotest.test_case "notif json" `Quick test_notif_json;
          Alcotest.test_case "broadcast msgs" `Quick test_broadcast_msgs;
          Alcotest.test_case "filter funcall" `Quick test_filter_funcall;
          Alcotest.test_case "f32 string" `Quick test_f32;
          Alcotest.test_case "mega ids" `Quick test_mega_ids;
          Alcotest.test_case "p tags" `Quick test_p_tags;
          Alcotest.test_case "advsearch" `Quick test_advsearch;
          Alcotest.test_case "internal http" `Quick test_internal_http;
          Alcotest.test_case "wants_zlib" `Quick test_wants_zlib;
        ] );
      ( "handlers",
        [
          Alcotest.test_case "kw" `Quick test_kw;
          Alcotest.test_case "fixup live p tags" `Quick test_fixup;
          Alcotest.test_case "funcall names" `Quick test_funcall_names;
        ] );
    ]
