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

let () =
  Alcotest.run "primal_api"
    [
      ( "protocol",
        [
          Alcotest.test_case "parse" `Quick test_parse;
          Alcotest.test_case "frames" `Quick test_frames;
          Alcotest.test_case "events zlib" `Quick test_events_zlib;
          Alcotest.test_case "wants_zlib" `Quick test_wants_zlib;
        ] );
      ( "handlers",
        [
          Alcotest.test_case "kw" `Quick test_kw;
          Alcotest.test_case "fixup live p tags" `Quick test_fixup;
          Alcotest.test_case "funcall names" `Quick test_funcall_names;
        ] );
    ]
