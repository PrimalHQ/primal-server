(* What a handler returns. Messages are JSON texts emitted verbatim as
   ["EVENT", subid, msg] (or inside one zlib EVENTS frame); the kernel appends NOTICEs and EOSE. *)

type eaddr = { kind : int; pubkey : string; identifier : string } (* NIP-33 address, raw pubkey *)

type registration =
  | Live_events of { eaddr : eaddr; user_pubkey : string; content_moderation_mode : string }
  | Live_events_from_follows of { user_pubkey : string }
  (* the periodic broadcasters (Julia's cache_server_handlers*.jl) *)
  | Notification_counts of { pubkey : string; v2 : bool } (* every 1 s *)
  | Directmsg_count of { pubkey : string; v2 : bool } (* every 1 s *)
  | Net_stats (* every 1/NETSTATS_RATE s *)
  | Rebroadcasting_status of { pubkey : string } (* every 2 s *)

type t = { messages : string list; registrations : registration list }

let messages msgs = { messages = msgs; registrations = [] }
let empty = { messages = []; registrations = [] }

(* After ws-connector's ReqStatus. [Notice] = answered with a NOTICE (and EOSE); [Not_handled] =
   the caller answers NOTICE "error" (WebSocket) or 500 (HTTP /api); also what a malformed request
   or a handler error turns into, as ws-connector's HandlerResponse::error did. *)
type outcome = Handled of t | Notice of string | Not_handled
