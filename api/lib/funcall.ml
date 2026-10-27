(* The closed set of funcall names and the exhaustive dispatcher. Adding a constructor without a
   handler arm is a compile error. [Other] is every other name: a private extension's funcall
   (Extensions) or an unknown one, answered NOTICE "unknown api request". *)

type t =
  (* the funcalls ws-connector's Rust handlers answered *)
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
  (* profiles, lists, reads, app settings (app.jl / app_ext.jl) *)
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
  (* notifications and the push subscriptions *)
  | Get_notifications
  | Set_notifications_seen
  | Notification_counts
  | Notification_counts_2
  | Directmsg_count
  | Directmsg_count_2
  | Net_stats
  | Rebroadcasting_status
  | Notifications
  (* explore / trending *)
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
  (* the long tail *)
  | Get_directmsgs
  | Get_directmsg_contacts
  | Reset_directmsg_count
  | Reset_directmsg_counts
  | Zaps_feed
  | User_zaps
  | User_zaps_by_satszapped
  | User_zaps_sent
  | Event_actions
  | User_followers
  | Mutual_follows
  | Find_reposts
  | Follow_list
  | Follow_lists
  | Parameterized_replaceable_list
  | Parametrized_replaceable_event
  | Parametrized_replaceable_events
  | Check_filterlist
  | Is_hidden_by_content_moderation
  | Get_app_settings
  | Get_app_settings_2
  | User_of_ln_address
  | Set_last_time_user_was_online
  | Report_user
  | Report_note
  | Trusted_users
  | Client_config
  | Network_stats
  | Articles_stats
  | Drafts
  | Top_article
  | Long_form_content_thread_view
  | User_profile_scored_media_thumbnails
  | Get_highlights
  | Get_suggested_users_2
  | Feed_2
  | Feed_directive_2
  | Enrich_feed_events
  | Note_mentions
  (* advanced search *)
  | Advanced_search
  | Advanced_feed
  | Parse_advanced_search_query
  (* the remaining readers *)
  | Search
  | Explore_media
  | Get_advanced_feeds
  | Nostr_stats
  | Get_filterlist
  | Get_recommended_reads
  | Trending_images
  | Trending_images_4h
  | Get_dvm_feeds
  | Get_featured_dvm_feeds
  | Dvm_feed_info
  (* settings and the remaining writes *)
  | Set_app_settings
  | Search_filterlist
  | Update_push_notification_token
  | Update_push_notification_token_for_nip46
  | Get_queued_events_for_nip46
  | Events_nip46
  | Invoices_to_zap_receipts
  | Import_events
  | Import_poll_vote_event
  (* relay-facing funcalls *)
  | Broadcast_events
  | Broadcast_reply
  | Dvm_feed
  (* the membership content funcalls *)
  | Membership_content_stats
  | Membership_recovery_contact_lists
  | Membership_recover_contact_list
  | Membership_content_backup
  | Membership_content_rebroadcast_status
  | Membership_content_rebroadcast_cancel
  | Membership_content_rebroadcast_start
  | Membership_legends_leaderboard
  | Membership_premium_leaderboard
  | Membership_media_management_uploads
  | Membership_media_management_delete
  | Other of string

let names : (string * t) list =
  [
    ("thread_view", Thread_view);
    ("membership_content_stats", Membership_content_stats);
    ("membership_recovery_contact_lists", Membership_recovery_contact_lists);
    ("membership_recover_contact_list", Membership_recover_contact_list);
    ("membership_content_backup", Membership_content_backup);
    ("membership_content_rebroadcast_status", Membership_content_rebroadcast_status);
    ("membership_content_rebroadcast_cancel", Membership_content_rebroadcast_cancel);
    ("membership_content_rebroadcast_start", Membership_content_rebroadcast_start);
    ("membership_legends_leaderboard", Membership_legends_leaderboard);
    ("membership_premium_leaderboard", Membership_premium_leaderboard);
    ("membership_media_management_uploads", Membership_media_management_uploads);
    ("membership_media_management_delete", Membership_media_management_delete);
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
    ("get_directmsgs", Get_directmsgs);
    ("get_directmsg_contacts", Get_directmsg_contacts);
    ("reset_directmsg_count", Reset_directmsg_count);
    ("reset_directmsg_counts", Reset_directmsg_counts);
    ("zaps_feed", Zaps_feed);
    ("user_zaps", User_zaps);
    ("user_zaps_by_satszapped", User_zaps_by_satszapped);
    ("user_zaps_sent", User_zaps_sent);
    ("event_actions", Event_actions);
    ("user_followers", User_followers);
    ("mutual_follows", Mutual_follows);
    ("find_reposts", Find_reposts);
    ("follow_list", Follow_list);
    ("follow_lists", Follow_lists);
    ("parameterized_replaceable_list", Parameterized_replaceable_list);
    ("parametrized_replaceable_event", Parametrized_replaceable_event);
    ("parametrized_replaceable_events", Parametrized_replaceable_events);
    ("check_filterlist", Check_filterlist);
    ("is_hidden_by_content_moderation", Is_hidden_by_content_moderation);
    ("get_app_settings", Get_app_settings);
    ("get_app_settings_2", Get_app_settings_2);
    ("user_of_ln_address", User_of_ln_address);
    ("set_last_time_user_was_online", Set_last_time_user_was_online);
    ("report_user", Report_user);
    ("report_note", Report_note);
    ("trusted_users", Trusted_users);
    ("client_config", Client_config);
    ("network_stats", Network_stats);
    ("articles_stats", Articles_stats);
    ("drafts", Drafts);
    ("top_article", Top_article);
    ("long_form_content_thread_view", Long_form_content_thread_view);
    ("user_profile_scored_media_thumbnails", User_profile_scored_media_thumbnails);
    ("get_highlights", Get_highlights);
    ("get_suggested_users_2", Get_suggested_users_2);
    ("feed_2", Feed_2);
    ("feed_directive_2", Feed_directive_2);
    ("enrich_feed_events", Enrich_feed_events);
    ("note_mentions", Note_mentions);
    ("advanced_search", Advanced_search);
    ("advanced_feed", Advanced_feed);
    ("parse_advanced_search_query", Parse_advanced_search_query);
    ("search", Search);
    ("explore_media", Explore_media);
    ("get_advanced_feeds", Get_advanced_feeds);
    ("nostr_stats", Nostr_stats);
    ("get_filterlist", Get_filterlist);
    ("get_recommended_reads", Get_recommended_reads);
    ("trending_images", Trending_images);
    ("trending_images_4h", Trending_images_4h);
    ("get_dvm_feeds", Get_dvm_feeds);
    ("get_featured_dvm_feeds", Get_featured_dvm_feeds);
    ("dvm_feed_info", Dvm_feed_info);
    ("set_app_settings", Set_app_settings);
    ("search_filterlist", Search_filterlist);
    ("update_push_notification_token", Update_push_notification_token);
    ("update_push_notification_token_for_nip46", Update_push_notification_token_for_nip46);
    ("get_queued_events_for_nip46", Get_queued_events_for_nip46);
    ("events_nip46", Events_nip46);
    ("invoices_to_zap_receipts", Invoices_to_zap_receipts);
    ("import_events", Import_events);
    ("import_poll_vote_event", Import_poll_vote_event);
    ("broadcast_events", Broadcast_events);
    ("broadcast_reply", Broadcast_reply);
    ("dvm_feed", Dvm_feed);
  ]

let of_string (s : string) : t = match List.assoc_opt s names with Some f -> f | None -> Other s

let to_string (f : t) : string =
  match f with
  | Other s -> s
  | f -> ( match List.find_opt (fun (_, g) -> g = f) names with Some (n, _) -> n | None -> assert false)

let native_names () : string list = List.map fst names @ Extensions.funcall_names ()

let log fmt = Printf.ksprintf (fun s -> Printf.printf "%s [dispatch] %s\n%!" (Procinfo.timestamp ()) s) fmt

(* Run one funcall. Handler exceptions (malformed kwargs, DB errors, pool timeouts) become
   [Not_handled] (as ws-handlers' error responses did), which the caller answers with NOTICE "error".
   [moderate]: apply Julia's content_moderation_filtering_2 to the answer (Moderation.filter);
   ~moderate:false for the funcalls Julia exempted because their SQL functions take the viewer's
   pubkey, and for writes. *)
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
    | Handlers.Julia_err -> Response.Notice "error"
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
  | Membership_content_stats -> run ~moderate:false Handlers.membership_content_stats
  | Membership_recovery_contact_lists -> run ~moderate:false Handlers.membership_recovery_contact_lists
  | Membership_recover_contact_list -> run ~moderate:false Handlers.membership_recover_contact_list
  | Membership_content_backup -> run ~moderate:false Handlers.membership_content_backup
  | Membership_content_rebroadcast_status -> run ~moderate:false Handlers.membership_content_rebroadcast_status
  | Membership_content_rebroadcast_cancel -> run ~moderate:false Handlers.membership_content_rebroadcast_cancel
  | Membership_content_rebroadcast_start -> run ~moderate:false Handlers.membership_content_rebroadcast_start
  | Membership_legends_leaderboard -> run ~moderate:false Handlers.membership_legends_leaderboard
  | Membership_premium_leaderboard -> run ~moderate:false Handlers.membership_premium_leaderboard
  | Membership_media_management_uploads -> run ~moderate:false Handlers.membership_media_management_uploads
  | Membership_media_management_delete -> run ~moderate:false Handlers.membership_media_management_delete
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
  | Get_directmsgs -> run Handlers.get_directmsgs
  | Get_directmsg_contacts -> run Handlers.get_directmsg_contacts
  | Reset_directmsg_count -> run ~moderate:false Handlers.reset_directmsg_count
  | Reset_directmsg_counts -> run ~moderate:false Handlers.reset_directmsg_counts
  | Zaps_feed -> run Handlers.zaps_feed
  | User_zaps -> run Handlers.user_zaps
  | User_zaps_by_satszapped -> run Handlers.user_zaps_by_satszapped
  | User_zaps_sent -> run Handlers.user_zaps_sent
  | Event_actions -> run Handlers.event_actions
  | User_followers -> run Handlers.user_followers
  | Mutual_follows -> run Handlers.mutual_follows
  | Find_reposts -> run Handlers.find_reposts
  | Follow_list -> run Handlers.follow_list
  | Follow_lists -> run Handlers.follow_lists
  | Parameterized_replaceable_list -> run Handlers.parameterized_replaceable_list
  | Parametrized_replaceable_event -> run Handlers.parametrized_replaceable_event
  | Parametrized_replaceable_events -> run Handlers.parametrized_replaceable_events
  | Check_filterlist -> run ~moderate:false Handlers.check_filterlist
  | Is_hidden_by_content_moderation -> run ~moderate:false Handlers.is_hidden_by_content_moderation
  | Get_app_settings -> run ~moderate:false Handlers.get_app_settings
  | Get_app_settings_2 -> run ~moderate:false Handlers.get_app_settings_2
  | User_of_ln_address -> run Handlers.user_of_ln_address
  | Set_last_time_user_was_online -> run ~moderate:false Handlers.set_last_time_user_was_online
  | Report_user -> run ~moderate:false Handlers.report_user
  | Report_note -> run ~moderate:false Handlers.report_note
  | Trusted_users -> run Handlers.trusted_users
  | Client_config -> run ~moderate:false Handlers.client_config
  | Network_stats -> run ~moderate:false Handlers.network_stats
  | Articles_stats -> run ~moderate:false Handlers.articles_stats
  | Drafts -> run Handlers.drafts
  | Top_article -> run Handlers.top_article
  | Long_form_content_thread_view -> run ~moderate:false Handlers.long_form_content_thread_view
  | User_profile_scored_media_thumbnails -> run Handlers.user_profile_scored_media_thumbnails
  | Get_highlights -> run Handlers.get_highlights
  | Get_suggested_users_2 -> run Handlers.get_suggested_users_2
  | Feed_2 -> run ~moderate:false Handlers.feed_2
  | Feed_directive_2 -> run ~moderate:false Handlers.feed_directive_2
  | Enrich_feed_events -> run Handlers.enrich_feed_events
  | Note_mentions -> run Handlers.note_mentions
  | Advanced_search -> run Handlers.advanced_search
  | Advanced_feed -> run Handlers.advanced_feed
  | Parse_advanced_search_query -> run Handlers.parse_advanced_search_query
  | Search -> run Handlers.search
  | Explore_media -> run Handlers.explore_media
  | Get_advanced_feeds -> run Handlers.get_advanced_feeds
  | Nostr_stats -> run Handlers.nostr_stats
  | Get_filterlist -> run Handlers.get_filterlist
  | Get_recommended_reads -> run Handlers.get_recommended_reads
  | Trending_images -> run Handlers.trending_images
  | Trending_images_4h -> run Handlers.trending_images_4h
  | Get_dvm_feeds -> run Handlers.get_dvm_feeds
  | Get_featured_dvm_feeds -> run Handlers.get_featured_dvm_feeds
  | Dvm_feed_info -> run Handlers.dvm_feed_info
  | Set_app_settings -> run Handlers.set_app_settings
  | Search_filterlist -> run Handlers.search_filterlist
  | Update_push_notification_token -> run Handlers.update_push_notification_token
  | Update_push_notification_token_for_nip46 -> run Handlers.update_push_notification_token_for_nip46
  | Get_queued_events_for_nip46 -> run Handlers.get_queued_events_for_nip46
  | Events_nip46 -> run Handlers.events_nip46
  | Invoices_to_zap_receipts -> run Handlers.invoices_to_zap_receipts
  | Import_events -> run Handlers.import_events
  | Import_poll_vote_event -> run Handlers.import_poll_vote_event
  | Broadcast_events -> run Handlers.broadcast_events
  | Broadcast_reply -> run Handlers.broadcast_reply
  | Dvm_feed -> run Handlers.dvm_feed
  | Other s -> ( match Extensions.find_funcall s with Some e -> run ~moderate:e.moderate e.handler | None -> Response.Not_handled)

(* mega_feed_directive routes spec ids that name exposed functions through the dispatcher *)
let () = Handlers.dispatch_by_name := fun ctx name kw -> match of_string name with Other s when not (Extensions.has_funcall s) -> Response.Not_handled | f -> dispatch ctx f kw
