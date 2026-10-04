(* Pure-logic tests for primal_common (no database beyond the compile-time schema check).
   Moved from ocaml-importer/test/test_importer.ml in Phase 0. *)

open Primal_common
module N = Nostr

let h = Hex_util.decode_exn

let test_hex () =
  let raw = h "deadbeef" in
  Alcotest.(check string) "roundtrip" "deadbeef" (Hex_util.encode raw)

(* Test vector lifted from Julia src/secp256k1.jl. *)
let test_schnorr_verify () =
  let msg = h "01a36e30a4117ba974f786c9135c198116d4bb100c516bc59fac48948ecb5abf" in
  let pk = h "932fedb11d131b720362372e8248ecd79cb72e16aecba31b0650e4c2ff21ed00" in
  let sg =
    h
      "20c8a626e8b2f70a86938af2fca509a69910111dc735525e15e0ec36e020a12529e7d3116e60126c135f8345353acc9c82a00bfea394007a625d5ecccc0741cc"
  in
  Alcotest.(check bool)
    "valid sig verifies" true
    (Secp256k1.verify ~msg_hash:msg ~serialized_pubkey:pk ~signature:sg);
  let bad = Bytes.of_string sg in
  Bytes.set bad 0 (Char.chr (Char.code (Bytes.get bad 0) lxor 1));
  Alcotest.(check bool)
    "tampered sig fails" false
    (Secp256k1.verify ~msg_hash:msg ~serialized_pubkey:pk ~signature:(Bytes.to_string bad))

let read_events path =
  let ic = open_in path in
  let rec loop acc =
    match input_line ic with
    | line ->
        let line = String.trim line in
        if line = "" then loop acc else loop (N.of_json (Yojson.Safe.from_string line) :: acc)
    | exception End_of_file ->
        close_in ic;
        List.rev acc
  in
  loop []

(* For real events from the DB, our NIP-01 canonicalization must reproduce the exact id a real
   client computed, and the Schnorr signature must verify. *)
let test_real_events () =
  let events = read_events "events.jsonl" in
  Alcotest.(check bool) "have fixtures" true (events <> []);
  List.iteri
    (fun i e ->
      Alcotest.(check string)
        (Printf.sprintf "event %d id canonicalization" i)
        (Hex_util.encode e.N.id)
        (Hex_util.encode (N.id_of e));
      Alcotest.(check bool) (Printf.sprintf "event %d verifies" i) true (N.verify e))
    events

(* Canonical LNURL (lud06) test vector from the LUD-06 spec. *)
let test_bech32_lnurl () =
  let lnurl =
    "LNURL1DP68GURN8GHJ7UM9WFMXJCM99E3K7MF0V9CXJ0M385EKVCENXC6R2C35XVUKXEFCV5MKVV34X5EKZD3EV56NYD3HXQURZEPEXEJXXEPNXSCRVWFNV9NXZCN9XQ6XYEFHVGCXXCMYXYMNSERXFQ5FNS"
  in
  let expected =
    "https://service.com/api?q=3fc3645b439ce8e7f2553a69e5267081d96dcd340693afabe04be7b0ccd178df"
  in
  Alcotest.(check (option string)) "lud06 decode" (Some expected) (Bech32.lnurl_decode lnurl);
  Alcotest.(check (option string))
    "lud06 decode (lowercase)" (Some expected)
    (Bech32.lnurl_decode (String.lowercase_ascii lnurl))

(* Canonical NIP-19 npub vector. *)
let test_nip19_npub () =
  let npub = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6" in
  let expected = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d" in
  match Bech32.nip19_decode npub with
  | Some (Bech32.Npub pk) -> Alcotest.(check string) "npub pubkey" expected (Hex_util.encode pk)
  | _ -> Alcotest.fail "npub did not decode to Npub"

