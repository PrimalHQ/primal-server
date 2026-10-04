(* What start_fetcher.jl wired behind Fetching.message_processors, in their SortedDict order:
   1. :deduped_storage — DB.import_msg_into_storage into the DeduplicatedEventStorage: an EVENT
      whose id was seen before is skipped (seenearly); otherwise the event is parsed and verified
      (created_at < now + 300, id and signature), appended to messages/YYYY/MM/DD.log, remembered,
      and handed to the storage's own :firehose_server processor (broadcast once);
   2. :firehose_server — the raw message broadcast to the firehose, whatever it is.
   So a new verified event reaches the firehose twice and every other line once, exactly as the
   Julia fetcher did; firehose_forward_raw=false drops step 2. One fiber on its own domain. *)

open Eio.Std

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [processor] %s\n%!" (Procinfo.timestamp ()) s) fmt

let process ~(cfg : Config.t) ~(stats : Stats.t) ~(dedup : Dedup.t) ~(archive : Archive.t option) ~(firehose : Firehose.t) (it : Relay_conn.item) : unit =
  (match it.ev with
  | Some ev -> (
      let id = match ev with `Assoc f -> ( match List.assoc_opt "id" f with Some (`String s) -> Some s | _ -> None) | _ -> None in
      match id with
      | Some id when Dedup.mem dedup id -> Stats.incr stats.seenearly
      | _ -> (
          Stats.incr stats.seen;
          match Nostr.of_json ev with
          | exception _ -> Stats.incr stats.parseerr
          | e ->
              let now = Utils.current_time () in
              if e.Nostr.created_at >= now + 300 then ()
              else if not (Nostr.verify e) then Stats.incr stats.verifyerr
              else begin
                Stats.incr stats.any;
                (match archive with
                | Some a -> ( try Archive.append a ~created_at:e.created_at it.line with exn -> Stats.incr stats.archive_errors; log "archive: %s" (Printexc.to_string exn))
                | None -> ());
                ignore (Dedup.check_and_add dedup (Hex_util.encode e.id) ~now);
                Firehose.broadcast firehose it.line
              end))
  | None -> ());
  if cfg.firehose_forward_raw then Firehose.broadcast firehose it.line

let run ~(cfg : Config.t) ~(stats : Stats.t) ~(dedup : Dedup.t) ~(archive : Archive.t option) ~(firehose : Firehose.t) ~(q : Relay_conn.item Eio.Stream.t) ~(stop : unit Promise.t) : unit =
  Phases.register_domain_slot "processor";
  let rec loop () =
    match Fiber.first (fun () -> Some (Eio.Stream.take q)) (fun () -> Promise.await stop; None) with
    | Some it ->
        (try process ~cfg ~stats ~dedup ~archive ~firehose it with Eio.Cancel.Cancelled _ as e -> raise e | exn -> log "%s" (Printexc.to_string exn));
        loop ()
    | None -> ()
  in
  loop ();
  (* drain what is queued so the archive keeps everything fetched before the stop *)
  let rec drain () = match Eio.Stream.take_nonblocking q with Some it -> (try process ~cfg ~stats ~dedup ~archive ~firehose it with _ -> ()); drain () | None -> () in
  drain ()
