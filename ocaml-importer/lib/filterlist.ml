(* In-memory filter sets, mirroring Julia src/filterlist.jl (module Filterlist).

   These are process-local sets keyed by raw 32-byte pubkeys / event ids. The spam detector
   populates them at runtime (mark_spammers -> access_pubkey_blocked_spam,
   mark_event_as_spam -> access_event_blocked_spam) and the ext_is_hidden hooks read them.

   In Julia these sets are also periodically reloaded from the membership `filterlist` table
   by a separate process (Filterlist.load). Seeding from the DB at startup is a TODO; for the
   staging importer they start empty and fill as spam is detected live, which matches the
   Julia importer process whose sets also begin empty until the first reload. *)

module SS = Set.Make (String)

(* A single mutex guards every set (sets are small, accesses are brief). Stdlib Mutex works
   across domains, which is what we need since the import workers and the spam detector touch
   these from different domains. *)
let m = Mutex.create ()

let with_lock f =
  Mutex.lock m;
  Fun.protect ~finally:(fun () -> Mutex.unlock m) f

let import_pubkey_blocked = ref SS.empty
let access_pubkey_unblocked = ref SS.empty
let access_pubkey_blocked_spam = ref SS.empty
let access_event_blocked_spam = ref SS.empty

(* Julia caps access_event_blocked_spam at 100000 with an OrderedSet (FIFO). We track the
   insertion order in a queue to evict the oldest. *)
let event_blocked_order = Queue.create ()
let event_blocked_cap = 100_000

(* {1 Predicates} (Julia: `x in Filterlist.<set>`) *)

let is_import_pubkey_blocked pk = with_lock (fun () -> SS.mem pk !import_pubkey_blocked)
let is_access_pubkey_unblocked pk = with_lock (fun () -> SS.mem pk !access_pubkey_unblocked)
let is_access_pubkey_blocked_spam pk = with_lock (fun () -> SS.mem pk !access_pubkey_blocked_spam)
let is_access_event_blocked_spam id = with_lock (fun () -> SS.mem id !access_event_blocked_spam)

(* {1 Mutators} (Julia: the spam detector's mark_spammers / mark_event_as_spam processors) *)

(* mark_spammers: add unless allowlisted in access_pubkey_unblocked. *)
let add_access_pubkey_blocked_spam pk =
  with_lock (fun () ->
      if not (SS.mem pk !access_pubkey_unblocked) then
        access_pubkey_blocked_spam := SS.add pk !access_pubkey_blocked_spam)

(* mark_event_as_spam: add event id, evicting oldest beyond the FIFO cap. *)
let add_access_event_blocked_spam id =
  with_lock (fun () ->
      if not (SS.mem id !access_event_blocked_spam) then begin
        access_event_blocked_spam := SS.add id !access_event_blocked_spam;
        Queue.add id event_blocked_order;
        while Queue.length event_blocked_order >= event_blocked_cap do
          let old = Queue.pop event_blocked_order in
          access_event_blocked_spam := SS.remove old !access_event_blocked_spam
        done
      end)

(* Bulk seed helpers (used by a future DB reloader; mirror Filterlist.load). *)
let set_access_pubkey_unblocked pks =
  with_lock (fun () -> access_pubkey_unblocked := SS.of_list pks)

let set_import_pubkey_blocked pks =
  with_lock (fun () -> import_pubkey_blocked := SS.of_list pks)
