(* Realtime spam detection, mirroring Julia src/spam_detection.jl (module SpamDetection).

   Notes are clustered by content similarity; once a cluster grows past a threshold its authors
   are treated as spammers. A single mutex (Julia's import_lock) serializes all clustering, so
   the detector is effectively single-threaded shared state — correct under the multi-domain
   worker pool. The caller (firehose handler) runs [on_message] on each message before importing
   it, passing the leased DB handle so the spamevent processors (e.g. store_spam_content_hash)
   can write.

   Processors mirror the Julia importer wiring (start_media_importer.jl):
   - spamlist_processors:  mark_spammers           -> Filterlist.add_access_pubkey_blocked_spam
   - spamevent_processors: mark_event_as_spam      -> Filterlist.add_access_event_blocked_spam
                           store_spam_content_hash -> Cache_storage_ext.store_spam_content_hash
   They are registered in bin/main.ml so this module need not depend on Filterlist / ext. *)

module CS = Cache_storage
module SS = Set.Make (String) (* raw 32-byte pubkeys / event ids *)

type cluster = { words : SS.t; mutable eids : string list }

type t = {
  cluster_size_threshold : int;
  min_note_size : int; (* words *)
  follower_cnt_threshold : int;
  spamlist_period : float;
  realtime_flush_period : float;
  mutex : Mutex.t;
  events : (string, Nostr.t) Hashtbl.t;
  latest_events : (string, Nostr.t) Hashtbl.t;
  mutable clusters : cluster list;
  mutable latest_clusters : cluster list;
  mutable realtime_spamlist : SS.t;
  mutable realtime_spamlist_diff : SS.t;
  mutable latest_spamlist : SS.t;
  mutable tlatest : float;
  mutable last_realtime_flush : float;
  mutable spamevent_processors : (CS.est -> Nostr.t -> unit) list;
  mutable spamlist_processors : (CS.est -> SS.t -> unit) list;
}

let create ?(cluster_size_threshold = 10) ?(min_note_size = 3) ?(follower_cnt_threshold = 50)
    ?(spamlist_period = 1200.) () : t =
  {
    cluster_size_threshold;
    min_note_size;
    follower_cnt_threshold;
    spamlist_period;
    realtime_flush_period = 10.;
    mutex = Mutex.create ();
    events = Hashtbl.create 4096;
    latest_events = Hashtbl.create 4096;
    clusters = [];
    latest_clusters = [];
    realtime_spamlist = SS.empty;
    realtime_spamlist_diff = SS.empty;
    latest_spamlist = SS.empty;
    tlatest = 0.;
    last_realtime_flush = 0.;
    spamevent_processors = [];
    spamlist_processors = [];
  }

let add_spamevent_processor sd p = sd.spamevent_processors <- p :: sd.spamevent_processors
let add_spamlist_processor sd p = sd.spamlist_processors <- p :: sd.spamlist_processors

(* Julia is_spam: similar length AND >90% shared words. *)
let is_spam (ewords : SS.t) (cwords : SS.t) : bool =
  let le = SS.cardinal ewords and lc = SS.cardinal cwords in
  lc > 0
  && abs_float (float_of_int (le - lc)) /. float_of_int lc < 0.10
  && float_of_int (SS.cardinal (SS.inter ewords cwords)) /. float_of_int lc > 0.90

(* Julia replaces a set of punctuation/newline separators with space, then splits on
   whitespace. We replace the same ASCII separators plus the other whitespace split() honours;
   the fullwidth comma is left as-is (rare; a minor divergence). *)
let split_words (content : string) : SS.t =
  let b = Bytes.of_string content in
  String.iteri
    (fun i c ->
      match c with
      | ':' | ';' | '/' | '.' | ',' | '?' | '!' | '\'' | '\n' | '\r' | '\t' -> Bytes.set b i ' '
      | _ -> ())
    content;
  String.split_on_char ' ' (Bytes.to_string b)
  |> List.filter (fun s -> s <> "")
  |> SS.of_list

let process_spamlist (sd : t) (est : CS.est) (spamlist : SS.t) : unit =
  List.iter (fun p -> try p est spamlist with _ -> ()) sd.spamlist_processors

(* Julia produce_spamlist: authors of every note in a large-enough latest cluster. *)
let produce_spamlist (sd : t) (est : CS.est) : unit =
  let spam = ref SS.empty in
  List.iter
    (fun c ->
      if List.length c.eids >= sd.cluster_size_threshold then
        List.iter
          (fun eid ->
            match Hashtbl.find_opt sd.latest_events eid with
            | Some ev -> spam := SS.add ev.Nostr.pubkey !spam
            | None -> ())
          c.eids)
    sd.latest_clusters;
  sd.latest_spamlist <- !spam;
  process_spamlist sd est !spam

let copy_table (src : ('a, 'b) Hashtbl.t) (dst : ('a, 'b) Hashtbl.t) : unit =
  Hashtbl.reset dst;
  Hashtbl.iter (fun k v -> Hashtbl.replace dst k v) src

let on_event (sd : t) ~(est : CS.est) (e : Nostr.t) (now : float) : bool =
  let notspam = ref true in
  Mutex.lock sd.mutex;
  Fun.protect
    ~finally:(fun () -> Mutex.unlock sd.mutex)
    (fun () ->
      if
        float_of_int e.created_at < now +. 300.
        && e.kind = Nostr.kind_text_note
        && (not (Hashtbl.mem sd.events e.id))
      then begin
        Hashtbl.replace sd.events e.id e;
        if Nostr.verify e && Cache_storage.pubkey_followers_cnt est e.pubkey < sd.follower_cnt_threshold
        then begin
          let ewords = split_words e.content in
          if SS.cardinal ewords >= sd.min_note_size then begin
            (* realtime: does this match an already-large latest cluster? *)
            (try
               List.iter
                 (fun c ->
                   if List.length c.eids >= sd.cluster_size_threshold && is_spam ewords c.words then begin
                     notspam := false;
                     sd.realtime_spamlist <- SS.add e.pubkey sd.realtime_spamlist;
                     sd.realtime_spamlist_diff <- SS.add e.pubkey sd.realtime_spamlist_diff;
                     if now -. sd.last_realtime_flush >= sd.realtime_flush_period then begin
                       sd.last_realtime_flush <- now;
                       process_spamlist sd est sd.realtime_spamlist_diff;
                       sd.realtime_spamlist_diff <- SS.empty
                     end;
                     List.iter (fun p -> try p est e with _ -> ()) sd.spamevent_processors;
                     raise Exit
                   end)
                 sd.latest_clusters
             with Exit -> ());
            (* add to (or open) a cluster *)
            try
              List.iter
                (fun c ->
                  if is_spam ewords c.words then begin
                    c.eids <- e.id :: c.eids;
                    raise Exit
                  end)
                sd.clusters;
              sd.clusters <- { words = ewords; eids = [ e.id ] } :: sd.clusters
            with Exit -> ()
          end;
          (* periodic snapshot + spamlist production *)
          if now -. sd.tlatest >= sd.spamlist_period then begin
            sd.tlatest <- now;
            copy_table sd.events sd.latest_events;
            sd.latest_clusters <- sd.clusters;
            Hashtbl.reset sd.events;
            sd.clusters <- [];
            sd.realtime_spamlist <- SS.empty;
            produce_spamlist sd est
          end
        end
      end);
  !notspam

let on_message (sd : t) ~(est : CS.est) (msg : string) (now : float) : bool =
  match try Nostr.event_from_msg (Yojson.Safe.from_string msg) with _ -> None with
  | Some (_relay, e) -> on_event sd ~est e now
  | None -> true
