(* The pure parts of the "lean" config behaviours: config parsing, the DAG's segments (closed and
   half-open), the DVM checker's relay hints and pg_listener's pair set. *)
open Primal_jobs

let lean_config () =
  let parse s = Config.lean_of_json (Yojson.Safe.from_string s) in
  let err s = match parse s with _ -> Alcotest.failf "%s: accepted" s | exception Config.Config_error _ -> () in
  Alcotest.(check bool) "absent" false (parse {|{"roles": []}|});
  Alcotest.(check bool) "null" false (parse {|{"lean": null}|});
  Alcotest.(check bool) "on" true (parse {|{"lean": {"enabled": true}}|});
  Alcotest.(check bool) "off" false (parse {|{"lean": {"enabled": false}}|});
  err {|{"lean": {}}|};
  err {|{"lean": {"enabled": true, "enable": true}}|};
  err {|{"lean": {"enabled": 1}}|};
  err {|{"lean": true}|}

(* the segment rule as it was before the lean switch (closed segments) *)
let old_segments ~since ~until ~step ~done_ =
  let rec go t acc =
    if t > until then acc
    else
      let acc =
        match List.assoc_opt t done_ with
        | None -> (t, max t since, min (t + step) until) :: acc
        | Some t2 when t2 - t < step && max t2 since < min (t + step) until -> (t, max t2 since, min (t + step) until) :: acc
        | Some _ -> acc
      in
      go (t + step) acc
  in
  List.rev (go (since / step * step) [])

let closed_unchanged () =
  Random.init 7;
  for _ = 1 to 2000 do
    let step = 1 + Random.int 50 in
    let since = Random.int 500 in
    let until = since + Random.int 200 in
    let done_ = List.init (Random.int 6) (fun _ -> let t = Random.int 20 * step in (t, t + Random.int (step + 3))) in
    let done_ = List.sort_uniq (fun (a, _) (b, _) -> compare a b) done_ in
    Alcotest.(check (list (triple int int int))) "same segments" (old_segments ~since ~until ~step ~done_) (Dag.segments ~lean:false ~since ~until ~step ~done_)
  done

(* consecutive runs over [since, until) windows with the coverage they record: how often each
   second is processed *)
let simulate ~lean ~step ~windows =
  let cov = Hashtbl.create 16 and counts = Hashtbl.create 1024 in
  List.iter
    (fun (since, until) ->
      let done_ = Hashtbl.fold (fun t t2 acc -> (t, t2) :: acc) cov [] in
      List.iter
        (fun (t, t1, t2) ->
          let last = if lean then t2 - 1 else t2 in
          for s = t1 to last do
            Hashtbl.replace counts s (1 + Option.value (Hashtbl.find_opt counts s) ~default:0)
          done;
          Hashtbl.replace cov t t2)
        (Dag.segments ~lean ~since ~until ~step ~done_))
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
      let counts = simulate ~lean:true ~step ~windows:ws in
      for s = 1000 to final - 1 do
        Alcotest.(check int) (Printf.sprintf "step %d second %d" step s) 1 (Option.value (Hashtbl.find_opt counts s) ~default:0)
      done;
      Alcotest.(check bool) "nothing at or after until" false (Hashtbl.mem counts final);
      (* closed: the boundary seconds come twice *)
      let counts = simulate ~lean:false ~step ~windows:ws in
      Alcotest.(check bool) "closed repeats boundaries" true (Hashtbl.fold (fun _ c acc -> acc || c > 1) counts false))
    [ 7; 60; 86_400 ]

(* a window again over what is covered: nothing to do; an empty window: nothing *)
let half_open_covered () =
  let segs = Dag.segments ~lean:true ~since:100 ~until:120 ~step:60 ~done_:[ (60, 120) ] in
  Alcotest.(check (list (triple int int int))) "covered" [] segs;
  Alcotest.(check (list (triple int int int))) "empty" [] (Dag.segments ~lean:true ~since:120 ~until:120 ~step:60 ~done_:[]);
  Alcotest.(check (list (triple int int int))) "step boundary" [ (60, 110, 120); (120, 120, 125) ] (Dag.segments ~lean:true ~since:110 ~until:125 ~step:60 ~done_:[ (60, 110) ])

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

let () =
  Alcotest.run "primal_jobs_lean"
    [ ("config", [ Alcotest.test_case "lean object" `Quick lean_config ]);
      ("dag", [ Alcotest.test_case "closed unchanged" `Quick closed_unchanged; Alcotest.test_case "half-open once" `Quick half_open_once; Alcotest.test_case "half-open covered" `Quick half_open_covered ]);
      ("dvm_checker", [ Alcotest.test_case "relay hints" `Quick relay_hints ]);
      ("pg_listener", [ Alcotest.test_case "seen prune" `Quick seen_prune ]) ]
