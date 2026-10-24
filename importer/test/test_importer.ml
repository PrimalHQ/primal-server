(* Pure-logic tests for the importer's lean mode (importer/lib/lean.ml and the pure parts around it). *)

module L = Primal_importer.Lean
module Cfg = Primal_importer.Config
module ES = Primal_importer.Event_syncer

let parse s = L.of_json (Yojson.Safe.from_string s)

let ok s =
  match parse s with Ok l -> l | Error e -> Alcotest.failf "unexpected error for %s: %s" s e

let is_error s = match parse s with Ok _ -> false | Error _ -> true

let test_lean_parse () =
  Alcotest.(check bool) "null = off" true (ok "null" = L.off);
  Alcotest.(check bool) "{} = off" true (ok "{}" = L.off);
  Alcotest.(check bool) "off is inactive" false (L.active L.off);
  let l = ok {|{"enabled": true, "lazy_counters": true, "kind_allowlist": [0, 3, 10002, 30023], "keep_versions_kinds": [30023, 30311], "hooks_expire_days": 7}|} in
  Alcotest.(check bool) "enabled" true l.enabled;
  Alcotest.(check bool) "lazy" true l.lazy_counters;
  Alcotest.(check bool) "others off" false (l.no_hashtags || l.transaction_per_event || l.delete_superseded);
  Alcotest.(check (list int)) "keep" [ 30023; 30311 ] l.keep_versions_kinds;
  Alcotest.(check int) "expire days" 7 l.hooks_expire_days;
  Alcotest.(check bool) "active" true (L.active l);
  Alcotest.(check bool) "null values are defaults" true (ok {|{"enabled": null, "kind_allowlist": null}|} = L.off);
  Alcotest.(check bool) "allowlist alone is active" true (L.active (ok {|{"kind_allowlist": []}|}));
  Alcotest.(check bool) "unknown key" true (is_error {|{"enabeld": true}|});
  Alcotest.(check bool) "wrong type" true (is_error {|{"enabled": 1}|});
  Alcotest.(check bool) "list of non-ints" true (is_error {|{"kind_allowlist": ["0"]}|});
  Alcotest.(check bool) "zero days" true (is_error {|{"hooks_expire_days": 0}|});
  Alcotest.(check bool) "not an object" true (is_error {|[1]|})

(* A complete importer config as the deploy writes it (no "lean" key): it must still parse. *)
let base_config =
  {|{"firehose_host": "127.0.0.1", "firehose_port": 9017, "num_workers": 4, "queue_capacity": 10000,
     "proxy": null, "event_sync_enabled": false, "event_sync_remotes": [], "event_sync_interval": 60,
     "event_sync_overlap": 600, "event_sync_backfill": null, "pushgateway_enabled": false,
     "pushgateway_host": "127.0.0.1", "pushgateway_port": 9091, "pushgateway_job": "j",
     "pushgateway_stats_file": "/tmp/s.json", "pushgateway_interval": 15,
     "push_notifications_enabled": false, "push_notification_sender_bin": "x",
     "push_notifications_period": 5, "push_notifications_log": false, "push_intake_host": "0.0.0.0",
     "push_intake_ports": [], "verification_enabled": true, "verify_zappers": true, "trusted_zappers": [],
     "disable_trustrank": false, "import_reporting": false, "reporting_whitelist": [],
     "download_media": false, "download_previews": false,
     "cache_db": {"host": "h", "port": 5432, "user": "u", "database": "d"},
     "membership_db": {"host": "h", "port": 5432, "user": "u", "database": "m"},
     "humaness_threshold": null, "import_listener_enabled": false, "import_listener_host": "0.0.0.0",
     "import_listener_port": 12018, "expire_scores_enabled": false, "scheduled_hooks_enabled": true,
     "content_moderation_rules_enabled": true, "default_settings_file": null,
     "relay_broadcast_timeout": 15, "poll_vote_import_enabled": true}|}

let with_key k v =
  match Yojson.Safe.from_string base_config with
  | `Assoc l -> `Assoc (l @ [ (k, Yojson.Safe.from_string v) ])
  | _ -> assert false

let test_config () =
  let c = Cfg.of_json (Yojson.Safe.from_string base_config) in
  Alcotest.(check bool) "no lean key = off" true (c.Cfg.cs.Primal_importer.Cache_storage.lean = L.off);
  let c = Cfg.of_json (with_key "lean" "null") in
  Alcotest.(check bool) "lean null = off" true (c.Cfg.cs.Primal_importer.Cache_storage.lean = L.off);
  let c = Cfg.of_json (with_key "lean" {|{"enabled": true, "no_hashtags": true}|}) in
  let l = c.Cfg.cs.Primal_importer.Cache_storage.lean in
  Alcotest.(check bool) "lean parsed" true (l.L.enabled && l.L.no_hashtags && not l.L.lazy_counters);
  Alcotest.(check bool) "typo is a config error" true
    (match Cfg.of_json (with_key "lean" {|{"lazy_counter": true}|}) with
    | _ -> false
    | exception Cfg.Config_error _ -> true)

let test_kind_allowlist () =
  let l = ok {|{"kind_allowlist": [0, 10002, 30023]}|} in
  List.iter
    (fun (k, want) -> Alcotest.(check bool) (Printf.sprintf "kind %d" k) want (L.kind_allowed l k))
    [ (0, true); (3, false); (1, true); (7, true); (9735, true); (10000, false); (10002, true);
      (30023, true); (30078, false); (39089, false); (20001, true) (* not governed: accepted_kind decides *) ];
  Alcotest.(check bool) "no allowlist" true (List.for_all (L.kind_allowed L.off) [ 0; 3; 10000; 30078 ])

let test_newer () =
  let a = String.make 32 '\001' and b = String.make 32 '\002' in
  Alcotest.(check bool) "greater created_at" true (L.newer ~created_at:11 ~id:b ~old_created_at:10 ~old_id:a);
  Alcotest.(check bool) "smaller created_at" false (L.newer ~created_at:9 ~id:a ~old_created_at:10 ~old_id:b);
  Alcotest.(check bool) "tie, lower id wins" true (L.newer ~created_at:10 ~id:a ~old_created_at:10 ~old_id:b);
  Alcotest.(check bool) "tie, higher id loses" false (L.newer ~created_at:10 ~id:b ~old_created_at:10 ~old_id:a);
  Alcotest.(check bool) "same event" false (L.newer ~created_at:10 ~id:a ~old_created_at:10 ~old_id:a)

(* Apply a diff to a multiset of rows and compare with what delete-all + reinsert would leave. *)
let apply_diff existing (d : L.bookmark_diff) =
  let rows = if d.del_nonplain then List.filter (fun (id, plain) -> id <> None && plain) existing else existing in
  let rows = List.filter (fun (id, _) -> match id with Some i -> not (List.mem i d.del_ids) | None -> true) rows in
  List.sort compare (rows @ List.map (fun i -> (Some i, true)) d.ins)

let check_diff name existing desired =
  let d = L.bookmark_diff ~existing ~desired in
  let want = List.sort compare (List.map (fun i -> (Some i, true)) desired) in
  Alcotest.(check bool) name true (apply_diff existing d = want);
  d

let test_bookmark_diff () =
  let p x = (Some x, true) in
  let d = check_diff "add one" [ p "a"; p "b" ] [ "a"; "b"; "c" ] in
  Alcotest.(check (list string)) "add one: one insert" [ "c" ] d.ins;
  Alcotest.(check (list string)) "add one: no delete" [] d.del_ids;
  let d = check_diff "remove one" [ p "a"; p "b"; p "c" ] [ "a"; "c" ] in
  Alcotest.(check (list string)) "remove one: one delete" [ "b" ] d.del_ids;
  Alcotest.(check (list string)) "remove one: no insert" [] d.ins;
  let d = check_diff "unchanged" [ p "a"; p "b" ] [ "b"; "a" ] in
  Alcotest.(check bool) "unchanged: nothing" true (d.ins = [] && d.del_ids = [] && not d.del_nonplain);
  ignore (check_diff "duplicate tag" [ p "a" ] [ "a"; "a" ]);
  ignore (check_diff "duplicate rows shrink" [ p "a"; p "a"; p "a" ] [ "a"; "b" ]);
  let d = check_diff "non-plain rows" [ (Some "a", false); (None, true); p "b" ] [ "a"; "b" ] in
  Alcotest.(check bool) "non-plain deleted" true d.del_nonplain;
  ignore (check_diff "empty list" [ p "a"; p "b" ] []);
  ignore (check_diff "from nothing" [] [ "x"; "y" ])

let test_ttl () =
  let t = L.Ttl.create ~max:3 ~ttl:10.0 () in
  let calls = ref 0 in
  let get ~now k = L.Ttl.find_or_add ~now t k (fun () -> incr calls; k * 10) in
  Alcotest.(check int) "computed" 10 (get ~now:0.0 1);
  Alcotest.(check int) "cached" 10 (get ~now:5.0 1);
  Alcotest.(check int) "one call" 1 !calls;
  ignore (get ~now:11.0 1);
  Alcotest.(check int) "expired: recomputed" 2 !calls;
  (match L.Ttl.find_or_add ~now:12.0 t 7 (fun () -> failwith "db down") with
  | _ -> Alcotest.fail "expected the failure"
  | exception Failure _ -> ());
  ignore (get ~now:12.0 7);
  Alcotest.(check int) "a failure is not cached" 3 !calls;
  ignore (get ~now:12.0 2);
  ignore (get ~now:12.0 3);
  ignore (get ~now:12.0 4);
  (* the table reached max: dropped whole, then refilled *)
  ignore (get ~now:12.0 1);
  Alcotest.(check int) "reset at max" 7 !calls

let test_superseded () =
  L.Superseded.add ~now:100.0 "id1";
  Alcotest.(check bool) "member" true (L.Superseded.mem ~now:200.0 "id1");
  Alcotest.(check bool) "expired" false (L.Superseded.mem ~now:(100.0 +. L.Superseded.ttl +. 1.0) "id1");
  Alcotest.(check bool) "other" false (L.Superseded.mem ~now:200.0 "id2")

let test_syncer_helpers () =
  Alcotest.(check string) "bytea array literal" {|{"\\x0102","\\xff"}|} (ES.bytea_array [ "\001\002"; "\255" ]);
  Alcotest.(check (list (list int))) "chunks" [ [ 1; 2 ]; [ 3; 4 ]; [ 5 ] ] (ES.chunks 2 [ 1; 2; 3; 4; 5 ]);
  Alcotest.(check (list (list int))) "no chunks" [] (ES.chunks 2 []);
  let l = ok {|{"kind_allowlist": [0, 3]}|} in
  Alcotest.(check bool) "wanted note" true (ES.wanted_kind l 1);
  Alcotest.(check bool) "unaccepted kind" false (ES.wanted_kind l 20001);
  Alcotest.(check bool) "blocked kind" false (ES.wanted_kind L.off 29333);
  Alcotest.(check bool) "not allowlisted" false (ES.wanted_kind l 30078)

let () =
  Alcotest.run "importer"
    [
      ( "lean",
        [
          Alcotest.test_case "parse" `Quick test_lean_parse;
          Alcotest.test_case "config" `Quick test_config;
          Alcotest.test_case "kind allowlist" `Quick test_kind_allowlist;
          Alcotest.test_case "newer" `Quick test_newer;
          Alcotest.test_case "bookmark diff" `Quick test_bookmark_diff;
          Alcotest.test_case "ttl cache" `Quick test_ttl;
          Alcotest.test_case "superseded" `Quick test_superseded;
          Alcotest.test_case "syncer helpers" `Quick test_syncer_helpers;
        ] );
    ]
