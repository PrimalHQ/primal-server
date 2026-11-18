(* Kind lists of the lean cache schema that the queries share (the importer's own lists in
   importer/lib/cache_storage.ml must match). Until 2026-11 this module also held the optional
   "lean" config object (absent = the classic schema's queries); the classic queries are gone. *)

(* The kinds the importer creates an event_stats row for (cache_storage.ml is_note_kind), without
   30023 (articles answer from reads). With lazy counter rows a missing row of one of these is all
   zeros; other kinds never had a row. *)
let stats_kinds = [ 1; 1068; 6969; 20; 34235; 34236; 1111 ]

(* is_note_kind with 30023: the kinds whose events have (or, lazily, stand for) an event_stats row *)
let note_kinds = 30023 :: stats_kinds

(* the kinds the importer writes to pubkey_events (cache_storage.ml is_pubkey_event_kind) *)
let pubkey_events_kinds = [ 1; 1068; 6969; 20; 34235; 34236; 6 ]

(* sql array literals of the lists above, for statements that cannot take them as parameters *)
let sql_ints l = String.concat ", " (List.map string_of_int l)
