(* Notification types, mirroring Julia src/notifications.jl (the @enum NotificationType and the
   notification_args table).

   A notification's type is stored as its integer code in pubkey_notifications.type and selects a
   per-type counter column (typeN) in pubkey_notification_cnts. The argument arity per type
   ([arg_count]) reproduces Julia's notification_args lengths and is asserted when a notification
   is built (Cache_storage_ext.notification). *)

(* {1 NotificationType codes} (src/notifications.jl:3-32) *)

let new_user_followed_you = 1
let user_unfollowed_you = 2

let your_post_was_zapped = 3
let your_post_was_liked = 4
let your_post_was_reposted = 5
let your_post_was_replied_to = 6
let you_were_mentioned_in_post = 7
let your_post_was_mentioned_in_post = 8

let post_you_were_mentioned_in_was_zapped = 101
let post_you_were_mentioned_in_was_liked = 102
let post_you_were_mentioned_in_was_reposted = 103
let post_you_were_mentioned_in_was_replied_to = 104

let post_your_post_was_mentioned_in_was_zapped = 201
let post_your_post_was_mentioned_in_was_liked = 202
let post_your_post_was_mentioned_in_was_reposted = 203
let post_your_post_was_mentioned_in_was_replied_to = 204

let your_post_was_highlighted = 301
let your_post_was_bookmarked = 302

let new_direct_message = 401

let live_event_happening = 501

let reply_to_reply = 601

(* {1 Per-type argument arity} (src/notifications.jl:44-73 notification_args lengths) *)

let arg_count = function
  | 1 | 2 -> 1 (* NEW_USER_FOLLOWED_YOU / USER_UNFOLLOWED_YOU: (follower) *)
  | 3 -> 4 (* YOUR_POST_WAS_ZAPPED: (your_post, who_zapped, satszapped, message) *)
  | 4 -> 3 (* YOUR_POST_WAS_LIKED: (your_post, who_liked, reaction) *)
  | 5 -> 2 (* YOUR_POST_WAS_REPOSTED: (your_post, who_reposted) *)
  | 6 -> 3 (* YOUR_POST_WAS_REPLIED_TO: (your_post, who_replied, reply) *)
  | 7 -> 2 (* YOU_WERE_MENTIONED_IN_POST: (you_were_mentioned_in, by) *)
  | 8 -> 3 (* YOUR_POST_WAS_MENTIONED_IN_POST: (your_post, mentioned_in, by) *)
  | 101 -> 3 (* POST_YOU_WERE_MENTIONED_IN_WAS_ZAPPED *)
  | 102 | 103 -> 2 (* ..._WAS_LIKED / ..._WAS_REPOSTED *)
  | 104 -> 3 (* ..._WAS_REPLIED_TO *)
  | 201 -> 4 (* POST_YOUR_POST_WAS_MENTIONED_IN_WAS_ZAPPED *)
  | 202 | 203 -> 3 (* ..._WAS_LIKED / ..._WAS_REPOSTED *)
  | 204 -> 4 (* ..._WAS_REPLIED_TO *)
  | 301 -> 3 (* YOUR_POST_WAS_HIGHLIGHTED: (your_post, who, highlight) *)
  | 302 -> 2 (* YOUR_POST_WAS_BOOKMARKED: (your_post, who) *)
  | 401 -> 2 (* NEW_DIRECT_MESSAGE: (event_id, sender) *)
  | 501 -> 3 (* LIVE_EVENT_HAPPENING: (live_event_id, host, coordinate) *)
  | 601 -> 3 (* REPLY_TO_REPLY: (your_post, who_replied, reply) *)
  | _ -> 0

(* Julia stores string(notif_type) (the enum symbol) in notification_settings.type. We keep the
   mapping for completeness even though that gate is a serving-layer no-op here. *)
let name = function
  | 1 -> "NEW_USER_FOLLOWED_YOU"
  | 2 -> "USER_UNFOLLOWED_YOU"
  | 3 -> "YOUR_POST_WAS_ZAPPED"
  | 4 -> "YOUR_POST_WAS_LIKED"
  | 5 -> "YOUR_POST_WAS_REPOSTED"
  | 6 -> "YOUR_POST_WAS_REPLIED_TO"
  | 7 -> "YOU_WERE_MENTIONED_IN_POST"
  | 8 -> "YOUR_POST_WAS_MENTIONED_IN_POST"
  | 101 -> "POST_YOU_WERE_MENTIONED_IN_WAS_ZAPPED"
  | 102 -> "POST_YOU_WERE_MENTIONED_IN_WAS_LIKED"
  | 103 -> "POST_YOU_WERE_MENTIONED_IN_WAS_REPOSTED"
  | 104 -> "POST_YOU_WERE_MENTIONED_IN_WAS_REPLIED_TO"
  | 201 -> "POST_YOUR_POST_WAS_MENTIONED_IN_WAS_ZAPPED"
  | 202 -> "POST_YOUR_POST_WAS_MENTIONED_IN_WAS_LIKED"
  | 203 -> "POST_YOUR_POST_WAS_MENTIONED_IN_WAS_REPOSTED"
  | 204 -> "POST_YOUR_POST_WAS_MENTIONED_IN_WAS_REPLIED_TO"
  | 301 -> "YOUR_POST_WAS_HIGHLIGHTED"
  | 302 -> "YOUR_POST_WAS_BOOKMARKED"
  | 401 -> "NEW_DIRECT_MESSAGE"
  | 501 -> "LIVE_EVENT_HAPPENING"
  | 601 -> "REPLY_TO_REPLY"
  | n -> string_of_int n
