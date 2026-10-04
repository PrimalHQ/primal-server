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

let () = Alcotest.run "primal_jobs_media" [ ("pgj", [ Alcotest.test_case "julia_float" `Quick julia_float; Alcotest.test_case "typed json" `Quick typed_json ]); ("store", [ Alcotest.test_case "key hash" `Quick key_hash ]) ]
