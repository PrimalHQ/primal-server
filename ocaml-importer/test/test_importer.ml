module N = Importer.Nostr
let h = Importer.Hex_util.decode_exn

let test_hex () =
  let raw = h "deadbeef" in
  Alcotest.(check string) "roundtrip" "deadbeef" (Importer.Hex_util.encode raw)

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
    (Importer.Secp256k1.verify ~msg_hash:msg ~serialized_pubkey:pk ~signature:sg);
  let bad = Bytes.of_string sg in
  Bytes.set bad 0 (Char.chr (Char.code (Bytes.get bad 0) lxor 1));
  Alcotest.(check bool)
    "tampered sig fails" false
    (Importer.Secp256k1.verify ~msg_hash:msg ~serialized_pubkey:pk
       ~signature:(Bytes.to_string bad))

let read_events path =
  let ic = open_in path in
  let rec loop acc =
    match input_line ic with
    | line ->
        let line = String.trim line in
        if line = "" then loop acc
        else loop (N.of_json (Yojson.Safe.from_string line) :: acc)
    | exception End_of_file ->
        close_in ic;
        List.rev acc
  in
  loop []

(* For real events from the DB, our NIP-01 canonicalization must reproduce the exact id a
   real client computed, and the Schnorr signature must verify. *)
let test_real_events () =
  let events = read_events "events.jsonl" in
  Alcotest.(check bool) "have fixtures" true (events <> []);
  List.iteri
    (fun i e ->
      Alcotest.(check string)
        (Printf.sprintf "event %d id canonicalization" i)
        (Importer.Hex_util.encode e.N.id)
        (Importer.Hex_util.encode (N.id_of e));
      Alcotest.(check bool) (Printf.sprintf "event %d verifies" i) true (N.verify e))
    events

(* Canonical LNURL (lud06) test vector from the LUD-06 spec. *)
let test_bech32_lnurl () =
  let lnurl =
    "LNURL1DP68GURN8GHJ7UM9WFMXJCM99E3K7MF0V9CXJ0M385EKVCENXC6R2C35XVUKXEFCV5MKVV34X5EKZD3EV56NYD3HXQURZEPEXEJXXEPNXSCRVWFNV9NXZCN9XQ6XYEFHVGCXXCMYXYMNSERXFQ5FNS"
  in
  let expected = "https://service.com/api?q=3fc3645b439ce8e7f2553a69e5267081d96dcd340693afabe04be7b0ccd178df" in
  Alcotest.(check (option string)) "lud06 decode" (Some expected) (Importer.Bech32.lnurl_decode lnurl);
  Alcotest.(check (option string)) "lud06 decode (lowercase)" (Some expected)
    (Importer.Bech32.lnurl_decode (String.lowercase_ascii lnurl))

(* Canonical NIP-19 npub vector. *)
let test_nip19_npub () =
  let npub = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6" in
  let expected = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d" in
  match Importer.Bech32.nip19_decode npub with
  | Some (Importer.Bech32.Npub pk) ->
      Alcotest.(check string) "npub pubkey" expected (Importer.Hex_util.encode pk)
  | _ -> Alcotest.fail "npub did not decode to Npub"

let () =
  Alcotest.run "importer"
    [ ("hex_util", [ Alcotest.test_case "roundtrip" `Quick test_hex ]);
      ("secp256k1", [ Alcotest.test_case "schnorr verify" `Quick test_schnorr_verify ]);
      ("bech32",
       [ Alcotest.test_case "lnurl lud06" `Quick test_bech32_lnurl;
         Alcotest.test_case "nip19 npub" `Quick test_nip19_npub ]);
      ("nostr", [ Alcotest.test_case "real events" `Quick test_real_events ])
    ]
