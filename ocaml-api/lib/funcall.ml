(* The closed set of natively handled funcall names and the exhaustive dispatcher (ocaml-plan.md
   §5.2). Adding a constructor without a handler arm is a compile error. [Proxied] is every other
   name: forwarded to the upstream Julia CacheServer; the constructor disappears with the proxy
   once the whole exposed set is native. *)

type t =
  | Thread_view
  | Multi_kind_thread_view
  | Scored
  | Get_default_app_settings
  | Get_app_releases
  | Get_bookmarks
  | User_infos
  | Server_name
  | Get_notifications_seen
  | Feed
  | Mega_feed_directive
  | Multi_kind_mega_feed_directive
  | Live_feed
  | Live_events_from_follows
  | Find_live_events
  | Events
  | Proxied of string

let of_string = function
  | "thread_view" -> Thread_view
  | "multi_kind_thread_view" -> Multi_kind_thread_view
  | "scored" -> Scored
  | "get_default_app_settings" -> Get_default_app_settings
  | "get_app_releases" -> Get_app_releases
  | "get_bookmarks" -> Get_bookmarks
  | "user_infos" -> User_infos
  | "server_name" -> Server_name
  | "get_notifications_seen" -> Get_notifications_seen
  | "feed" -> Feed
  | "mega_feed_directive" -> Mega_feed_directive
  | "multi_kind_mega_feed_directive" -> Multi_kind_mega_feed_directive
  | "live_feed" -> Live_feed
  | "live_events_from_follows" -> Live_events_from_follows
  | "find_live_events" -> Find_live_events
  | "events" -> Events
  | s -> Proxied s

let to_string = function
  | Thread_view -> "thread_view"
  | Multi_kind_thread_view -> "multi_kind_thread_view"
  | Scored -> "scored"
  | Get_default_app_settings -> "get_default_app_settings"
  | Get_app_releases -> "get_app_releases"
  | Get_bookmarks -> "get_bookmarks"
  | User_infos -> "user_infos"
  | Server_name -> "server_name"
  | Get_notifications_seen -> "get_notifications_seen"
  | Feed -> "feed"
  | Mega_feed_directive -> "mega_feed_directive"
  | Multi_kind_mega_feed_directive -> "multi_kind_mega_feed_directive"
  | Live_feed -> "live_feed"
  | Live_events_from_follows -> "live_events_from_follows"
  | Find_live_events -> "find_live_events"
  | Events -> "events"
  | Proxied s -> s

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [dispatch] %s\n%!" (Procinfo.timestamp ()) s) fmt

(* Run one funcall. Handler exceptions (malformed kwargs, DB errors, pool timeouts) become
   [Not_handled], as ws-handlers' error responses did: the upstream answers instead. *)
let dispatch (ctx : Handlers.ctx) (f : t) (kw : Kw.t) : Response.outcome =
  let run h =
    try h ctx kw with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | Kw.Invalid msg ->
        log "%s sub_id=%s: %s (not handled)" (to_string f) ctx.subid msg;
        Response.Not_handled
    | Invalid_argument _ | Not_found ->
        log "%s sub_id=%s: invalid argument (not handled)" (to_string f) ctx.subid;
        Response.Not_handled
    | Db.Pool_timeout ->
        log "%s sub_id=%s: database pool timeout (not handled)" (to_string f) ctx.subid;
        Response.Not_handled
    | exn ->
        log "%s sub_id=%s: %s (not handled)" (to_string f) ctx.subid (Printexc.to_string exn);
        Response.Not_handled
  in
  match f with
  | Thread_view -> run Handlers.thread_view
  | Multi_kind_thread_view -> run Handlers.multi_kind_thread_view
  | Scored -> run Handlers.scored
  | Get_default_app_settings -> run Handlers.get_default_app_settings
  | Get_app_releases -> run Handlers.get_app_releases
  | Get_bookmarks -> run Handlers.get_bookmarks
  | User_infos -> run Handlers.user_infos
  | Server_name -> run Handlers.server_name
  | Get_notifications_seen -> run Handlers.get_notifications_seen
  | Feed -> run Handlers.feed
  | Mega_feed_directive -> run Handlers.mega_feed_directive
  | Multi_kind_mega_feed_directive -> run Handlers.multi_kind_mega_feed_directive
  | Live_feed -> run Handlers.live_feed
  | Live_events_from_follows -> run Handlers.live_events_from_follows
  | Find_live_events -> run Handlers.find_live_events
  | Events -> run Handlers.events
  | Proxied _ -> Response.Not_handled
