(* The closed set of natively handled funcall names and the exhaustive dispatcher (ocaml-plan.md
   §5.2). Adding a constructor without a handler arm is a compile error. [Proxied] is every other
   name: forwarded to the upstream Julia CacheServer; the constructor disappears with the proxy
   once the whole exposed set is native. *)

type t =
  (* Phase 3a: ws-connector parity *)
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
  (* Phase 3b: the Julia-era catalogue *)
  | User_profile
  | User_profile_followed_by
  | Contact_list
  | Is_user_following
  | Mutelist
  | Mutelists
  | Allowlist
  | Replaceable_event
  | Get_user_relays
  | Get_user_relays_2
  | Creator_paid_tiers
  | Poll_votes
  | Nip19_decode
  | Event_zaps_by_satszapped
  | Long_form_content_feed
  | Get_reads_topics
  | Get_reads_feeds
  | Get_featured_authors
  | Get_home_feeds
  | Get_recommended_blossom_servers
  | Get_default_app_subsettings
  | Get_app_subsettings
  | Set_app_subsettings
  | Get_default_relays
  | Get_media_metadata
  | Note_mentions_count
  | User_profile_scored_content
  | User_search
  | Feed_directive
  | Get_recommended_users
  | Get_suggested_users
  | Membership_media_management_stats
  (* Phase 4a *)
  | Get_notifications
  | Set_notifications_seen
  | Notification_counts
  | Notification_counts_2
  | Directmsg_count
  | Directmsg_count_2
  | Net_stats
  | Rebroadcasting_status
  | Notifications
  (* Phase 4b *)
  | Explore
  | Explore_global_trending_24h
  | Explore_global_mostzapped_4h
  | Scored_users
  | Scored_users_24h
  | Trending_hashtags
  | Trending_hashtags_4h
  | Trending_hashtags_7d
  | Explore_zaps
  | Explore_people
  | Explore_topics
  | Explore_legend_counts
  | Proxied of string

let names : (string * t) list =
  [
    ("thread_view", Thread_view);
    ("multi_kind_thread_view", Multi_kind_thread_view);
    ("scored", Scored);
    ("get_default_app_settings", Get_default_app_settings);
    ("get_app_releases", Get_app_releases);
    ("get_bookmarks", Get_bookmarks);
    ("user_infos", User_infos);
    ("server_name", Server_name);
    ("get_notifications_seen", Get_notifications_seen);
    ("feed", Feed);
    ("mega_feed_directive", Mega_feed_directive);
    ("multi_kind_mega_feed_directive", Multi_kind_mega_feed_directive);
    ("live_feed", Live_feed);
    ("live_events_from_follows", Live_events_from_follows);
    ("find_live_events", Find_live_events);
    ("events", Events);
    ("user_profile", User_profile);
    ("user_profile_followed_by", User_profile_followed_by);
    ("contact_list", Contact_list);
    ("is_user_following", Is_user_following);
    ("mutelist", Mutelist);
    ("mutelists", Mutelists);
    ("allowlist", Allowlist);
    ("replaceable_event", Replaceable_event);
    ("get_user_relays", Get_user_relays);
    ("get_user_relays_2", Get_user_relays_2);
    ("creator_paid_tiers", Creator_paid_tiers);
    ("poll_votes", Poll_votes);
    ("nip19_decode", Nip19_decode);
    ("event_zaps_by_satszapped", Event_zaps_by_satszapped);
    ("long_form_content_feed", Long_form_content_feed);
    ("get_reads_topics", Get_reads_topics);
    ("get_reads_feeds", Get_reads_feeds);
    ("get_featured_authors", Get_featured_authors);
    ("get_home_feeds", Get_home_feeds);
    ("get_recommended_blossom_servers", Get_recommended_blossom_servers);
    ("get_default_app_subsettings", Get_default_app_subsettings);
    ("get_app_subsettings", Get_app_subsettings);
    ("set_app_subsettings", Set_app_subsettings);
    ("get_default_relays", Get_default_relays);
    ("get_media_metadata", Get_media_metadata);
    ("note_mentions_count", Note_mentions_count);
    ("user_profile_scored_content", User_profile_scored_content);
    ("user_search", User_search);
    ("feed_directive", Feed_directive);
    ("get_recommended_users", Get_recommended_users);
    ("get_suggested_users", Get_suggested_users);
    ("membership_media_management_stats", Membership_media_management_stats);
    ("get_notifications", Get_notifications);
    ("set_notifications_seen", Set_notifications_seen);
    ("notification_counts", Notification_counts);
    ("notification_counts_2", Notification_counts_2);
    ("directmsg_count", Directmsg_count);
    ("directmsg_count_2", Directmsg_count_2);
    ("net_stats", Net_stats);
    ("rebroadcasting_status", Rebroadcasting_status);
    ("notifications", Notifications);
    ("explore", Explore);
    ("explore_global_trending_24h", Explore_global_trending_24h);
    ("explore_global_mostzapped_4h", Explore_global_mostzapped_4h);
    ("scored_users", Scored_users);
    ("scored_users_24h", Scored_users_24h);
    ("trending_hashtags", Trending_hashtags);
    ("trending_hashtags_4h", Trending_hashtags_4h);
    ("trending_hashtags_7d", Trending_hashtags_7d);
    ("explore_zaps", Explore_zaps);
    ("explore_people", Explore_people);
    ("explore_topics", Explore_topics);
    ("explore_legend_counts", Explore_legend_counts);
  ]

