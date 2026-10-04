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
  match of_string "get_notifications" with Proxied _ -> () | _ -> Alcotest.fail "get_notifications is still proxied"

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
          Alcotest.test_case "wants_zlib" `Quick test_wants_zlib;
        ] );
      ( "handlers",
        [
          Alcotest.test_case "kw" `Quick test_kw;
          Alcotest.test_case "fixup live p tags" `Quick test_fixup;
          Alcotest.test_case "funcall names" `Quick test_funcall_names;
        ] );
    ]