(* Phase slots: registration, stuck detection, domain-implicit phase. *)
let test_phases () =
  let s = Phases.new_slot "test-slot" in
  Phases.set_slot s "working";
  let p, _ = Phases.slot_state s in
  Alcotest.(check string) "phase recorded" "working" p;
  Alcotest.(check bool) "not stuck yet" true
    (List.for_all (fun (n, _, _) -> n <> "test-slot") (Phases.stuck_slots ~min_age:60.0));
  Alcotest.(check bool) "stuck at min_age 0" true
    (List.exists (fun (n, p, _) -> n = "test-slot" && p = "working")
       (Phases.stuck_slots ~min_age:0.0));
  Phases.set_domain_slot s;
  Phases.phase "idle";
  let p, _ = Phases.slot_state s in
  Alcotest.(check string) "implicit domain slot" "idle" p

(* Nostr.to_json must round-trip through of_json and preserve the id. *)
let test_event_json_roundtrip () =
  let events = read_events "events.jsonl" in
  List.iteri
    (fun i e ->
      let e2 = N.of_json (N.to_json e) in
      Alcotest.(check bool) (Printf.sprintf "event %d roundtrip" i) true (e = e2);
      Alcotest.(check string) (Printf.sprintf "event %d id" i) (N.id_hex e) (Hex_util.encode (N.id_of e2)))
    events

let relay_url_t = Alcotest.(option (pair (pair bool string) (pair int string)))
let pr u = Option.map (fun (a, b, c, d) -> ((a, b), (c, d))) (Relay_broadcast.parse_relay_url u)

let test_relay_url () =
  Alcotest.check relay_url_t "wss default" (Some ((true, "relay.primal.net"), (443, "/"))) (pr "wss://relay.primal.net");
  Alcotest.check relay_url_t "ws with port and path" (Some ((false, "<internal-relay-host>"), (7777, "/x"))) (pr "ws://<internal-relay-host>:7777/x");
  Alcotest.check relay_url_t "trailing slash" (Some ((true, "nos.lol"), (443, "/"))) (pr "wss://nos.lol/");
  Alcotest.check relay_url_t "http rejected" None (pr "https://x.y")

let test_procinfo () =
  Alcotest.(check string) "hms" "01:01:05" (Procinfo.fmt_hms 3665);
  Alcotest.(check string) "bytes K" "1K" (Procinfo.fmt_bytes 1024);
  Alcotest.(check string) "bytes M" "2M" (Procinfo.fmt_bytes (2 * 1048576));
  Alcotest.(check bool) "rss > 0" true (Procinfo.read_rss_bytes () > 0)

let test_schnorr_sign () =
  let seckey = String.init 32 (fun i -> Char.chr ((i * 37 + 11) land 0xff)) in
  let e = Nostr.create ~seckey ~created_at:1_700_000_000 ~kind:1 ~tags:[ [ `String "t"; `String "x" ] ] ~content:"hello" in
  Alcotest.(check int) "pubkey length" 32 (String.length e.Nostr.pubkey);
  Alcotest.(check bool) "verifies" true (Nostr.verify e);
  Alcotest.(check bool) "tampered content fails" false (Nostr.verify { e with Nostr.content = "hello!" });
  let e2 = Nostr.create ~seckey ~created_at:1_700_000_000 ~kind:1 ~tags:[ [ `String "t"; `String "x" ] ] ~content:"hello" in
  Alcotest.(check string) "deterministic id" (Nostr.id_hex e) (Nostr.id_hex e2)

let () =
  Alcotest.run "primal_common"
    [
      ("hex_util", [ Alcotest.test_case "roundtrip" `Quick test_hex ]);
      ("secp256k1", [ Alcotest.test_case "schnorr verify" `Quick test_schnorr_verify; Alcotest.test_case "schnorr sign" `Quick test_schnorr_sign ]);
      ( "bech32",
        [
          Alcotest.test_case "lnurl lud06" `Quick test_bech32_lnurl;
          Alcotest.test_case "nip19 npub" `Quick test_nip19_npub;
        ] );
      ( "nostr",
        [
          Alcotest.test_case "real events" `Quick test_real_events;
          Alcotest.test_case "json roundtrip" `Quick test_event_json_roundtrip;
        ] );
      ("relay_broadcast", [ Alcotest.test_case "parse url" `Quick test_relay_url ]);
      ("phases", [ Alcotest.test_case "slots" `Quick test_phases ]);
      ("procinfo", [ Alcotest.test_case "formatting" `Quick test_procinfo ]);
    ]