let of_string (s : string) : t = match List.assoc_opt s names with Some f -> f | None -> Proxied s

let to_string (f : t) : string =
  match f with
  | Proxied s -> s
  | f -> ( match List.find_opt (fun (_, g) -> g = f) names with Some (n, _) -> n | None -> assert false)

let native_names () : string list = List.map fst names

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [dispatch] %s\n%!" (Procinfo.timestamp ()) s) fmt

(* Run one funcall. Handler exceptions (malformed kwargs, DB errors, pool timeouts) become
   [Not_handled], as ws-handlers' error responses did: the upstream answers instead.
   [moderate]: apply Julia's content_moderation_filtering_2 to the answer (the Phase 3b funcalls;
   the 3a ones are those Julia exempts because their SQL functions take the viewer's pubkey). *)
let dispatch (ctx : Handlers.ctx) (f : t) (kw : Kw.t) : Response.outcome =
  let run ?(moderate = true) h =
    try
      match h ctx kw with
      | Response.Handled r when moderate ->
          let user_pubkey = Kw.hex32_opt kw "user_pubkey" in
          let author_exempt = Moderation.author_exempt kw in
          Response.Handled
            { r with messages = Moderation.filter ~clock:ctx.clock ~funcall:(to_string f) ~user_pubkey ~author_exempt r.messages }
      | o -> o
    with
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
  | Thread_view -> run ~moderate:false Handlers.thread_view
  | Multi_kind_thread_view -> run ~moderate:false Handlers.multi_kind_thread_view
  | Scored -> run ~moderate:false Handlers.scored
  | Get_default_app_settings -> run ~moderate:false Handlers.get_default_app_settings
  | Get_app_releases -> run ~moderate:false Handlers.get_app_releases
  | Get_bookmarks -> run ~moderate:false Handlers.get_bookmarks
  | User_infos -> run ~moderate:false Handlers.user_infos
  | Server_name -> run ~moderate:false Handlers.server_name
  | Get_notifications_seen -> run ~moderate:false Handlers.get_notifications_seen
  | Feed -> run ~moderate:false Handlers.feed
  | Mega_feed_directive -> run ~moderate:false Handlers.mega_feed_directive
  | Multi_kind_mega_feed_directive -> run ~moderate:false Handlers.multi_kind_mega_feed_directive
  | Live_feed -> run ~moderate:false Handlers.live_feed
  | Live_events_from_follows -> run ~moderate:false Handlers.live_events_from_follows
  | Find_live_events -> run ~moderate:false Handlers.find_live_events
  | Events -> run ~moderate:false Handlers.events
  | User_profile -> run Handlers.user_profile
  | User_profile_followed_by -> run Handlers.user_profile_followed_by
  | Contact_list -> run Handlers.contact_list
  | Is_user_following -> run Handlers.is_user_following
  | Mutelist -> run Handlers.mutelist
  | Mutelists -> run Handlers.mutelists
  | Allowlist -> run Handlers.allowlist
  | Replaceable_event -> run Handlers.replaceable_event
  | Get_user_relays -> run Handlers.get_user_relays
  | Get_user_relays_2 -> run Handlers.get_user_relays_2
  | Creator_paid_tiers -> run Handlers.creator_paid_tiers
  | Poll_votes -> run Handlers.poll_votes
  | Nip19_decode -> run Handlers.nip19_decode
  | Event_zaps_by_satszapped -> run Handlers.event_zaps_by_satszapped
  | Long_form_content_feed -> run ~moderate:false Handlers.long_form_content_feed_funcall
  | Get_reads_topics -> run Handlers.get_reads_topics
  | Get_reads_feeds -> run Handlers.get_reads_feeds
  | Get_featured_authors -> run Handlers.get_featured_authors
  | Get_home_feeds -> run Handlers.get_home_feeds
  | Get_recommended_blossom_servers -> run Handlers.get_recommended_blossom_servers
  | Get_default_app_subsettings -> run Handlers.get_default_app_subsettings
  | Get_app_subsettings -> run Handlers.get_app_subsettings
  | Set_app_subsettings -> run Handlers.set_app_subsettings
  | Get_default_relays -> run Handlers.get_default_relays
  | Get_media_metadata -> run Handlers.get_media_metadata
  | Note_mentions_count -> run Handlers.note_mentions_count
  | User_profile_scored_content -> run Handlers.user_profile_scored_content
  | User_search -> run Handlers.user_search
  | Feed_directive -> run ~moderate:false Handlers.feed_directive
  | Get_recommended_users -> run Handlers.get_recommended_users
  | Get_suggested_users -> run Handlers.get_suggested_users
  | Membership_media_management_stats -> run Handlers.membership_media_management_stats
  | Get_notifications -> run Handlers.get_notifications
  | Set_notifications_seen -> run ~moderate:false Handlers.set_notifications_seen
  | Notification_counts -> run ~moderate:false Handlers.notification_counts
  | Notification_counts_2 -> run ~moderate:false Handlers.notification_counts_2
  | Directmsg_count -> run ~moderate:false Handlers.directmsg_count
  | Directmsg_count_2 -> run ~moderate:false Handlers.directmsg_count_2
  | Net_stats -> run ~moderate:false Handlers.net_stats
  | Rebroadcasting_status -> run ~moderate:false Handlers.rebroadcasting_status
  | Notifications -> run ~moderate:false Handlers.notifications
  | Explore -> run ~moderate:false Handlers.explore
  | Explore_global_trending_24h -> run Handlers.explore_global_trending_24h
  | Explore_global_mostzapped_4h -> run Handlers.explore_global_mostzapped_4h
  | Scored_users -> run Handlers.scored_users
  | Scored_users_24h -> run Handlers.scored_users_24h
  | Trending_hashtags -> run Handlers.trending_hashtags
  | Trending_hashtags_4h -> run Handlers.trending_hashtags_4h
  | Trending_hashtags_7d -> run Handlers.trending_hashtags_7d
  | Explore_zaps -> run Handlers.explore_zaps
  | Explore_people -> run Handlers.explore_people
  | Explore_topics -> run Handlers.explore_topics
  | Explore_legend_counts -> run Handlers.explore_legend_counts
  | Proxied _ -> Response.Not_handled

(* mega_feed_directive routes spec ids that name exposed functions through the dispatcher *)
let () = Handlers.dispatch_by_name := fun ctx name kw -> match of_string name with Proxied _ -> Response.Not_handled | f -> dispatch ctx f kw
