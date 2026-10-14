open Primal_fetcher

let sanitize () =
  let eq name a b = Alcotest.(check (option string)) name b a in
  eq "lowercase host, default port, trailing slash" (Relay_url.sanitize_valid "wss://Relay.Damus.io:443/") (Some "wss://relay.damus.io");
  eq "kept port" (Relay_url.sanitize_valid "ws://nostr.rocks:7448") (Some "ws://nostr.rocks:7448");
  eq "normpath" (Relay_url.sanitize_valid "wss://a.example/x/../y/") (Some "wss://a.example/y");
  eq "onion dropped" (Relay_url.sanitize_valid "ws://abc.onion") None;
  eq "ipv6 dropped" (Relay_url.sanitize_valid "wss://[::1]:4848/") None;
  eq "localhost dropped" (Relay_url.sanitize_valid "ws://localhost:4848") None;
  eq "empty dropped" (Relay_url.sanitize_valid "") None;
  eq "first line only" (Relay_url.sanitize_valid "wss://relay.example/\ngarbage") (Some "wss://relay.example");
  eq "query dropped (URIs.isvalid)" (Relay_url.sanitize_valid "wss://relay.example/?x=1") None;
  eq "fragment dropped" (Relay_url.sanitize_valid "wss://host.example/#frag") None;
  eq "empty segments kept" (Relay_url.sanitize_valid "wss://host.example/a//b/") (Some "wss://host.example/a//b");
  eq "dot segment" (Relay_url.sanitize_valid "wss://host.example/./") (Some "wss://host.example");
  eq "tab in host kept" (Relay_url.sanitize_valid "wss://\tnostr.example") (Some "wss://\tnostr.example");
  eq "empty host kept" (Relay_url.sanitize_valid "wss:///no.str.cr") (Some "wss:///no.str.cr");
  eq "userinfo kept" (Relay_url.sanitize_valid "wss://user@host.example/") (Some "wss://user@host.example")

let julia_float () =
  Alcotest.(check string) "time()" "1.791140507318978e9" (Julia_json.julia_float 1791140507.318978);
  Alcotest.(check string) "integer-valued large" "1.791140507e9" (Julia_json.julia_float 1791140507.0);
  Alcotest.(check string) "small" "30.0" (Julia_json.julia_float 30.0)

let resume_dir () =
  Alcotest.(check string) "escaping" "/s/wss___relay_damus_io" (Resume.relay_dir ~state_dir:"/s" "wss://relay.damus.io");
  Alcotest.(check string) "escaping 2" "/s/ws___10_0_0_5_7777" (Resume.relay_dir ~state_dir:"/s" "ws://10.0.0.5:7777")

let private_hosts () =
  Alcotest.(check bool) "192.168" true (Relay_url.private_ipv4_host "10.0.0.2");
  Alcotest.(check bool) "10" true (Relay_url.private_ipv4_host "10.0.0.1");
  Alcotest.(check bool) "public" false (Relay_url.private_ipv4_host "100.71.52.1");
  Alcotest.(check bool) "name" false (Relay_url.private_ipv4_host "relay.damus.io")

let fast_extract () =
  let m = {|["EVENT","sub1",{"content":"x \"id\":\"deadbeef","created_at":1791141482,"id":"2f2c0d13d2d3c5c2e25af2b8f5e1ac65b5eb406a4fcd854114efdc35e1124aeb","kind":5,"pubkey":"c3","sig":"00","tags":[]}]|} in
  Alcotest.(check (option string)) "id" (Some "2f2c0d13d2d3c5c2e25af2b8f5e1ac65b5eb406a4fcd854114efdc35e1124aeb") (Relay_conn.extract_event_id m);
  Alcotest.(check (option int)) "created_at" (Some 1791141482) (Relay_conn.extract_created_at m);
  Alcotest.(check (option string)) "eose" None (Relay_conn.extract_event_id {|["EOSE","sub1"]|})

let () =
  Alcotest.run "primal_fetcher"
    [ ("relay_url", [ Alcotest.test_case "sanitize" `Quick sanitize; Alcotest.test_case "private" `Quick private_hosts ]); ("julia_json", [ Alcotest.test_case "float" `Quick julia_float ]); ("resume", [ Alcotest.test_case "dir" `Quick resume_dir ]); ("relay_conn", [ Alcotest.test_case "fast extract" `Quick fast_extract ]) ]
