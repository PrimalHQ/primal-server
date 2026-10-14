open Primal_jobs_media

let julia_float () =
  let eq name a b = Alcotest.(check string) name b a in
  eq "4.651567" (Pgj.julia_float 4.651567) "4.651567";
  eq "0.0" (Pgj.julia_float 0.0) "0.0";
  eq "1.5" (Pgj.julia_float 1.5) "1.5";
  eq "2.0" (Pgj.julia_float 2.0) "2.0";
  eq "100000.0" (Pgj.julia_float 100000.0) "100000.0";
  eq "123456.0" (Pgj.julia_float 123456.0) "123456.0";
  eq "0.00001" (Pgj.julia_float 0.00001) "1.0e-5";
  eq "1e6" (Pgj.julia_float 1000000.0) "1.0e6";
  eq "time" (Pgj.julia_float 1791140507.318978) "1.791140507318978e9";
  eq "small" (Pgj.julia_float 0.0001) "0.0001";
  eq "tiny" (Pgj.julia_float 0.000001) "1.0e-6";
  eq "frac" (Pgj.julia_float (4.651567 /. 6.0)) "0.7752611666666667"

(* a media_storage row the Rust executor wrote: key {"url","type":"resized","size":"small","animated":false} *)
let key_hash () =
  let url = "https://npub1yaa6zcll5vr4d5uhaqduz6886kkc9m5ac8jkaf0avqpmv56qlu7svu64kh.blossom.band/10e2a966e83aa2cb927771118d1a682875704dc5b8bb72f846178a60e733380b.gif" in
  let k : Media_store.key = [ ("url", `String url); ("type", `String "resized"); ("size", `String "small"); ("animated", `Bool false) ] in
  Alcotest.(check string) "h" "da65c6b462e11b7fb259ff6e74058139a07fe075dfcba364589e87602ec543c6" (Media_store.key_h k);
  Alcotest.(check string) "subdir" "d/a6/5c" (Media_store.subdir_of_h (Media_store.key_h k))

