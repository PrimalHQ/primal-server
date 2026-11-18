(* The pure parts of the lean-schema behaviours: the retired "lean" config key, the DAG's half-open
   segments, the DVM checker's relay hints and backoff, and pg_listener's pair set. *)
open Primal_jobs

let lean_config () =
  let parse s = Config.of_json (Yojson.Safe.from_string s) in
  match parse {|{"lean": {"enabled": true}}|} with
  | _ -> Alcotest.fail "the retired lean object was accepted"
  | exception Config.Config_error m -> Alcotest.(check string) "the lean key first" "lean" (String.sub m 0 4)

(* consecutive runs over [since, until) windows with the coverage they record: how often each
   second is processed *)
let simulate ~step ~windows =
  let cov = Hashtbl.create 16 and counts = Hashtbl.create 1024 in
  List.iter
    (fun (since, until) ->
      let done_ = Hashtbl.fold (fun t t2 acc -> (t, t2) :: acc) cov [] in
      List.iter
        (fun (t, t1, t2) ->
          for s = t1 to t2 - 1 do
            Hashtbl.replace counts s (1 + Option.value (Hashtbl.find_opt counts s) ~default:0)
          done;
          Hashtbl.replace cov t t2)
        (Dag.segments ~since ~until ~step ~done_))
    windows;
  counts

let windows ~start ~n =
  let rec go since i acc = if i = n then List.rev acc else let until = since + 1 + Random.int 9 in go until (i + 1) ((since, until) :: acc) in
  go start 0 []

let half_open_once () =
  Random.init 11;
  List.iter
    (fun step ->
      let ws = windows ~start:1000 ~n:300 in
      let final = snd (List.nth ws (List.length ws - 1)) in
      let counts = simulate ~step ~windows:ws in
      for s = 1000 to final - 1 do
        Alcotest.(check int) (Printf.sprintf "step %d second %d" step s) 1 (Option.value (Hashtbl.find_opt counts s) ~default:0)
      done;
      Alcotest.(check bool) "nothing at or after until" false (Hashtbl.mem counts final))
    [ 7; 60; 86_400 ]

(* a window again over what is covered: nothing to do; an empty window: nothing *)
let half_open_covered () =
  let segs = Dag.segments ~since:100 ~until:120 ~step:60 ~done_:[ (60, 120) ] in
  Alcotest.(check (list (triple int int int))) "covered" [] segs;
  Alcotest.(check (list (triple int int int))) "empty" [] (Dag.segments ~since:120 ~until:120 ~step:60 ~done_:[]);
  Alcotest.(check (list (triple int int int))) "step boundary" [ (60, 110, 120); (120, 120, 125) ] (Dag.segments ~since:110 ~until:125 ~step:60 ~done_:[ (60, 110) ])

let relay_hints () =
  let tags =
    Yojson.Safe.from_string
      {|[["d","x"],["k","5300"],["relays","wss://a.example","http://no.example","wss://b.example"],["r","wss://c.example/"],["relay"," wss://a.example "],["r"],["relays",1]]|}
  in
  let tags = match tags with `List l -> l | _ -> [] in
  Alcotest.(check (list string)) "hints" [ "wss://a.example"; "wss://b.example"; "wss://c.example/" ] (Dvm_checker.relay_hints tags);
  Alcotest.(check (list string)) "none" [] (Dvm_checker.relay_hints [ `List [ `String "k"; `String "5300" ] ])

let seen_prune () =
  let module S = Pg_listener.Seen in
  let t = S.create () in
  let put coord last n =
    let en = { S.followers = Hashtbl.create 4; last } in
    Hashtbl.replace t.S.by_coord coord en;
    for i = 1 to n do S.add t en (Printf.sprintf "%s-%d" coord i) done
  in
  put "old" 0.0 3;
  put "a" 100_000.0 (S.max_pairs / 2);
  put "b" 100_001.0 (S.max_pairs / 2);
  put "c" 100_002.0 10;
  Alcotest.(check int) "pairs" (3 + S.max_pairs + 10) t.S.pairs;
  S.prune t ~now:100_003.0 ~keep:"c";
  Alcotest.(check bool) "expired gone" false (Hashtbl.mem t.S.by_coord "old");
  Alcotest.(check bool) "oldest gone" false (Hashtbl.mem t.S.by_coord "a");
  Alcotest.(check bool) "kept" true (Hashtbl.mem t.S.by_coord "b" && Hashtbl.mem t.S.by_coord "c");
  Alcotest.(check int) "pairs after" ((S.max_pairs / 2) + 10) t.S.pairs;
  let en = Hashtbl.find t.S.by_coord "c" in
  S.add t en "c-1";
  Alcotest.(check int) "add is idempotent" ((S.max_pairs / 2) + 10) t.S.pairs

(* failing handlers wait 1, 2, 4, ... periods (capped), answering ones and new ones go first *)
let backoff () =
  let module B = Dvm_checker.Backoff in
  let period = 600.0 and max_s = 3600.0 in
  let fl = Alcotest.(check (float 1e-9)) in
  fl "n=0" 0.0 (B.delay ~period ~max_s 0);
  fl "n=1" 600.0 (B.delay ~period ~max_s 1);
  fl "n=2" 1200.0 (B.delay ~period ~max_s 2);
  fl "n=3" 2400.0 (B.delay ~period ~max_s 3);
  fl "capped" 3600.0 (B.delay ~period ~max_s 4);
  let t = B.create () in
  let a = ("pa", "a") and b = ("pb", "b") and c = ("pc", "c") in
  B.failed t ~now:0.0 a;
  B.failed t ~now:0.0 a;
  B.failed t ~now:0.0 b;
  let keys (l, n) = (List.map fst l, n) in
  let items = [ (a, ()); (b, ()); (c, ()) ] in
  let pl now = keys (B.plan t ~period ~max_s ~now items) in
  let chk = Alcotest.(check (pair (list (pair string string)) int)) in
  chk "b due after one period, a not yet" ([ c; b ], 1) (pl 700.0);
  chk "both due later, the new one first" ([ c; a; b ], 0) (pl 1300.0);
  B.succeeded t a;
  chk "an answer resets" ([ a; c; b ], 0) (pl 1300.0);
  chk "off: every handler" ([ a; c; b ], 0) (keys (B.plan t ~period ~max_s:0.0 ~now:0.0 items));
  ignore (B.plan t ~period ~max_s ~now:0.0 [ (a, ()) ]);
  Alcotest.(check bool) "unlisted entries dropped" false (Hashtbl.mem t b)

let () =
  Alcotest.run "primal_jobs_lean"
    [ ("config", [ Alcotest.test_case "retired lean object" `Quick lean_config ]);
      ("dag", [ Alcotest.test_case "half-open once" `Quick half_open_once; Alcotest.test_case "half-open covered" `Quick half_open_covered ]);
      ("dvm_checker", [ Alcotest.test_case "relay hints" `Quick relay_hints; Alcotest.test_case "backoff" `Quick backoff ]);
      ("pg_listener", [ Alcotest.test_case "seen prune" `Quick seen_prune ]) ]
