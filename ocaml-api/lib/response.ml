(* What a native handler returns (ocaml-plan.md §5.2). Messages are JSON texts emitted verbatim as
   ["EVENT", subid, msg] (or inside one zlib EVENTS frame); the kernel appends NOTICEs and EOSE. *)

type eaddr = { kind : int; pubkey : string; identifier : string } (* NIP-33 address, raw pubkey *)

type registration =
  | Live_events of { eaddr : eaddr; user_pubkey : string; content_moderation_mode : string }
  | Live_events_from_follows of { user_pubkey : string }

type t = { messages : string list; registrations : registration list }

let messages msgs = { messages = msgs; registrations = [] }
let empty = { messages = []; registrations = [] }

(* ws-connector ReqStatus. [Notice] = answered with a NOTICE (and EOSE); [Not_handled] = forwarded
   to the upstream (also what a malformed request or a handler error turns into, as ws-connector's
   HandlerResponse::error did). *)
type outcome = Handled of t | Notice of string | Not_handled
