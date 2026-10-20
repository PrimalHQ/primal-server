(* Pure-logic tests for primal_common (no database beyond the compile-time schema check). *)

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
  Alcotest.check relay_url_t "ws with port and path" (Some ((false, "10.0.0.5"), (7777, "/x"))) (pr "ws://10.0.0.5:7777/x");
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

let test_s3_presign () =
  let p = { S3.name = "aws"; endpoint = "https://s3.amazonaws.com"; region = "us-east-1"; bucket = "examplebucket"; bucket2 = None; access_key = "AKIAIOSFODNN7EXAMPLE"; secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"; domain = None } in
  (* 2013-05-24T00:00:00Z; the documented example uses virtual-hosted addressing, so the signature
     below is computed for the host/path we send and checked for shape and determinism *)
  let now = 1369353600.0 in
  let url = S3.presign_get ~expires:86400 ~now p ~bucket:"examplebucket" ~key:"test.txt" in
  Alcotest.(check bool) "path style" true (String.starts_with ~prefix:"https://s3.amazonaws.com/examplebucket/test.txt?" url);
  Alcotest.(check bool) "has signature" true (Str_util.find_substring url "&X-Amz-Signature=" <> None);
  Alcotest.(check string) "deterministic" url (S3.presign_get ~expires:86400 ~now p ~bucket:"examplebucket" ~key:"test.txt");
  (* the documented vector itself: virtual-hosted host and key path *)
  let date, amz_date = S3.amz_dates now in
  Alcotest.(check string) "amz date" "20130524T000000Z" amz_date;
  let scope = date ^ "/us-east-1/s3/aws4_request" in
  let query = [ ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"); ("X-Amz-Credential", p.S3.access_key ^ "/" ^ scope); ("X-Amz-Date", amz_date); ("X-Amz-Expires", "86400"); ("X-Amz-SignedHeaders", "host") ] in
  let canonical_request = String.concat "\n" [ "GET"; "/test.txt"; S3.canonical_query query; "host:examplebucket.s3.amazonaws.com\n"; "host"; "UNSIGNED-PAYLOAD" ] in
  let sts = S3.string_to_sign ~amz_date ~scope ~canonical_request in
  let signature = Digestif.SHA256.(to_hex (hmac_string ~key:(S3.signing_key ~secret:p.S3.secret_key ~date ~region:"us-east-1" ~service:"s3") sts)) in
  Alcotest.(check string) "aws documented signature" "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404" signature

let test_langid () =
  let det s = match Langid.detect s with Some (c, p) -> (c, p) | None -> ("", 0.0) in
  let c, p = det "This is a reasonably long English sentence about the weather and the sea, written for a test." in
  Alcotest.(check string) "english" "eng" c;
  Alcotest.(check bool) "english confident" true (p > 0.5);
  let c, _ = det "Это довольно длинное предложение на русском языке о погоде и море, написанное для теста." in
  Alcotest.(check string) "russian" "rus" c;
  let c, p = det "これは日本語の文章です。天気と海についての長めの文です。" in
  Alcotest.(check string) "japanese" "jpn" c;
  Alcotest.(check bool) "japanese confidence" true (p >= 0.5);
  Alcotest.(check bool) "empty" true (Langid.detect "" = None);
  Alcotest.(check bool) "digits only" true (Langid.detect "12345 67890 !!!" = None)

let nip44_padding () =
  List.iter (fun (n, p) -> Alcotest.(check int) (string_of_int n) p (Nip44.calc_padded_len n))
    [ (16, 32); (32, 32); (33, 64); (37, 64); (45, 64); (49, 64); (64, 64); (65, 96); (100, 128); (111, 128); (200, 224); (250, 256); (320, 320); (383, 384); (384, 384); (400, 448); (500, 512); (512, 512); (515, 640); (700, 768); (800, 896); (900, 1024); (1020, 1024); (65536, 65536) ]

(* nip44.vectors.json get_conversation_key[0] *)
let nip44_conversation_key () =
  let sec1 = Hex_util.decode_exn "315e59ff51cb9209768cf7da80791ddcaae56ac9775eb25b6dee1234bc5d2268" and pub2 = Hex_util.decode_exn "c2f9d9948dc8c7c38321e4b85c8558872eafa0641cd269db76848a6073e69133" in
  match Nip44.conversation_key ~seckey:sec1 ~pubkey:pub2 with
  | Some k -> Alcotest.(check string) "conversation key" "3dfef0ce2a4d80a25e7a328accf73448ef67096f65f79588e358d9a0eb9013f1" (Hex_util.encode k)
  | None -> Alcotest.fail "ecdh failed"

let nip44_roundtrip () =
  Mirage_crypto_rng_unix.use_default ();
  let sk1 = String.init 32 (fun i -> Char.chr (i + 1)) and sk2 = String.init 32 (fun i -> Char.chr (100 - i)) in
  let pk1 = Option.get (Secp256k1.pubkey_of_seckey sk1) and pk2 = Option.get (Secp256k1.pubkey_of_seckey sk2) in
  let k12 = Option.get (Nip44.conversation_key ~seckey:sk1 ~pubkey:pk2) and k21 = Option.get (Nip44.conversation_key ~seckey:sk2 ~pubkey:pk1) in
  Alcotest.(check string) "symmetric" (Hex_util.encode k12) (Hex_util.encode k21);
  List.iter (fun msg -> match Nip44.decrypt ~conversation_key:k21 (Nip44.encrypt ~conversation_key:k12 msg) with Ok m -> Alcotest.(check string) "roundtrip" msg m | Error e -> Alcotest.fail e) [ "a"; "hello, nostr"; String.make 1000 'x'; "{\"kind\":1,\"content\":\"\xc5\xa1\"}" ]

(* Regression: httpun-ws delivered only the first two of N frames that arrived in one socket read
   (the rest waited for the peer's next bytes); patched in flake.nix. Four frames in ONE write to
   an echo session must all come back. *)
let test_ws_burst () =
  let open Eio.Std in
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env and net = Eio.Stdenv.net env in
  Switch.run @@ fun sw ->
  let fd = Listen.bind ~host:"127.0.0.1" ~port:0 () in
  let port = Listen.port_of_fd fd in
  let echo (s : Http_server.ws_session) =
    let rec loop () =
      match s.ws_recv () with
      | `Text m -> s.ws_send_text m; loop ()
      | `Binary m -> s.ws_send_binary m; loop ()
      | `Closed -> ()
    in
    loop ()
  in
  let svc =
    Http_server.default_service "echo"
      [ { Http_server.meth = `GET; pattern = []; handler = (fun _ -> Http_server.Ws (None, echo)) } ]
  in
  let stop, resolve_stop = Promise.create () in
  Fiber.fork ~sw (fun () -> Http_server.serve_on ~sw ~clock ~stop svc (Listen.import ~sw fd));
  let flow = Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
  let masked payload =
    let n = String.length payload in
    let mask = "\x01\x02\x03\x04" in
    let hdr =
      if n < 126 then Printf.sprintf "\x81%c" (Char.chr (0x80 lor n))
      else Printf.sprintf "\x81\xfe%c%c" (Char.chr (n lsr 8)) (Char.chr (n land 0xff))
    in
    hdr ^ mask ^ String.init n (fun i -> Char.chr (Char.code payload.[i] lxor Char.code mask.[i mod 4]))
  in
  let msgs = List.init 4 (fun i -> Printf.sprintf "{\"n\":%d,\"pad\":\"%s\"}" i (String.make (200 * (i + 1)) 'x')) in
  Eio.Flow.copy_string
    "GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    flow;
  let r = Eio.Buf_read.of_flow ~max_size:(1 lsl 20) flow in
  let status = Eio.Buf_read.line r in
  Alcotest.(check bool) "101" true (String.length status > 12 && String.sub status 9 3 = "101");
  let rec skip () = if Eio.Buf_read.line r <> "" then skip () in
  skip ();
  (* the four frames in ONE write *)
  Eio.Flow.copy_string (String.concat "" (List.map masked msgs)) flow;
  let read_frame () =
    let h = Eio.Buf_read.take 2 r in
    let len = Char.code h.[1] land 0x7f in
    let len =
      if len = 126 then (
        let e = Eio.Buf_read.take 2 r in
        (Char.code e.[0] lsl 8) lor Char.code e.[1])
      else len
    in
    Eio.Buf_read.take len r
  in
  let got = ref [] in
  (match
     Eio.Time.with_timeout clock 3.0 (fun () ->
         for _ = 1 to 4 do got := read_frame () :: !got done;
         Ok ())
   with
  | Ok () -> ()
  | Error `Timeout -> ());
  Alcotest.(check (list string)) "all four frames of one write are answered" msgs (List.rev !got);
  Eio.Flow.shutdown flow `All;
  Promise.resolve resolve_stop ()

(* Regression: a client that stops reading. Its outbound queue fills while the writer waits for a
   flush; the writer then gives up, nothing takes from the queue any more, and a sender blocked
   on it waited forever (the API's broadcast loop stopped for every connection). Sends must
   return once the writer has given up, and ws_try_send_text must never wait. *)
let test_ws_stalled_client () =
  let open Eio.Std in
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env and net = Eio.Stdenv.net env in
  let checked = ref false in
  let run () =
    Switch.run @@ fun sw ->
    let fd = Listen.bind ~host:"127.0.0.1" ~port:0 () in
    let port = Listen.port_of_fd fd in
    let session, resolve_session = Promise.create () in
    let hold (s : Http_server.ws_session) =
      Promise.resolve resolve_session s;
      let rec loop () = match s.ws_recv () with `Closed -> () | _ -> loop () in
      loop ()
    in
    let svc =
      {
        (Http_server.default_service "stall"
           [ { Http_server.meth = `GET; pattern = []; handler = (fun _ -> Http_server.Ws (None, hold)) } ])
        with
        ws_limits = { Http_server.default_ws_limits with outbound_queue = 2; send_stall_s = 0.2 };
      }
    in
    let stop, resolve_stop = Promise.create () in
    Fiber.fork ~sw (fun () -> Http_server.serve_on ~sw ~clock ~stop svc (Listen.import ~sw fd));
    let flow = Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) in
    Eio.Flow.copy_string
      "GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: AAAAAAAAAAAAAAAAAAAAAA==\r\nSec-WebSocket-Version: 13\r\n\r\n"
      flow;
    let r = Eio.Buf_read.of_flow ~max_size:(1 lsl 20) flow in
    let status = Eio.Buf_read.line r in
    Alcotest.(check bool) "101" true (String.length status > 12 && String.sub status 9 3 = "101");
    let rec skip () = if Eio.Buf_read.line r <> "" then skip () in
    skip ();
    (* from here on the client reads nothing: 40 MB is more than the loopback buffers hold *)
    let s = Promise.await session in
    let frame = String.make (1 lsl 20) 'x' in
    let sent = Eio.Time.with_timeout clock 3.0 (fun () -> for _ = 1 to 40 do s.ws_send_text frame done; Ok ()) in
    Alcotest.(check bool) "blocking sends return after the stall" true (sent = Ok ());
    let t0 = Eio.Time.now clock in
    for _ = 1 to 40 do s.ws_try_send_text frame done;
    Alcotest.(check bool) "try_send does not wait" true (Eio.Time.now clock -. t0 < 0.5);
    checked := true;
    (* a close with unread data resets the connection, which ends the server's blocked write *)
    Eio.Resource.close flow;
    Promise.resolve resolve_stop ()
  in
  (* the stalled connection's teardown is not under test: cut off after 5 s *)
  (match Eio.Time.with_timeout clock 5.0 (fun () -> run (); Ok ()) with Ok () | Error `Timeout -> ());
  Alcotest.(check bool) "checks done within 5 s" true !checked

let () =
  Alcotest.run "primal_common"
    [ ("nip44", [ Alcotest.test_case "padding" `Quick nip44_padding; Alcotest.test_case "conversation key" `Quick nip44_conversation_key; Alcotest.test_case "roundtrip" `Quick nip44_roundtrip ]);
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
      ("s3", [ Alcotest.test_case "sigv4 presign" `Quick test_s3_presign ]);
      ("langid", [ Alcotest.test_case "detect" `Quick test_langid ]);
      ("phases", [ Alcotest.test_case "slots" `Quick test_phases ]);
      ("procinfo", [ Alcotest.test_case "formatting" `Quick test_procinfo ]);
      ( "http_server",
        [ Alcotest.test_case "ws burst" `Quick test_ws_burst; Alcotest.test_case "ws stalled client" `Quick test_ws_stalled_client ] );
    ]
