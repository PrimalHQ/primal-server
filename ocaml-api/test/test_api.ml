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
    ]