let typed_json () =
  let n = Pgj.tuple [ Pgj.cache_storage; Pgj.event_id_hex "ab"; `String "u" ] in
  Alcotest.(check string) "tuple" {|{"_ty":"Tuple","_v":[{"_ty":"CacheStorage","_v":null},{"_ty":"EventId","_v":"ab"},"u"]}|} (Pgj.to_string n);
  Alcotest.(check (list (pair string bool))) "specs" [ ("original", true); ("original", false) ] (List.filteri (fun i _ -> i < 2) (Pgj.variant_specs_of Pgj.all_variants));
  Alcotest.(check (option string)) "symbol" (Some "small") (Pgj.as_symbol (Pgj.symbol "small"))

let blossom_paths () =
  let open Primal_jobs_media.Blossom in
  let srv = "https://media.primal.net" and sha = "ef940339e4e34e12520827cf3651c8bbd93c33ba3e3d2d80defc3909ec429050" in
  let rel p = remote_relpath_for ~media_url:(srv ^ p) ~media_server_url:srv ~sha256_hex:sha in
  Alcotest.(check (result string string)) "uploads2" (Ok "/uploads2/e/f9/40/ef940339e4e34e12520827cf3651c8bbd93c33ba3e3d2d80defc3909ec429050.mp3") (rel "/uploads2/e/f9/40/ef940339e4e34e12520827cf3651c8bbd93c33ba3e3d2d80defc3909ec429050.mp3");
  Alcotest.(check (result string string)) "legacy uploads" (Ok "/uploads/e/f9/40/ef940339e4e34e12520827cf3651c8bbd93c33ba3e3d2d80defc3909ec429050.jpg") (rel "/uploads/e/f9/40/ef940339e4e34e12520827cf3651c8bbd93c33ba3e3d2d80defc3909ec429050.jpg");
  Alcotest.(check bool) "other server" true (Result.is_error (remote_relpath_for ~media_url:("https://other/uploads2/x/" ^ sha ^ ".jpg") ~media_server_url:srv ~sha256_hex:sha));
  Alcotest.(check bool) "outside uploads" true (Result.is_error (rel ("/cache/e/f9/40/" ^ sha ^ ".jpg")));
  Alcotest.(check bool) "dotdot" true (Result.is_error (rel ("/uploads2/../" ^ sha ^ ".jpg")));
  Alcotest.(check bool) "wrong name" true (Result.is_error (rel "/uploads2/e/f9/40/0000.jpg"));
  Alcotest.(check string) "sha of path" sha (Hex_util.encode (sha_of_path ("/" ^ sha ^ ".jpg")));
  Alcotest.(check string) "sha of bare path" sha (Hex_util.encode (sha_of_path sha));
  Alcotest.check_raises "bad sha" (Http_error (400, "invalid sha256")) (fun () -> ignore (sha_of_path "/zz.jpg"));
  Alcotest.(check string) "ext" ".mp4" (ext_of "video/x-m4v");
  Alcotest.(check string) "no ext" "" (ext_of "application/x-unknown")

let proc_run () =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env and proc_mgr = Eio.Stdenv.process_mgr env in
  let r = Primal_jobs_media.Proc.run ~proc_mgr ~clock [ "echo"; "hi" ] in
  Alcotest.(check (pair int string)) "echo" (0, "hi\n") (r.status, r.stdout);
  let big = String.make 3_000_000 'x' in
  let r = Primal_jobs_media.Proc.run ~proc_mgr ~clock ~stdin_data:big [ "cat" ] in
  Alcotest.(check (pair int int)) "cat 3 MB through stdin" (0, 3_000_000) (r.status, String.length r.stdout);
  let r = Primal_jobs_media.Proc.run ~proc_mgr ~clock [ "sh"; "-c"; "echo err >&2; exit 3" ] in
  Alcotest.(check (pair int string)) "exit code and stderr" (3, "err\n") (r.status, r.stderr);
  let r = Primal_jobs_media.Proc.run ~proc_mgr ~clock ~timeout:0.3 [ "sleep"; "5" ] in
  Alcotest.(check int) "timeout" 124 r.status;
  let rs = Eio.Fiber.List.map ~max_fibers:20 (fun i -> (Primal_jobs_media.Proc.run ~proc_mgr ~clock ~stdin_data:(string_of_int i) [ "cat" ]).stdout) (List.init 50 Fun.id) in
  Alcotest.(check (list string)) "50 concurrent" (List.init 50 string_of_int) rs

(* direct (unproxied) downloads: chosen by the parsed host only, and to public addresses only *)
let direct_hosts () =
  let direct u = Media_tools.url_host_under Media_tools.direct_domains u in
  let yes u = Alcotest.(check bool) u true (direct u) and no u = Alcotest.(check bool) u false (direct u) in
  yes "https://media.primal.net/cache/a.png";
  yes "https://R2.Primal.NET/x.jpg";
  yes "https://primal.net/a.png";
  yes "http://blossom.primal.net:8080/a.png";
  no "http://192.168.1.20:8080/x?.primal.net/a.png";
  no "http://127.0.0.1/a.png#.primal.net";
  no "http://evil.example/.primal.net/a.png";
  no "https://primal.net.evil.example/a.png";
  no "https://evilprimal.net/a.png";
  no "http://192.168.1.20@media.primal.net/a.png";
  no "https://primaldata.s3.us-east-005.backblazeb2.com/a.png";
  no "not a url .primal.net";
  Alcotest.(check bool) "node timeout" true (Media_tools.url_host_under Media_tools.long_timeout_domains "https://x.primalnode.net/a");
  let ip s = Eio.Net.Ipaddr.of_raw (Ipaddr.to_octets (Ipaddr.of_string_exn s)) in
  let public s = Alcotest.(check bool) s true (Http.is_public_ip (ip s)) and private_ s = Alcotest.(check bool) s false (Http.is_public_ip (ip s)) in
  List.iter public [ "1.1.1.1"; "8.8.8.8"; "100.63.255.255"; "100.128.0.0"; "172.15.255.255"; "172.32.0.0"; "192.169.0.1"; "2606:4700::1111" ];
  List.iter private_
    [ "0.0.0.0"; "10.1.2.3"; "100.64.0.1"; "127.0.0.1"; "169.254.169.254"; "172.16.0.1"; "172.31.255.255"; "192.168.1.20"; "192.0.2.1"; "198.18.0.1"; "224.0.0.1"; "255.255.255.255";
      "::1"; "::"; "fe80::1"; "fd00::1"; "::ffff:192.168.1.20"; "2001:db8::1" ]

(* with no proxies configured, a download from a loopback server is refused before connecting *)
let download_refuses_private () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env and clock = Eio.Stdenv.clock env in
  let paths = `Assoc [ ("uploadfast", `List []); ("upload", `List []); ("cache", `List []) ] in
  let s k = (k, `String "") and n k = (k, `Int 1) in
  let cfg =
    Media_config.of_json
      (`Assoc
        ([ ("proxies", `List []); ("metadata_proxy", `Null); ("strip_image_metadata", `Bool false); ("log", `Bool false); ("s3_providers", `List []); ("hls_providers", `List []);
           ("media_paths", paths); ("media_paths_2", paths); ("cloudflare_cache", `Null); ("blossom_hosts", `List []); ("ffmpeg_remote_host", `Null); ("user_content_purger_api", `Null); ("execute_funcs", `Null) ]
        @ List.map s [ "binary_data_cache_dir"; "media_url_root"; "tmp_dir"; "ai_host"; "blossom_host"; "upload_url_root" ]
        @ List.map n [ "download_timeout_s"; "hls_processing_timeout_s"; "ai_timeout_s"; "scheduler_period_s"; "max_concurrent_per_name"; "julia_duty_concurrency"; "refresh_matview_period_s" ]))
  in
  let ci = { Postgres.host = "127.0.0.1"; port = 1; user = ""; database = "" } in
  let ctx = { Procgraph.cfg; cache = Postgres.make_pool ~size:1 ci; mem = Postgres.make_pool ~size:1 ci; net; clock; proc_mgr = Eio.Stdenv.process_mgr env; domain_mgr = Eio.Stdenv.domain_mgr env; verbose = false } in
  Eio.Switch.run @@ fun sw ->
  let sock = Eio.Net.listen ~sw ~backlog:4 ~reuse_addr:true net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
  let port = match Eio.Net.listening_addr sock with `Tcp (_, p) -> p | _ -> assert false in
  let accepted = ref 0 in
  Eio.Fiber.fork_daemon ~sw (fun () ->
      while true do
        Eio.Net.accept_fork ~sw sock ~on_error:ignore (fun flow _ ->
            incr accepted;
            Eio.Flow.copy_string "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok" flow)
      done;
      `Stop_daemon);
  let url = Printf.sprintf "http://127.0.0.1:%d/x?.primal.net/a.png" port in
  let r = try Ok (Media_tools.download ctx url) with Procgraph.Node_error m -> Error m in
  Alcotest.(check (result string string)) "refused" (Error (Printf.sprintf "download %s: refused: 127.0.0.1: not a public address" url)) r;
  Alcotest.(check int) "never connected" 0 !accepted

let () = Alcotest.run "primal_jobs_media" [ ("download", [ Alcotest.test_case "direct hosts" `Quick direct_hosts; Alcotest.test_case "refuses private" `Quick download_refuses_private ]); ("proc", [ Alcotest.test_case "run" `Quick proc_run ]); ("blossom", [ Alcotest.test_case "paths" `Quick blossom_paths ]); ("pgj", [ Alcotest.test_case "julia_float" `Quick julia_float; Alcotest.test_case "typed json" `Quick typed_json ]); ("store", [ Alcotest.test_case "key hash" `Quick key_hash ]) ]
