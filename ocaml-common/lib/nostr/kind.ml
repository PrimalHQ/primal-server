(* Primal's synthetic event kinds (ocaml-plan.md §4.3): the one table for app.jl:134-198,
   app_ext.jl:71-98, app_media.jl:16-17 and the sql/app.sql c_* constants. Three numbers are used
   twice by the Julia code and clients depend on both meanings; they are kept and marked. *)

(* app.jl *)
let event_stats = 10000100
let net_stats = 10000101
let user_profile = 10000105
let referenced_event = 10000107
let range = 10000113
let event_actions_count = 10000115
let directmsg_count = 10000117
let directmsg_counts = 10000118
let event_ids = 10000122
let partial_response = 10000123
let is_user_following = 10000125
let event_import_status = 10000127
let zap_event = 10000129
let filtering_reason = 10000131
let user_follower_counts = 10000133
let directmsg_count_2 = 10000134 (* collides with suggested_users *)
let nostr_stats = 10000136
let is_hidden_by_content_moderation = 10000137
let user_pubkey = 10000138 (* collides with app_releases *)
let user_relays = 10000139
let event_relays = 10000141
let long_form_metadata = 10000144
let recommended_reads = 10000145
let reads_topics = 10000146
let creator_paid_tiers = 10000147
let featured_authors = 10000148
let highlight_groups = 10000151
let reads_feeds = 10000152
let home_feeds = 10000153
let dvm_feed_follows_actions = 10000156
let user_follower_count_increases = 10000157
let user_primal_names = 10000158
let dvm_feed_metadata = 10000159
let show_primal_support = 10000162
let membership_media_management_stats = 10000163
let membership_media_management_uploads = 10000164
let membership_recovery_contact_lists = 10000165
let membership_content_stats = 10000166
let membership_content_rebroadcast_status = 10000167
let membership_legend_customization = 10000168
let membership_cohorts = 10000169
let membership_legend_leaderboard = 10000170
let membership_premium_leaderboard = 10000171
let user_trustranks = 10000172
let nip19_decode_result = 10000173
let articles_stats = 10000174
let recommended_blossom_servers = 10000175
let invoices_to_zap_receipts = 10000177
let media_hls_urls = 10000178
let poll_stats = 10000179
let parsed_search_query = 10000180

(* app_ext.jl *)
let explore_legend_counts = 10000102
let primal_settings = 10000103
let app_settings = 30078
let user_scores = 10000108
let relays = 10000109
let notification = 10000110
let notifications_seen_until = 10000111
let notifications_summary = 10000112
let media_mapping = 10000114
let hashtags = 10000116
let media_metadata = 10000119
let default_relays = 10000124
let filterlist = 10000126
let link_metadata = 10000128
let filterlisted = 10000130
let notifications_summary_2 = 10000132
let suggested_users = 10000134 (* collides with directmsg_count_2 *)
let upload_chunk = 10000135
let app_releases = 10000138 (* collides with user_pubkey *)
let trusted_users = 10000140
let uploaded_2 = 10000142
let note_mentions_count = 10000143
let event_broadcast_responses = 10000149
let advanced_feeds = 10000150
let app_subsettings = 10000155
let hashtags_2 = 10000160
let media_metadata_by_hash = 10000176 (* collides with live_event_stats (SQL) *)
let recommended_users = 10000200

(* app_media.jl *)
let upload = 10000120
let uploaded = 10000121

(* sql/app.sql only *)
let collection_order = 10000161
let live_event_stats = 10000176 (* collides with media_metadata_by_hash *)

(* Live-event moderation poke sent on primal_events (cache_storage.jl send_event_to_ws_connector). *)
let live_event_moderation_changed = 11_000_001
