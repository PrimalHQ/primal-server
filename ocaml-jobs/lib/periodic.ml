(* The job loop every Julia module ran: run, sleep [period], repeat, until [stop]; an exception is
   logged and the loop continues (ocaml-plan.md §4.6). *)

open Eio.Std

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [jobs] %s\n%!" (Procinfo.timestamp ()) s) fmt

let run ~clock ~(stop : unit Promise.t) ~(period : float) ~(label : string) (f : unit -> unit) : unit =
  let rec loop () =
    if not (Promise.is_resolved stop) then begin
      Phases.phase (label ^ ":run");
      let t0 = Unix.gettimeofday () in
      (try f () with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn -> log "%s: %s" label (Printexc.to_string exn));
      log "%s: run took %.1fs" label (Unix.gettimeofday () -. t0);
      Phases.phase (label ^ ":sleep");
      match Fiber.first (fun () -> Promise.await stop; `Stop) (fun () -> Eio.Time.sleep clock period; `Tick) with `Stop -> () | `Tick -> loop ()
    end
  in
  loop ()
