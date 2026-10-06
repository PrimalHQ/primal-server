(* A short-lived cache of feed pages answered for the anonymous default pubkey.

   Every logged-out visitor asks the same questions (the webapp requests the home and reads feeds
   with Handlers.primal_pubkey on every route), and each one re-ran the windowed search; here the
   first answer within [ttl] seconds is reused. Only mega_feed_directive /
   multi_kind_mega_feed_directive with user_pubkey = the primal pubkey (or none) are eligible, and
   only Handled outcomes without live-event registrations are stored. Concurrent misses for one key
   wait for the first computation (one promise per key) instead of piling onto the database; if it
   fails or is cancelled the waiters compute for themselves. Shared across domains (Stdlib mutex,
   held only for table operations). *)

type entry = Ready of float * Response.t | Pending of Response.t option Eio.Promise.t

let table : (string, entry) Hashtbl.t = Hashtbl.create 256
let lock = Mutex.create ()
let hits = Atomic.make 0
let misses = Atomic.make 0
let waits = Atomic.make 0
let max_entries = 4096

let with_lock f =
  Mutex.lock lock;
  Fun.protect ~finally:(fun () -> Mutex.unlock lock) f

let anonymous (kw : Kw.t) : bool =
  match kw with
  | `Assoc l -> (
      match List.assoc_opt "user_pubkey" l with
      | None | Some `Null -> true
      | Some (`String s) -> String.lowercase_ascii s = Handlers.primal_pubkey_hex
      | Some _ -> false)
  | _ -> false

let cacheable (f : Funcall.t) (kw : Kw.t) : bool =
  match f with Funcall.Mega_feed_directive | Funcall.Multi_kind_mega_feed_directive -> anonymous kw | _ -> false

let rec canon (j : Yojson.Safe.t) : Yojson.Safe.t =
  match j with
  | `Assoc l -> `Assoc (List.sort (fun (a, _) (b, _) -> compare a b) (List.map (fun (k, v) -> (k, canon v)) l))
  | `List l -> `List (List.map canon l)
  | v -> v

let key (f : Funcall.t) (kw : Kw.t) : string = Funcall.to_string f ^ " " ^ Yojson.Safe.to_string (canon kw)

let sweep now =
  if Hashtbl.length table > max_entries then
    Hashtbl.filter_map_inplace (fun _ e -> match e with Ready (exp, _) when exp < now -> None | e -> Some e) table

(* A fresh entry exists: the answer costs nothing, so Conn serves it inline without a fiber slot. *)
let fresh (key : string) : bool =
  let now = Unix.gettimeofday () in
  with_lock (fun () -> match Hashtbl.find_opt table key with Some (Ready (exp, _)) -> exp > now | _ -> false)

let stats () = (Atomic.get hits, Atomic.get misses, Atomic.get waits, with_lock (fun () -> Hashtbl.length table))

let lookup ~(ttl : float) ~(key : string) ~(compute : unit -> Response.outcome) : Response.outcome =
  let now = Unix.gettimeofday () in
  let action =
    with_lock (fun () ->
        match Hashtbl.find_opt table key with
        | Some (Ready (exp, r)) when exp > now -> `Hit r
        | Some (Pending p) -> `Wait p
        | _ ->
            let p, u = Eio.Promise.create () in
            Hashtbl.replace table key (Pending p);
            `Compute u)
  in
  match action with
  | `Hit r ->
      Atomic.incr hits;
      Response.Handled r
  | `Wait p -> (
      Atomic.incr waits;
      match Eio.Promise.await p with Some r -> Response.Handled r | None -> compute ())
  | `Compute u ->
      Atomic.incr misses;
      let outcome =
        try compute ()
        with e ->
          with_lock (fun () -> Hashtbl.remove table key);
          Eio.Promise.resolve u None;
          raise e
      in
      (match outcome with
      | Response.Handled r when r.registrations = [] ->
          with_lock (fun () ->
              sweep now;
              Hashtbl.replace table key (Ready (now +. ttl, r)));
          Eio.Promise.resolve u (Some r)
      | _ ->
          with_lock (fun () -> Hashtbl.remove table key);
          Eio.Promise.resolve u None);
      outcome
