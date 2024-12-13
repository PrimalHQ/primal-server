

SELECT pg_catalog.set_config('search_path', '', false);

DROP TRIGGER update_cache_updated_at ON public.cache;
DROP INDEX public.zap_receipts_1_9fe40119b2_target_eid_idx;
DROP INDEX public.zap_receipts_1_9fe40119b2_sender_idx;
DROP INDEX public.zap_receipts_1_9fe40119b2_receiver_idx;
DROP INDEX public.zap_receipts_1_9fe40119b2_imported_at_idx;
DROP INDEX public.wsconnlog_t_idx;
DROP INDEX public.video_thumbnails_1_107d5a46eb_video_url_idx;
DROP INDEX public.video_thumbnails_1_107d5a46eb_thumbnail_url_idx;
DROP INDEX public.video_thumbnails_1_107d5a46eb_rowid_idx;
DROP INDEX public.verified_users_pubkey;
DROP INDEX public.verified_users_name;
DROP INDEX public.user_search_username_idx;
DROP INDEX public.user_search_nip05_idx;
DROP INDEX public.user_search_name_idx;
DROP INDEX public.user_search_lud16_idx;
DROP INDEX public.user_search_displayname_idx;
DROP INDEX public.user_search_display_name_idx;
DROP INDEX public.stuff_created_at;
DROP INDEX public.score_expiry_expire_at_idx;
DROP INDEX public.score_expiry_event_id_idx;
DROP INDEX public.scheduled_hooks_execute_at_idx;
DROP INDEX public.relays_times_referenced_idx;
DROP INDEX public.relay_list_metadata_1_801a17fc93_rowid_idx;
DROP INDEX public.relay_list_metadata_1_801a17fc93_pubkey_idx;
DROP INDEX public.reads_versions_12_b537d4df66_pubkey_idx;
DROP INDEX public.reads_versions_12_b537d4df66_identifier_idx;
DROP INDEX public.reads_versions_12_b537d4df66_eid_idx;
DROP INDEX public.reads_versions_11_fb53a8e0b4_pubkey_idx;
DROP INDEX public.reads_versions_11_fb53a8e0b4_identifier_idx;
DROP INDEX public.reads_versions_11_fb53a8e0b4_eid_idx;
DROP INDEX public.reads_12_68c6bbfccd_topics_idx;
DROP INDEX public.reads_12_68c6bbfccd_published_at_idx;
DROP INDEX public.reads_12_68c6bbfccd_pubkey_idx;
DROP INDEX public.reads_12_68c6bbfccd_identifier_idx;
DROP INDEX public.reads_11_2a4d2ce519_topics_idx;
DROP INDEX public.reads_11_2a4d2ce519_published_at_idx;
DROP INDEX public.reads_11_2a4d2ce519_pubkey_idx;
DROP INDEX public.reads_11_2a4d2ce519_identifier_idx;
DROP INDEX public.pubkey_zapped_1_17f1f622a9_zaps_idx;
DROP INDEX public.pubkey_zapped_1_17f1f622a9_satszapped_idx;
DROP INDEX public.pubkey_zapped_1_17f1f622a9_rowid_idx;
DROP INDEX public.pubkey_zapped_1_17f1f622a9_pubkey_idx;
DROP INDEX public.pubkey_notifications_1_e5459ab9dd_type_idx;
DROP INDEX public.pubkey_notifications_1_e5459ab9dd_rowid_idx;
DROP INDEX public.pubkey_notifications_1_e5459ab9dd_pubkey_idx;
DROP INDEX public.pubkey_notifications_1_e5459ab9dd_pubkey_created_at_type_idx;
DROP INDEX public.pubkey_notifications_1_e5459ab9dd_pubkey_created_at_idx;
DROP INDEX public.pubkey_notifications_1_e5459ab9dd_pubkey_arg2_idx_;
DROP INDEX public.pubkey_notifications_1_e5459ab9dd_pubkey_arg1_idx_;
DROP INDEX public.pubkey_notifications_1_e5459ab9dd_created_at_idx;
DROP INDEX public.pubkey_notifications_1_e5459ab9dd_arg2_idx;
DROP INDEX public.pubkey_notifications_1_e5459ab9dd_arg1_idx;
DROP INDEX public.pubkey_notification_cnts_1_d78f6fcade_rowid_idx;
DROP INDEX public.pubkey_notification_cnts_1_d78f6fcade_pubkey_idx;
DROP INDEX public.pubkey_media_cnt_1_b5e2a488b1_pubkey_idx;
DROP INDEX public.pubkey_ln_address_1_d3649b2898_rowid_idx;
DROP INDEX public.pubkey_ln_address_1_d3649b2898_pubkey_idx;
DROP INDEX public.pubkey_ln_address_1_d3649b2898_ln_address_idx;
DROP INDEX public.pubkey_ids_1_54b55dd09c_rowid_idx;
DROP INDEX public.pubkey_ids_1_54b55dd09c_key_idx;
DROP INDEX public.pubkey_followers_cnt_1_a6f7e200e7_value_idx;
DROP INDEX public.pubkey_followers_cnt_1_a6f7e200e7_rowid_idx;
DROP INDEX public.pubkey_followers_cnt_1_a6f7e200e7_key_idx;
DROP INDEX public.pubkey_followers_1_d52305fb47_rowid_idx;
DROP INDEX public.pubkey_followers_1_d52305fb47_pubkey_idx;
DROP INDEX public.pubkey_followers_1_d52305fb47_follower_pubkey_pubkey_idx;
DROP INDEX public.pubkey_followers_1_d52305fb47_follower_pubkey_idx;
DROP INDEX public.pubkey_followers_1_d52305fb47_follower_contact_list_event_id_id;
DROP INDEX public.pubkey_events_1_1dcbfe1466_rowid_idx;
DROP INDEX public.pubkey_events_1_1dcbfe1466_pubkey_is_reply_idx;
DROP INDEX public.pubkey_events_1_1dcbfe1466_pubkey_idx;
DROP INDEX public.pubkey_events_1_1dcbfe1466_pubkey_created_at_idx;
DROP INDEX public.pubkey_events_1_1dcbfe1466_event_id_idx;
DROP INDEX public.pubkey_events_1_1dcbfe1466_created_at_pubkey_idx;
DROP INDEX public.pubkey_events_1_1dcbfe1466_created_at_idx;
DROP INDEX public.pubkey_directmsgs_cnt_1_efdf9742a6_sender_idx;
DROP INDEX public.pubkey_directmsgs_cnt_1_efdf9742a6_rowid_idx;
DROP INDEX public.pubkey_directmsgs_cnt_1_efdf9742a6_receiver_sender_idx;
DROP INDEX public.pubkey_directmsgs_cnt_1_efdf9742a6_receiver_idx;
DROP INDEX public.pubkey_directmsgs_1_c794110a2c_sender_idx;
DROP INDEX public.pubkey_directmsgs_1_c794110a2c_rowid_idx;
DROP INDEX public.pubkey_directmsgs_1_c794110a2c_receiver_sender_idx;
DROP INDEX public.pubkey_directmsgs_1_c794110a2c_receiver_idx;
DROP INDEX public.pubkey_directmsgs_1_c794110a2c_receiver_event_id_idx;
DROP INDEX public.pubkey_directmsgs_1_c794110a2c_created_at_idx;
DROP INDEX public.pubkey_content_zap_cnt_1_236df2f369_pubkey_idx;
DROP INDEX public.pubkey_bookmarks_ref_event_id;
DROP INDEX public.pubkey_bookmarks_pubkey_ref_event_id;
DROP INDEX public.preview_1_44299731c7_url_idx;
DROP INDEX public.preview_1_44299731c7_rowid_idx;
DROP INDEX public.preview_1_44299731c7_imported_at_idx;
DROP INDEX public.preview_1_44299731c7_category_idx;
DROP INDEX public.parametrized_replaceable_events_1_cbe75c8d53_rowid_idx;
DROP INDEX public.parametrized_replaceable_events_1_cbe75c8d53_pubkey_idx;
DROP INDEX public.parametrized_replaceable_events_1_cbe75c8d53_kind_idx;
DROP INDEX public.parametrized_replaceable_events_1_cbe75c8d53_identifier_idx;
DROP INDEX public.parametrized_replaceable_events_1_cbe75c8d53_event_id_idx;
DROP INDEX public.parametrized_replaceable_events_1_cbe75c8d53_created_at_idx;
DROP INDEX public.parameterized_replaceable_list_1_d02d7ecc62_rowid_idx;
DROP INDEX public.parameterized_replaceable_list_1_d02d7ecc62_pubkey_idx;
DROP INDEX public.parameterized_replaceable_list_1_d02d7ecc62_identifier_idx;
DROP INDEX public.parameterized_replaceable_list_1_d02d7ecc62_created_at_idx;
DROP INDEX public.og_zap_receipts_1_dc85307383_sender_idx;
DROP INDEX public.og_zap_receipts_1_dc85307383_rowid_idx;
DROP INDEX public.og_zap_receipts_1_dc85307383_receiver_idx;
DROP INDEX public.og_zap_receipts_1_dc85307383_event_id_idx;
DROP INDEX public.og_zap_receipts_1_dc85307383_created_at_idx;
DROP INDEX public.og_zap_receipts_1_dc85307383_amount_sats_idx;
DROP INDEX public.mute_lists_1_d90e559628_rowid_idx;
DROP INDEX public.mute_lists_1_d90e559628_key_idx;
DROP INDEX public.mute_list_2_1_949b3d746b_rowid_idx;
DROP INDEX public.mute_list_2_1_949b3d746b_key_idx;
DROP INDEX public.mute_list_1_f693a878b9_rowid_idx;
DROP INDEX public.mute_list_1_f693a878b9_key_idx;
DROP INDEX public.meta_data_1_323bc43167_rowid_idx;
DROP INDEX public.meta_data_1_323bc43167_key_idx;
DROP INDEX public.memberships_pubkey;
DROP INDEX public.media_storage_h_idx;
DROP INDEX public.media_storage_added_at_idx;
DROP INDEX public.media_1_16fa35f2dc_url_size_animated_idx;
DROP INDEX public.media_1_16fa35f2dc_url_idx;
DROP INDEX public.media_1_16fa35f2dc_rowid_idx;
DROP INDEX public.media_1_16fa35f2dc_media_url_idx;
DROP INDEX public.media_1_16fa35f2dc_imported_at_idx;
DROP INDEX public.media_1_16fa35f2dc_category_idx;
DROP INDEX public.logs_1_d241bdb71c_type_idx;
DROP INDEX public.logs_1_d241bdb71c_t_idx;
DROP INDEX public.logs_1_d241bdb71c_module_idx;
DROP INDEX public.logs_1_d241bdb71c_func_idx;
DROP INDEX public.logs_1_d241bdb71c_eid;
DROP INDEX public.lists_pubkey;
DROP INDEX public.lists_list;
DROP INDEX public.lists_added_at;
DROP INDEX public.human_override_pubkey;
DROP INDEX public.hashtags_1_1e5c72161a_score_idx;
DROP INDEX public.hashtags_1_1e5c72161a_rowid_idx;
DROP INDEX public.hashtags_1_1e5c72161a_hashtag_idx;
DROP INDEX public.filterlist_pubkey_pubkey_blocked_grp_idx;
DROP INDEX public.event_zapped_1_7ebdbebf92_rowid_idx;
DROP INDEX public.event_zapped_1_7ebdbebf92_event_id_zap_sender_idx;
DROP INDEX public.event_thread_parents_1_e17bf16c98_rowid_idx;
DROP INDEX public.event_thread_parents_1_e17bf16c98_key_idx;
DROP INDEX public.event_stats_by_pubkey_1_4ecc48a026_score_idx;
DROP INDEX public.event_stats_by_pubkey_1_4ecc48a026_score24h_idx;
DROP INDEX public.event_stats_by_pubkey_1_4ecc48a026_satszapped_idx;
DROP INDEX public.event_stats_by_pubkey_1_4ecc48a026_rowid_idx;
DROP INDEX public.event_stats_by_pubkey_1_4ecc48a026_event_id_idx;
DROP INDEX public.event_stats_by_pubkey_1_4ecc48a026_created_at_score24h_idx;
DROP INDEX public.event_stats_by_pubkey_1_4ecc48a026_created_at_satszapped_idx;
DROP INDEX public.event_stats_by_pubkey_1_4ecc48a026_created_at_idx;
DROP INDEX public.event_stats_by_pubkey_1_4ecc48a026_author_pubkey_idx;
DROP INDEX public.event_stats_1_1b380f4869_zaps_idx;
DROP INDEX public.event_stats_1_1b380f4869_score_idx;
DROP INDEX public.event_stats_1_1b380f4869_score24h_idx;
DROP INDEX public.event_stats_1_1b380f4869_satszapped_idx;
DROP INDEX public.event_stats_1_1b380f4869_rowid_idx;
DROP INDEX public.event_stats_1_1b380f4869_reposts_idx;
DROP INDEX public.event_stats_1_1b380f4869_replies_idx;
DROP INDEX public.event_stats_1_1b380f4869_mentions_idx;
DROP INDEX public.event_stats_1_1b380f4869_likes_idx;
DROP INDEX public.event_stats_1_1b380f4869_event_id_idx;
DROP INDEX public.event_stats_1_1b380f4869_created_at_score24h_idx;
DROP INDEX public.event_stats_1_1b380f4869_created_at_satszapped_idx;
DROP INDEX public.event_stats_1_1b380f4869_created_at_idx;
DROP INDEX public.event_stats_1_1b380f4869_author_pubkey_score_idx;
DROP INDEX public.event_stats_1_1b380f4869_author_pubkey_score24h_idx;
DROP INDEX public.event_stats_1_1b380f4869_author_pubkey_satszapped_idx;
DROP INDEX public.event_stats_1_1b380f4869_author_pubkey_idx;
DROP INDEX public.event_stats_1_1b380f4869_author_pubkey_created_at_idx;
DROP INDEX public.event_sentiment_1_d3d7a00a54_topsentiment_idx;
DROP INDEX public.event_replies_1_9d033b5bb3_rowid_idx;
DROP INDEX public.event_replies_1_9d033b5bb3_reply_created_at_idx;
DROP INDEX public.event_replies_1_9d033b5bb3_event_id_idx;
DROP INDEX public.event_pubkey_actions_1_d62afee35d_updated_at_idx;
DROP INDEX public.event_pubkey_actions_1_d62afee35d_rowid_idx;
DROP INDEX public.event_pubkey_actions_1_d62afee35d_pubkey_idx;
DROP INDEX public.event_pubkey_actions_1_d62afee35d_event_id_idx;
DROP INDEX public.event_pubkey_actions_1_d62afee35d_created_at_idx;
DROP INDEX public.event_pubkey_action_refs_1_f32e1ff589_rowid_idx;
DROP INDEX public.event_pubkey_action_refs_1_f32e1ff589_ref_pubkey_idx;
DROP INDEX public.event_pubkey_action_refs_1_f32e1ff589_ref_kind_idx;
DROP INDEX public.event_pubkey_action_refs_1_f32e1ff589_ref_event_id_ref_pubkey_i;
DROP INDEX public.event_pubkey_action_refs_1_f32e1ff589_ref_event_id_ref_kind_idx;
DROP INDEX public.event_pubkey_action_refs_1_f32e1ff589_ref_event_id_idx;
DROP INDEX public.event_pubkey_action_refs_1_f32e1ff589_ref_created_at_idx;
DROP INDEX public.event_pubkey_action_refs_1_f32e1ff589_event_id_idx;
DROP INDEX public.event_pubkey;
DROP INDEX public.event_preview_1_310cef356e_url_idx;
DROP INDEX public.event_preview_1_310cef356e_rowid_idx;
DROP INDEX public.event_preview_1_310cef356e_event_id_idx;
DROP INDEX public.event_mentions_1_a056fb6737_eid_idx;
DROP INDEX public.event_media_1_30bf07e9cf_url_idx;
DROP INDEX public.event_media_1_30bf07e9cf_rowid_idx;
DROP INDEX public.event_media_1_30bf07e9cf_event_id_idx;
DROP INDEX public.event_kind;
DROP INDEX public.event_imported_at_kind_idx;
DROP INDEX public.event_imported_at_id_idx;
DROP INDEX public.event_imported_at;
DROP INDEX public.event_hooks_event_id_idx;
DROP INDEX public.event_hashtags_1_295f217c0e_rowid_idx;
DROP INDEX public.event_hashtags_1_295f217c0e_hashtag_idx;
DROP INDEX public.event_hashtags_1_295f217c0e_event_id_idx;
DROP INDEX public.event_hashtags_1_295f217c0e_created_at_idx;
DROP INDEX public.event_created_at_kind;
DROP INDEX public.event_created_at_idx;
DROP INDEX public.event_created_at_1_7a51e16c5c_rowid_idx;
DROP INDEX public.event_created_at_1_7a51e16c5c_created_at_idx;
DROP INDEX public.event_attributes_1_3196ca546f_rowid_idx;
DROP INDEX public.event_attributes_1_3196ca546f_key_value_idx;
DROP INDEX public.event_attributes_1_3196ca546f_event_id_idx;
DROP INDEX public.deleted_events_1_0249f47b16_rowid_idx;
DROP INDEX public.deleted_events_1_0249f47b16_event_id_idx;
DROP INDEX public.dag_1_4bd2aaff98_output_idx;
DROP INDEX public.dag_1_4bd2aaff98_input_idx;
DROP INDEX public.coverages_1_8656fc443b_name_idx;
DROP INDEX public.contact_lists_1_1abdf474bd_rowid_idx;
DROP INDEX public.contact_lists_1_1abdf474bd_key_idx;
DROP INDEX public.cmr_pubkeys_scopes_user_pubkey_pubkey_scope_idx;
DROP INDEX public.cmr_pubkeys_parent_user_pubkey_pubkey_idx;
DROP INDEX public.cmr_pubkeys_allowed_user_pubkey_pubkey_idx;
DROP INDEX public.cmr_groups_user_pubkey_grp_scope_idx;
DROP INDEX public.bookmarks_1_43f5248b56_rowid_idx;
DROP INDEX public.bookmarks_1_43f5248b56_pubkey_idx;
DROP INDEX public.basic_tags_6_62c3d17c2f_pubkey_idx;
DROP INDEX public.basic_tags_6_62c3d17c2f_imported_at_idx;
DROP INDEX public.basic_tags_6_62c3d17c2f_id_idx;
DROP INDEX public.basic_tags_6_62c3d17c2f_created_at_idx;
DROP INDEX public.basic_tags_6_62c3d17c2f_arg1_idx;
DROP INDEX public.allow_list_1_f1da08e9c8_rowid_idx;
DROP INDEX public.allow_list_1_f1da08e9c8_key_idx;
DROP INDEX public.advsearch_5_d7da6f551e_url_tsv_idx;
DROP INDEX public.advsearch_5_d7da6f551e_reply_tsv_idx;
DROP INDEX public.advsearch_5_d7da6f551e_pubkey_idx;
DROP INDEX public.advsearch_5_d7da6f551e_pubkey_created_at_desc_idx;
DROP INDEX public.advsearch_5_d7da6f551e_mention_tsv_idx;
DROP INDEX public.advsearch_5_d7da6f551e_kind_idx;
DROP INDEX public.advsearch_5_d7da6f551e_id_idx;
DROP INDEX public.advsearch_5_d7da6f551e_hashtag_tsv_idx;
DROP INDEX public.advsearch_5_d7da6f551e_filter_tsv_idx;
DROP INDEX public.advsearch_5_d7da6f551e_created_at_idx;
DROP INDEX public.advsearch_5_d7da6f551e_content_tsv_idx;
DROP INDEX public.a_tags_1_7d98c5333f_ref_kind_ref_pubkey_ref_identifier_idx;
DROP INDEX public.a_tags_1_7d98c5333f_ref_kind_ref_pubkey_idx;
DROP INDEX public.a_tags_1_7d98c5333f_imported_at_idx;
DROP INDEX public.a_tags_1_7d98c5333f_eid_idx;
DROP INDEX public.a_tags_1_7d98c5333f_created_at_idx;
ALTER TABLE ONLY public.zap_receipts_1_9fe40119b2 DROP CONSTRAINT zap_receipts_1_9fe40119b2_pkey;
ALTER TABLE ONLY public.wsconnvars DROP CONSTRAINT wsconnvars_pkey;
ALTER TABLE ONLY public.wsconnruns DROP CONSTRAINT wsconnruns_pkey;
ALTER TABLE ONLY public.vars DROP CONSTRAINT vars_pk;
ALTER TABLE ONLY public.user_search DROP CONSTRAINT user_search_pkey;
ALTER TABLE ONLY public.trusted_pubkey_followers_cnt DROP CONSTRAINT trusted_pubkey_followers_cnt_pkey;
ALTER TABLE ONLY public.relays DROP CONSTRAINT relays_pkey;
ALTER TABLE ONLY public.relay_url_map DROP CONSTRAINT relay_url_map_pkey;
ALTER TABLE ONLY public.relay_list_metadata_1_801a17fc93 DROP CONSTRAINT relay_list_metadata_1_801a17fc93_pkey;
ALTER TABLE ONLY public.reads_versions_12_b537d4df66 DROP CONSTRAINT reads_versions_12_b537d4df66_pubkey_identifier_eid_key;
ALTER TABLE ONLY public.reads_versions_11_fb53a8e0b4 DROP CONSTRAINT reads_versions_11_fb53a8e0b4_pubkey_identifier_eid_key;
ALTER TABLE ONLY public.reads_12_68c6bbfccd DROP CONSTRAINT reads_12_68c6bbfccd_pkey;
ALTER TABLE ONLY public.reads_11_2a4d2ce519 DROP CONSTRAINT reads_11_2a4d2ce519_pkey;
ALTER TABLE ONLY public.pubkey_zapped_1_17f1f622a9 DROP CONSTRAINT pubkey_zapped_1_17f1f622a9_pkey;
ALTER TABLE ONLY public.pubkey_trustrank DROP CONSTRAINT pubkey_trustrank_pkey;
ALTER TABLE ONLY public.pubkey_notification_cnts_1_d78f6fcade DROP CONSTRAINT pubkey_notification_cnts_1_d78f6fcade_pkey;
ALTER TABLE ONLY public.pubkey_media_cnt_1_b5e2a488b1 DROP CONSTRAINT pubkey_media_cnt_1_b5e2a488b1_pkey;
ALTER TABLE ONLY public.pubkey_ln_address_1_d3649b2898 DROP CONSTRAINT pubkey_ln_address_1_d3649b2898_pkey;
ALTER TABLE ONLY public.pubkey_ids_1_54b55dd09c DROP CONSTRAINT pubkey_ids_1_54b55dd09c_pkey;
ALTER TABLE ONLY public.pubkey_followers_cnt_1_a6f7e200e7 DROP CONSTRAINT pubkey_followers_cnt_1_a6f7e200e7_pkey;
ALTER TABLE ONLY public.pubkey_content_zap_cnt_1_236df2f369 DROP CONSTRAINT pubkey_content_zap_cnt_1_236df2f369_pkey;
ALTER TABLE ONLY public.note_stats_1_07d205f278 DROP CONSTRAINT note_stats_1_07d205f278_pkey;
ALTER TABLE ONLY public.note_length_1_15d66ffae6 DROP CONSTRAINT note_length_1_15d66ffae6_pkey;
ALTER TABLE ONLY public.node_outputs_1_cfe6037c9f DROP CONSTRAINT node_outputs_1_cfe6037c9f_pkey;
ALTER TABLE ONLY public.mute_lists_1_d90e559628 DROP CONSTRAINT mute_lists_1_d90e559628_pkey;
ALTER TABLE ONLY public.mute_list_2_1_949b3d746b DROP CONSTRAINT mute_list_2_1_949b3d746b_pkey;
ALTER TABLE ONLY public.mute_list_1_f693a878b9 DROP CONSTRAINT mute_list_1_f693a878b9_pkey;
ALTER TABLE ONLY public.meta_data_1_323bc43167 DROP CONSTRAINT meta_data_1_323bc43167_pkey;
ALTER TABLE ONLY public.membership_legend_customization DROP CONSTRAINT membership_legend_customization_pk;
ALTER TABLE ONLY public.media_storage DROP CONSTRAINT media_storage_pk;
ALTER TABLE ONLY public.human_override DROP CONSTRAINT human_override_pkey;
ALTER TABLE ONLY public.filterlist DROP CONSTRAINT filterlist_pkey;
ALTER TABLE ONLY public.event_thread_parents_1_e17bf16c98 DROP CONSTRAINT event_thread_parents_1_e17bf16c98_pkey;
ALTER TABLE ONLY public.event_sentiment_1_d3d7a00a54 DROP CONSTRAINT event_sentiment_1_d3d7a00a54_pkey;
ALTER TABLE ONLY public.event_relay DROP CONSTRAINT event_relay_pkey;
ALTER TABLE ONLY public.event_pubkey_actions_1_d62afee35d DROP CONSTRAINT event_pubkey_actions_1_d62afee35d_pkey;
ALTER TABLE ONLY public.event DROP CONSTRAINT event_pkey;
ALTER TABLE ONLY public.event_mentions_1_6738bfddaf DROP CONSTRAINT event_mentions_1_6738bfddaf_pkey;
ALTER TABLE ONLY public.event_mentions_1_0b730615c4 DROP CONSTRAINT event_mentions_1_0b730615c4_pkey;
ALTER TABLE ONLY public.event_media_1_30bf07e9cf DROP CONSTRAINT event_media_1_30bf07e9cf_pkey;
ALTER TABLE ONLY public.event_created_at_1_7a51e16c5c DROP CONSTRAINT event_created_at_1_7a51e16c5c_pkey;
ALTER TABLE ONLY public.dvm_feeds DROP CONSTRAINT dvm_feeds_pkey;
ALTER TABLE ONLY public.deleted_events_1_0249f47b16 DROP CONSTRAINT deleted_events_1_0249f47b16_pkey;
ALTER TABLE ONLY public.daily_followers_cnt_increases DROP CONSTRAINT daily_followers_cnt_increases_pkey;
ALTER TABLE ONLY public.dag_1_4bd2aaff98 DROP CONSTRAINT dag_1_4bd2aaff98_output_input_key;
ALTER TABLE ONLY public.coverages_1_8656fc443b DROP CONSTRAINT coverages_1_8656fc443b_name_t_key;
ALTER TABLE ONLY public.contact_lists_1_1abdf474bd DROP CONSTRAINT contact_lists_1_1abdf474bd_pkey;
ALTER TABLE ONLY public.cache DROP CONSTRAINT cache_pkey;
ALTER TABLE ONLY public.bookmarks_1_43f5248b56 DROP CONSTRAINT bookmarks_1_43f5248b56_pkey;
ALTER TABLE ONLY public.basic_tags_6_62c3d17c2f DROP CONSTRAINT basic_tags_6_62c3d17c2f_pkey;
ALTER TABLE ONLY public.basic_tags_6_62c3d17c2f DROP CONSTRAINT basic_tags_6_62c3d17c2f_id_tag_arg1_arg3_key;
ALTER TABLE ONLY public.allow_list_1_f1da08e9c8 DROP CONSTRAINT allow_list_1_f1da08e9c8_pkey;
ALTER TABLE ONLY public.advsearch_5_d7da6f551e DROP CONSTRAINT advsearch_5_d7da6f551e_pkey;
ALTER TABLE ONLY public.advsearch_5_d7da6f551e DROP CONSTRAINT advsearch_5_d7da6f551e_id_key;
ALTER TABLE ONLY public.a_tags_1_7d98c5333f DROP CONSTRAINT a_tags_1_7d98c5333f_pkey;
ALTER TABLE ONLY public.a_tags_1_7d98c5333f DROP CONSTRAINT a_tags_1_7d98c5333f_eid_ref_kind_ref_pubkey_ref_identifier__key;
ALTER TABLE public.wsconnruns ALTER COLUMN run DROP DEFAULT;
ALTER TABLE public.basic_tags_6_62c3d17c2f ALTER COLUMN i DROP DEFAULT;
ALTER TABLE public.advsearch_5_d7da6f551e ALTER COLUMN i DROP DEFAULT;
ALTER TABLE public.a_tags_1_7d98c5333f ALTER COLUMN i DROP DEFAULT;
DROP VIEW public.zap_receipts;
DROP TABLE public.zap_receipts_1_9fe40119b2;
DROP TABLE public.wsconnvars;
DROP SEQUENCE public.wsconnruns_run_seq;
DROP TABLE public.wsconnruns;
DROP TABLE public.wsconnlog;
DROP VIEW public.video_thumbnails;
DROP TABLE public.video_thumbnails_1_107d5a46eb;
DROP TABLE public.verified_users;
DROP TABLE public.vars;
DROP TABLE public.user_search;
DROP VIEW public.trusted_users_trusted_followers;
DROP TABLE public.trusted_pubkey_followers_cnt;
DROP TABLE public.trelays;
DROP TABLE public.test_pubkeys;
DROP TABLE public.stuff;
DROP TABLE public.score_expiry;
DROP TABLE public.scheduled_hooks;
DROP TABLE public.relays;
DROP TABLE public.relay_url_map;
DROP VIEW public.relay_list_metadata;
DROP TABLE public.relay_list_metadata_1_801a17fc93;
DROP TABLE public.reads_versions_11_fb53a8e0b4;
DROP VIEW public.reads_versions;
DROP TABLE public.reads_versions_12_b537d4df66;
DROP TABLE public.reads_11_2a4d2ce519;
DROP VIEW public.reads;
DROP TABLE public.reads_12_68c6bbfccd;
DROP VIEW public.pubkey_zapped;
DROP TABLE public.pubkey_zapped_1_17f1f622a9;
DROP TABLE public.pubkey_trustrank;
DROP VIEW public.pubkey_notifications;
DROP TABLE public.pubkey_notifications_1_e5459ab9dd;
DROP VIEW public.pubkey_notification_cnts;
DROP TABLE public.pubkey_notification_cnts_1_d78f6fcade;
DROP VIEW public.pubkey_media_cnt;
DROP TABLE public.pubkey_media_cnt_1_b5e2a488b1;
DROP VIEW public.pubkey_ln_address;
DROP TABLE public.pubkey_ln_address_1_d3649b2898;
DROP VIEW public.pubkey_ids;
DROP TABLE public.pubkey_ids_1_54b55dd09c;
DROP VIEW public.pubkey_followers_cnt;
DROP TABLE public.pubkey_followers_cnt_1_a6f7e200e7;
DROP VIEW public.pubkey_followers;
DROP TABLE public.pubkey_followers_1_d52305fb47;
DROP VIEW public.pubkey_events;
DROP TABLE public.pubkey_events_1_1dcbfe1466;
DROP VIEW public.pubkey_directmsgs_cnt;
DROP TABLE public.pubkey_directmsgs_cnt_1_efdf9742a6;
DROP VIEW public.pubkey_directmsgs;
DROP TABLE public.pubkey_directmsgs_1_c794110a2c;
DROP VIEW public.pubkey_content_zap_cnt;
DROP TABLE public.pubkey_content_zap_cnt_1_236df2f369;
DROP TABLE public.pubkey_bookmarks;
DROP VIEW public.preview;
DROP TABLE public.preview_1_44299731c7;
DROP VIEW public.parametrized_replaceable_events;
DROP TABLE public.parametrized_replaceable_events_1_cbe75c8d53;
DROP VIEW public.parameterized_replaceable_list;
DROP TABLE public.parameterized_replaceable_list_1_d02d7ecc62;
DROP VIEW public.og_zap_receipts;
DROP TABLE public.og_zap_receipts_1_dc85307383;
DROP VIEW public.note_stats;
DROP TABLE public.note_stats_1_07d205f278;
DROP VIEW public.note_length;
DROP TABLE public.note_length_1_15d66ffae6;
DROP TABLE public.node_outputs_1_cfe6037c9f;
DROP VIEW public.mute_lists;
DROP TABLE public.mute_lists_1_d90e559628;
DROP VIEW public.mute_list_2;
DROP TABLE public.mute_list_2_1_949b3d746b;
DROP VIEW public.mute_list;
DROP TABLE public.mute_list_1_f693a878b9;
DROP VIEW public.meta_data;
DROP TABLE public.meta_data_1_323bc43167;
DROP TABLE public.memberships;
DROP TABLE public.membership_legend_customization;
DROP TABLE public.media_storage;
DROP VIEW public.media;
DROP TABLE public.media_1_16fa35f2dc;
DROP TABLE public.logs_1_d241bdb71c;
DROP TABLE public.lists;
DROP TABLE public.human_override;
DROP VIEW public.hashtags;
DROP TABLE public.hashtags_1_1e5c72161a;
DROP TABLE public.filterlist_pubkey;
DROP TABLE public.filterlist;
DROP VIEW public.events;
DROP VIEW public.event_zapped;
DROP TABLE public.event_zapped_1_7ebdbebf92;
DROP VIEW public.event_thread_parents;
DROP TABLE public.event_thread_parents_1_e17bf16c98;
DROP VIEW public.event_tags;
DROP VIEW public.event_stats_by_pubkey;
DROP TABLE public.event_stats_by_pubkey_1_4ecc48a026;
DROP VIEW public.event_stats;
DROP TABLE public.event_stats_1_1b380f4869;
DROP VIEW public.event_sentiment;
DROP TABLE public.event_sentiment_1_d3d7a00a54;
DROP VIEW public.event_replies;
DROP TABLE public.event_replies_1_9d033b5bb3;
DROP TABLE public.event_relay;
DROP VIEW public.event_pubkey_actions;
DROP TABLE public.event_pubkey_actions_1_d62afee35d;
DROP VIEW public.event_pubkey_action_refs;
DROP TABLE public.event_pubkey_action_refs_1_f32e1ff589;
DROP VIEW public.event_preview;
DROP TABLE public.event_preview_1_310cef356e;
DROP TABLE public.event_mentions_1_6738bfddaf;
DROP TABLE public.event_mentions_1_0b730615c4;
DROP VIEW public.event_mentions;
DROP TABLE public.event_mentions_1_a056fb6737;
DROP VIEW public.event_media;
DROP TABLE public.event_media_1_30bf07e9cf;
DROP TABLE public.event_hooks;
DROP VIEW public.event_hashtags;
DROP TABLE public.event_hashtags_1_295f217c0e;
DROP VIEW public.event_created_at;
DROP TABLE public.event_created_at_1_7a51e16c5c;
DROP VIEW public.event_attributes;
DROP TABLE public.event_attributes_1_3196ca546f;
DROP TABLE public.dvm_feeds;
DROP VIEW public.deleted_events;
DROP TABLE public.deleted_events_1_0249f47b16;
DROP TABLE public.daily_followers_cnt_increases;
DROP TABLE public.dag_1_4bd2aaff98;
DROP TABLE public.coverages_1_8656fc443b;
DROP VIEW public.contact_lists;
DROP TABLE public.contact_lists_1_1abdf474bd;
DROP TABLE public.cmr_pubkeys_scopes;
DROP TABLE public.cmr_pubkeys_parent;
DROP TABLE public.cmr_pubkeys_allowed;
DROP TABLE public.cmr_groups;
DROP TABLE public.cache;
DROP VIEW public.bookmarks;
DROP TABLE public.bookmarks_1_43f5248b56;
DROP SEQUENCE public.basic_tags_6_62c3d17c2f_i_seq;
DROP VIEW public.basic_tags;
DROP TABLE public.basic_tags_6_62c3d17c2f;
DROP VIEW public.allow_list;
DROP TABLE public.allow_list_1_f1da08e9c8;
DROP SEQUENCE public.advsearch_5_d7da6f551e_i_seq;
DROP VIEW public.advsearch;
DROP TABLE public.advsearch_5_d7da6f551e;
DROP SEQUENCE public.a_tags_1_7d98c5333f_i_seq;
DROP VIEW public.a_tags;
DROP TABLE public.a_tags_1_7d98c5333f;
DROP FUNCTION public.zap_response(r record, a_user_pubkey bytea);
DROP FUNCTION public.wsconntasks(a_port bigint);
DROP FUNCTION public.user_is_human(a_pubkey bytea, a_user_pubkey bytea);
DROP FUNCTION public.user_is_human(a_pubkey bytea);
DROP FUNCTION public.user_infos(a_pubkeys text[]);
DROP FUNCTION public.user_infos(a_pubkeys bytea[]);
DROP FUNCTION public.user_has_bio(a_pubkey bytea);
DROP FUNCTION public.user_follows_posts(a_pubkey bytea, a_since bigint, a_until bigint, a_include_replies bigint, a_limit bigint, a_offset bigint);
DROP PROCEDURE public.update_user_relative_daily_follower_count_increases();
DROP FUNCTION public.update_updated_at();
DROP FUNCTION public.try_cast_jsonb(a_json text, a_default jsonb);
DROP FUNCTION public.thread_view_reply_posts(a_event_id bytea, a_limit bigint, a_since bigint, a_until bigint, a_offset bigint);
DROP FUNCTION public.thread_view_parent_posts(a_event_id bytea);
DROP FUNCTION public.thread_view(a_event_id bytea, a_limit bigint, a_since bigint, a_until bigint, a_offset bigint, a_user_pubkey bytea, a_apply_humaness_check boolean);
DROP FUNCTION public.test_pubkeys(a_name text);
DROP FUNCTION public.safe_jsonb(data text);
DROP FUNCTION public.safe_json(i text, fallback jsonb);
DROP FUNCTION public.response_messages_for_post(a_event_id bytea, a_user_pubkey bytea, a_is_referenced_event boolean, a_depth bigint);
DROP PROCEDURE public.record_trusted_pubkey_followers_cnt();
DROP FUNCTION public.raise_notice(a text);
DROP FUNCTION public.primal_verified_names(a_pubkeys bytea[]);
DROP FUNCTION public.notification_is_visible(type bigint, arg1 bytea, arg2 bytea, a_user_pubkey bytea);
DROP FUNCTION public.notification_is_visible(type bigint, arg1 bytea, arg2 bytea);
DROP FUNCTION public.notification_is_hidden(type bigint, arg1 bytea, arg2 bytea);
DROP FUNCTION public.long_form_content_feed(a_pubkey bytea, a_notes character varying, a_topic character varying, a_curation character varying, a_minwords bigint, a_limit bigint, a_since bigint, a_until bigint, a_offset bigint, a_user_pubkey bytea, a_apply_humaness_check boolean);
DROP FUNCTION public.is_pubkey_hidden_by_group(a_user_pubkey bytea, a_scope public.cmr_scope, a_pubkey bytea, a_cmr_grp public.cmr_grp, a_fl_grp public.filterlist_grp);
DROP FUNCTION public.is_pubkey_hidden(a_user_pubkey bytea, a_scope public.cmr_scope, a_pubkey bytea);
DROP FUNCTION public.is_event_hidden(a_user_pubkey bytea, a_scope public.cmr_scope, a_event_id bytea);
DROP FUNCTION public.humaness_threshold_trustrank();
DROP FUNCTION public.get_event_jsonb(a_event_id bytea);
DROP FUNCTION public.get_event(a_event_id bytea);
DROP TABLE public.event;
DROP FUNCTION public.get_bookmarks(a_pubkey bytea);
DROP FUNCTION public.feed_user_follows(a_pubkey bytea, a_since bigint, a_until bigint, a_include_replies bigint, a_limit bigint, a_offset bigint, a_user_pubkey bytea, a_apply_humaness_check boolean);
DROP FUNCTION public.feed_user_authored(a_pubkey bytea, a_since bigint, a_until bigint, a_include_replies bigint, a_limit bigint, a_offset bigint, a_user_pubkey bytea, a_apply_humaness_check boolean);
DROP FUNCTION public.event_zaps(a_pubkey bytea, a_identifier character varying, a_user_pubkey bytea);
DROP FUNCTION public.event_zaps(a_event_id bytea, a_user_pubkey bytea);
DROP FUNCTION public.event_zap_by_zap_receipt_id(a_zap_receipt_id bytea, a_user_pubkey bytea);
DROP FUNCTION public.event_stats_for_long_form_content(a_event_id bytea);
DROP FUNCTION public.event_stats(a_event_id bytea);
DROP FUNCTION public.event_preview_response(a_event_id bytea);
DROP FUNCTION public.event_media_response(a_event_id bytea);
DROP FUNCTION public.event_is_deleted(a_event_id bytea);
DROP FUNCTION public.event_action_cnt(a_event_id bytea, a_user_pubkey bytea);
DROP FUNCTION public.enrich_feed_events_(a_posts public.post[], a_user_pubkey bytea, a_apply_humaness_check boolean);
DROP FUNCTION public.enrich_feed_events(a_posts public.post[], a_user_pubkey bytea, a_apply_humaness_check boolean, a_order_by character varying);
DROP FUNCTION public.count_jsonb_keys(j jsonb);
DROP FUNCTION public.content_moderation_filtering(a_results jsonb, a_scope public.cmr_scope, a_user_pubkey bytea);
DROP FUNCTION public.c_zap_event();
DROP FUNCTION public.c_user_scores();
DROP FUNCTION public.c_user_primal_names();
DROP FUNCTION public.c_user_follower_counts();
DROP FUNCTION public.c_referenced_event();
DROP FUNCTION public.c_range();
DROP FUNCTION public.c_membership_legend_customization();
DROP FUNCTION public.c_membership_cohorts();
DROP FUNCTION public.c_media_metadata();
DROP FUNCTION public.c_long_form_metadata();
DROP FUNCTION public.c_link_metadata();
DROP FUNCTION public.c_event_stats();
DROP FUNCTION public.c_event_relays();
DROP FUNCTION public.c_event_actions_count();
DROP FUNCTION public.c_collection_order();
DROP TYPE public.response_messages_for_post_res;
DROP TYPE public.post;
DROP TYPE public.media_size;
DROP TYPE public.filterlist_target;
DROP TYPE public.filterlist_grp;
DROP TYPE public.cmr_scope;
DROP TYPE public.cmr_grp;
DROP SCHEMA public;

CREATE SCHEMA public;



COMMENT ON SCHEMA public IS 'standard public schema';



CREATE TYPE public.cmr_grp AS ENUM (
    'primal_spam',
    'primal_nsfw'
);



CREATE TYPE public.cmr_scope AS ENUM (
    'content',
    'trending'
);



CREATE TYPE public.filterlist_grp AS ENUM (
    'spam',
    'nsfw',
    'csam'
);



CREATE TYPE public.filterlist_target AS ENUM (
    'pubkey',
    'event'
);



CREATE TYPE public.media_size AS ENUM (
    'original',
    'small',
    'medium',
    'large'
);



CREATE TYPE public.post AS (
	event_id bytea,
	created_at bigint
);



CREATE TYPE public.response_messages_for_post_res AS (
	e jsonb,
	is_referenced_event boolean
);



CREATE FUNCTION public.c_collection_order() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000161$$;



CREATE FUNCTION public.c_event_actions_count() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000115$$;



CREATE FUNCTION public.c_event_relays() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000141$$;



CREATE FUNCTION public.c_event_stats() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000100$$;



CREATE FUNCTION public.c_link_metadata() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000128$$;



CREATE FUNCTION public.c_long_form_metadata() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000144$$;



CREATE FUNCTION public.c_media_metadata() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000119$$;



CREATE FUNCTION public.c_membership_cohorts() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000169$$;



CREATE FUNCTION public.c_membership_legend_customization() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000168$$;



CREATE FUNCTION public.c_range() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000113$$;



CREATE FUNCTION public.c_referenced_event() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000107$$;



CREATE FUNCTION public.c_user_follower_counts() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000133$$;



CREATE FUNCTION public.c_user_primal_names() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000158$$;



CREATE FUNCTION public.c_user_scores() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000108$$;



CREATE FUNCTION public.c_zap_event() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000129$$;



CREATE FUNCTION public.content_moderation_filtering(a_results jsonb, a_scope public.cmr_scope, a_user_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
SELECT e 
FROM jsonb_array_elements(a_results) r(e) 
WHERE e->>'pubkey' IS NULL OR NOT is_pubkey_hidden(a_user_pubkey, a_scope, DECODE(e->>'pubkey', 'hex'))
$$;



CREATE FUNCTION public.count_jsonb_keys(j jsonb) RETURNS bigint
    LANGUAGE sql
    AS $$ SELECT count(*) from (SELECT jsonb_object_keys(j)) v $$;



CREATE FUNCTION public.enrich_feed_events(a_posts public.post[], a_user_pubkey bytea, a_apply_humaness_check boolean, a_order_by character varying DEFAULT 'created_at'::character varying) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
	t RECORD;
	p RECORD;
	r RECORD;
	max_created_at int8 := null;
	min_created_at int8 := null;
    relay_url varchar;
    relays jsonb := '{}';
    user_scores jsonb := '{}';
    pubkeys bytea[] := '{}';
    identifier varchar;
    a_posts_sorted post[];
    elements jsonb := '{}';
BEGIN
    BEGIN
        a_posts_sorted := ARRAY (SELECT (event_id, created_at)::post FROM UNNEST(a_posts) p ORDER BY created_at DESC);
        SELECT COALESCE(jsonb_agg(ENCODE(event_id, 'hex')), '[]'::jsonb) INTO elements FROM UNNEST(a_posts_sorted) p;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE '% %', SQLERRM, SQLSTATE;
    END;

	FOREACH p IN ARRAY a_posts_sorted LOOP
		max_created_at := GREATEST(max_created_at, p.created_at);
		min_created_at := LEAST(min_created_at, p.created_at);
        FOR t IN SELECT * FROM response_messages_for_post(p.event_id, a_user_pubkey, false, 3) LOOP
            DECLARE
                e jsonb := t.e;
                e_id bytea := DECODE(e->>'id', 'hex');
                e_kind int8 := e->>'kind';
                e_pubkey bytea := DECODE(e->>'pubkey', 'hex');
                read_eid bytea;
            BEGIN
                IF e_pubkey IS NOT NULL THEN
                    pubkeys := array_append(pubkeys, e_pubkey);
                END IF;

                IF a_apply_humaness_check AND NOT user_is_human(e_pubkey, a_user_pubkey) THEN
                    CONTINUE;
                END IF;

                IF e_kind = 6 AND (
                    EXISTS (SELECT 1 FROM basic_tags WHERE id = e_id AND tag = 'p' AND is_pubkey_hidden(a_user_pubkey, 'content', arg1))
                    OR
                    EXISTS (SELECT 1 FROM basic_tags WHERE id = e_id AND tag = 'e' AND event_is_deleted(arg1))
                ) THEN
                    CONTINUE;
                END IF;

                IF t.is_referenced_event THEN
                    RETURN NEXT jsonb_build_object(
                            'pubkey', e->>'pubkey',
                            'kind', c_REFERENCED_EVENT(), 
                            'content', e::text);
                ELSE
                    RETURN NEXT e;
                END IF;

                IF e_kind = 1 OR e_kind = 30023 THEN
                    /* IF NOT t.is_referenced_event THEN */
                        RETURN QUERY SELECT * FROM event_zaps(e_id, a_user_pubkey);
                    /* END IF; */

                    FOR identifier IN SELECT pre.identifier FROM parametrized_replaceable_events pre WHERE event_id = e_id LOOP
                        RETURN QUERY SELECT * FROM event_zaps(e_pubkey, identifier, a_user_pubkey);
                    END LOOP;

                    IF    e_kind = 1     THEN RETURN QUERY SELECT * FROM event_stats(e_id);
                    ELSIF e_kind = 30023 THEN RETURN QUERY SELECT * FROM event_stats_for_long_form_content(e_id);
                    END IF;

                    RETURN QUERY SELECT * FROM event_action_cnt(e_id, a_user_pubkey);

                    FOR r IN SELECT * FROM event_relay WHERE event_id = e_id LOOP
                        relay_url := r.relay_url;
                        SELECT dest INTO relay_url FROM relay_url_map WHERE src = relay_url LIMIT 1;
                        IF NOT (relay_url IS null) THEN
                            relays := jsonb_set(relays, array[(e->>'id')::text], to_jsonb(relay_url));
                        END IF;
                    END LOOP;
                END IF;

                IF e_kind = 0 OR e_kind = 1 OR e_kind = 6 THEN
                    RETURN QUERY SELECT * FROM event_media_response(e_id);
                    RETURN QUERY SELECT * FROM event_preview_response(e_id);
                END IF;
                IF e_kind = 30023 THEN
                    FOR read_eid IN 
                        SELECT rv.eid 
                        FROM reads rs, reads_versions rv 
                        WHERE rs.latest_eid = e_id AND rs.pubkey = rv.pubkey AND rs.identifier = rv.identifier
                    LOOP
                        RETURN QUERY SELECT * FROM event_media_response(read_eid);
                        RETURN QUERY SELECT * FROM event_preview_response(read_eid);
                    END LOOP;
                END IF;

                IF e_kind = 30023 THEN
                    DECLARE
                        words int8;
                    BEGIN
                        SELECT rs.words INTO words FROM reads_versions rv, reads rs
                        WHERE rv.eid = e_id AND rv.pubkey = rs.pubkey AND rv.identifier = rs.identifier;
                        IF words IS NOT null THEN
                            RETURN NEXT jsonb_build_object(
                                'kind', c_LONG_FORM_METADATA(), 
                                'content', jsonb_build_object(
                                    'event_id', e->>'id',
                                    'words', words)::text);
                        END IF;
                    END;
                END IF;

                IF e_kind = 0 THEN
                    FOR r IN SELECT value FROM pubkey_followers_cnt WHERE key = e_pubkey LIMIT 1 LOOP
                        user_scores := jsonb_set(user_scores, array[e->>'pubkey'::text], to_jsonb(r.value));
                    END LOOP;
                END IF;

                IF e_kind = 9735 AND t.is_referenced_event THEN
                    RETURN QUERY SELECT * FROM event_zap_by_zap_receipt_id(e_id, a_user_pubkey);
                END IF;
            END;
        END LOOP;
	END LOOP;

    IF count_jsonb_keys(user_scores) > 0 THEN
        RETURN NEXT jsonb_build_object('kind', c_USER_SCORES(), 'content', user_scores::text);
    END IF;

    IF count_jsonb_keys(relays) > 0 THEN
        RETURN NEXT jsonb_build_object('kind', c_EVENT_RELAYS(), 'content', relays::text);
    END IF;

    IF pubkeys != '{}' THEN
        RETURN QUERY SELECT * FROM primal_verified_names(pubkeys);
    END IF;

	RETURN NEXT jsonb_build_object(
		'kind', c_RANGE(),
		'content', json_build_object(
			'since', min_created_at, 
			'until', max_created_at, 
			'order_by', a_order_by,
            'elements', elements)::text);
    
	/* RETURN NEXT jsonb_build_object( */
	/* 	'kind', c_COLLECTION_ORDER(), */
	/* 	'content', json_build_object( */
	/* 		'elements', elements, */ 
	/* 		'order_by', a_order_by)::text); */
END;
$$;



CREATE FUNCTION public.enrich_feed_events_(a_posts public.post[], a_user_pubkey bytea, a_apply_humaness_check boolean) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
	t RECORD;
	p RECORD;
	r RECORD;
	max_created_at int8 := null;
	min_created_at int8 := null;
    relay_url varchar;
    relays jsonb := '{}';
    user_scores jsonb := '{}';
    identifier varchar;
BEGIN
	FOREACH p IN ARRAY a_posts LOOP
        RAISE NOTICE '%', p;
		max_created_at := GREATEST(max_created_at, p.created_at);
		min_created_at := LEAST(min_created_at, p.created_at);
        FOR t IN SELECT * FROM response_messages_for_post(p.event_id, a_user_pubkey, false, 3) LOOP
            DECLARE
                e jsonb := t.e;
                e_id bytea := DECODE(e->>'id', 'hex');
                e_kind int8 := e->>'kind';
                e_pubkey bytea := DECODE(e->>'pubkey', 'hex');
            BEGIN
                IF a_apply_humaness_check AND NOT user_is_human(e_pubkey) THEN
                    CONTINUE;
                END IF;

                IF t.is_referenced_event THEN
                    RETURN NEXT jsonb_build_object(
                            'pubkey', e->>'pubkey',
                            'kind', c_REFERENCED_EVENT(), 
                            'content', e::text);
                ELSE
                    RETURN NEXT e;
                END IF;

                IF e_kind = 1 OR e_kind = 30023 THEN
                    IF NOT t.is_referenced_event THEN
                        RETURN QUERY SELECT * FROM event_zaps(e_id, a_user_pubkey);
                    END IF;

                    FOR identifier IN SELECT pre.identifier FROM parametrized_replaceable_events pre WHERE event_id = e_id LOOP
                        RETURN QUERY SELECT * FROM event_zaps(e_pubkey, identifier, a_user_pubkey);
                    END LOOP;

                    IF    e_kind = 1     THEN RETURN QUERY SELECT * FROM event_stats(e_id);
                    ELSIF e_kind = 30023 THEN RETURN QUERY SELECT * FROM event_stats_for_long_form_content(e_id);
                    END IF;

                    RETURN QUERY SELECT * FROM event_action_cnt(e_id, a_user_pubkey);

                    FOR r IN SELECT * FROM event_relay WHERE event_id = e_id LOOP
                        relay_url := r.relay_url;
                        SELECT dest INTO relay_url FROM relay_url_map WHERE src = relay_url LIMIT 1;
                        IF NOT (relay_url IS null) THEN
                            relays := jsonb_set(relays, array[(e->>'id')::text], to_jsonb(relay_url));
                        END IF;
                    END LOOP;
                END IF;

                IF e_kind = 0 OR e_kind = 1 OR e_kind = 6 THEN
                    RETURN QUERY SELECT * FROM event_media_response(e_id);
                    RETURN QUERY SELECT * FROM event_preview_response(e_id);
                END IF;

                IF e_kind = 30023 THEN
                    DECLARE
                        words int8;
                    BEGIN
                        SELECT rs.words INTO words FROM reads_versions rv, reads rs
                        WHERE rv.eid = e_id AND rv.pubkey = rs.pubkey AND rv.identifier = rs.identifier;
                        IF words IS NOT null THEN
                            RETURN NEXT jsonb_build_object(
                                'kind', c_LONG_FORM_METADATA(), 
                                'content', jsonb_build_object(
                                    'event_id', e->>'id',
                                    'words', words)::text);
                        END IF;
                    END;
                END IF;

                IF e_kind = 0 THEN
                    FOR r IN SELECT value FROM pubkey_followers_cnt WHERE key = e_pubkey LIMIT 1 LOOP
                        user_scores := jsonb_set(user_scores, array[e_pubkey::text], to_jsonb(r.value));
                    END LOOP;
                END IF;
            END;
        END LOOP;
	END LOOP;

    IF count_jsonb_keys(user_scores) > 0 THEN
        RETURN NEXT jsonb_build_object('kind', c_USER_SCORES(), 'content', user_scores::text);
    END IF;

    IF count_jsonb_keys(relays) > 0 THEN
        RETURN NEXT jsonb_build_object('kind', c_EVENT_RELAYS(), 'content', relays::text);
    END IF;

	RETURN NEXT jsonb_build_object(
		'kind', c_RANGE(),
		'content', json_build_object(
			'since', min_created_at, 
			'until', max_created_at, 
			'order_by', 'created_at')::text);

END;
$$;



CREATE FUNCTION public.event_action_cnt(a_event_id bytea, a_user_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$	
	SELECT jsonb_build_object('kind', c_EVENT_ACTIONS_COUNT(), 'content', row_to_json(a)::text)
	FROM (
		SELECT 
            ENCODE(event_id, 'hex') AS event_id, 
            replied::int4::bool, 
            liked::int4::bool, 
            reposted::int4::bool, 
            zapped::int4::bool
		FROM event_pubkey_actions WHERE event_id = a_event_id AND pubkey = a_user_pubkey
		LIMIT 1
	) a
$$;



CREATE FUNCTION public.event_is_deleted(a_event_id bytea) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
SELECT EXISTS (SELECT 1 FROM deleted_events WHERE event_id = a_event_id)
$$;



CREATE FUNCTION public.event_media_response(a_event_id bytea) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$	
DECLARE
    res jsonb := '{}';
    resources jsonb := '[]';
    root_mt varchar;
    thumbnails jsonb := '{}';
    r_url varchar;
    r_thumbnail_url varchar;
    r record;
BEGIN
    FOR r_url IN SELECT em.url FROM event_media em WHERE event_id = a_event_id LOOP
        DECLARE
            variants jsonb := '[]';
        BEGIN
            FOR r IN SELECT size AS s, animated AS a, width AS w, height AS h, mimetype AS mt, duration AS dur FROM media WHERE media.url = r_url LOOP
                variants := variants || jsonb_build_array(jsonb_build_object(
                        's', SUBSTR(r.s, 1, 1),
                        'a', r.a,
                        'w', r.w,
                        'h', r.h,
                        'mt', r.mt,
                        'dur', r.dur,
                        'media_url', cdn_url(r_url, r.s, r.a::int4::bool)));
                root_mt := r.mt;
            END LOOP;
            resources := resources || jsonb_build_array(jsonb_build_object(
                    'url', r_url,
                    'variants', variants,
                    'mt', root_mt));
            FOR r_thumbnail_url IN SELECT thumbnail_url FROM video_thumbnails WHERE video_url = r_url LOOP
                thumbnails := jsonb_set(thumbnails, array[r_url], to_jsonb(r_thumbnail_url));
            END LOOP;
        END;
    END LOOP;

    IF jsonb_array_length(resources) > 0 THEN
        res := jsonb_set(res, array['resources'], resources);
    END IF;
    IF count_jsonb_keys(thumbnails) > 0 THEN
        res := jsonb_set(res, array['thumbnails'], thumbnails);
    END IF;

    IF count_jsonb_keys(res) > 0 THEN
        res := jsonb_set(res, array['event_id'], to_jsonb(ENCODE(a_event_id, 'hex')));
        RETURN NEXT jsonb_build_object(
            'kind', c_MEDIA_METADATA(),
            'content', res::text);
    END IF;
END $$;



CREATE FUNCTION public.event_preview_response(a_event_id bytea) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$	
DECLARE
    resources jsonb := '[]';
    r record;
    r_url varchar;
BEGIN
    FOR r_url IN SELECT ep.url FROM event_preview ep WHERE event_id = a_event_id LOOP
        FOR r IN SELECT mimetype, md_title, md_description, md_image, icon_url FROM preview where url = r_url LOOP
            resources := resources || jsonb_build_array(jsonb_build_object(
                    'url', r_url, 
                    'mimetype', r.mimetype, 
                    'md_title', r.md_title, 
                    'md_description', r.md_description, 
                    'md_image', r.md_image, 
                    'icon_url', r.icon_url));
        END LOOP;
    END LOOP;

    IF jsonb_array_length(resources) > 0 THEN
        RETURN NEXT jsonb_build_object(
            'kind', c_LINK_METADATA(),
            'content', jsonb_build_object(
                'resources', resources,
                'event_id', ENCODE(a_event_id, 'hex'))::text);
    END IF;
END $$;



CREATE FUNCTION public.event_stats(a_event_id bytea) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
	SELECT jsonb_build_object('kind', c_EVENT_STATS(), 'content', row_to_json(a)::text)
	FROM (
		SELECT ENCODE(a_event_id, 'hex') as event_id, likes, replies, mentions, reposts, zaps, satszapped, score, score24h 
		FROM event_stats WHERE event_id = a_event_id
		LIMIT 1
	) a
$$;



CREATE FUNCTION public.event_stats_for_long_form_content(a_event_id bytea) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
	SELECT jsonb_build_object('kind', c_EVENT_STATS(), 'content', row_to_json(a)::text)
	FROM (
        SELECT ENCODE(a_event_id, 'hex') as event_id, likes, replies, 0 AS mentions, reposts, zaps, satszapped, 0 AS score, 0 AS score24h 
        FROM reads WHERE latest_eid = a_event_id LIMIT 1
	) a
$$;



CREATE FUNCTION public.event_zap_by_zap_receipt_id(a_zap_receipt_id bytea, a_user_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$	
DECLARE
    r record;
BEGIN
    FOR r IN 
        SELECT zap_receipt_id, created_at, event_id, sender, receiver, amount_sats FROM og_zap_receipts 
        WHERE zap_receipt_id = a_zap_receipt_id
    LOOP
        RETURN QUERY SELECT * FROM zap_response(r, a_user_pubkey);
    END LOOP;
END $$;



CREATE FUNCTION public.event_zaps(a_event_id bytea, a_user_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$	
DECLARE
    r record;
BEGIN
    FOR r IN 
        SELECT zap_receipt_id, created_at, event_id, sender, receiver, amount_sats FROM og_zap_receipts 
        WHERE event_id = a_event_id
        ORDER BY amount_sats DESC LIMIT 5
    LOOP
        RETURN QUERY SELECT * FROM zap_response(r, a_user_pubkey);
    END LOOP;
END $$;



CREATE FUNCTION public.event_zaps(a_pubkey bytea, a_identifier character varying, a_user_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$	
DECLARE
    r record;
    pk bytea;
BEGIN
    FOR r IN 
        SELECT
            zr.eid        AS zap_receipt_id,
            zr.created_at AS created_at,
            zr.target_eid AS event_id,
            zr.sender     AS sender,
            zr.receiver   AS receiver,
            zr.satszapped AS amount_sats 
        FROM
            reads_versions rv,
            zap_receipts zr
        WHERE 
            rv.pubkey = a_pubkey AND 
            rv.identifier = a_identifier AND 
            rv.eid = zr.target_eid
        ORDER BY amount_sats DESC LIMIT 5
    LOOP
        RETURN QUERY SELECT * FROM zap_response(r, a_user_pubkey);
    END LOOP;
END $$;



CREATE FUNCTION public.feed_user_authored(a_pubkey bytea, a_since bigint, a_until bigint, a_include_replies bigint, a_limit bigint, a_offset bigint, a_user_pubkey bytea, a_apply_humaness_check boolean) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM filterlist WHERE grp = 'csam' AND target_type = 'pubkey' AND target = a_pubkey AND blocked LIMIT 1) THEN
        RETURN;
    END IF;

    RETURN QUERY SELECT * FROM enrich_feed_events(
        ARRAY (
            select (pe.event_id, pe.created_at)::post
            from pubkey_events pe
            where pe.pubkey = a_pubkey and pe.created_at >= a_since and pe.created_at <= a_until and pe.is_reply = a_include_replies
            order by pe.created_at desc limit a_limit offset a_offset
        ),
        a_user_pubkey, a_apply_humaness_check);
END
$$;



CREATE FUNCTION public.feed_user_follows(a_pubkey bytea, a_since bigint, a_until bigint, a_include_replies bigint, a_limit bigint, a_offset bigint, a_user_pubkey bytea, a_apply_humaness_check boolean) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
SELECT * FROM enrich_feed_events(
    ARRAY (
        SELECT r
        FROM user_follows_posts(
            a_pubkey,
            a_since,
            a_until,
            a_include_replies,
            a_limit,
            a_offset) r),
    a_user_pubkey, a_apply_humaness_check)
$$;



CREATE FUNCTION public.get_bookmarks(a_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
SELECT get_event_jsonb(event_id) FROM bookmarks WHERE pubkey = a_pubkey;
$$;





CREATE TABLE public.event (
    id bytea NOT NULL,
    pubkey bytea NOT NULL,
    created_at bigint NOT NULL,
    kind bigint NOT NULL,
    tags jsonb NOT NULL,
    content text NOT NULL,
    sig bytea NOT NULL,
    imported_at bigint NOT NULL
);



CREATE FUNCTION public.get_event(a_event_id bytea) RETURNS public.event
    LANGUAGE sql STABLE
    AS $$
SELECT
	*
FROM
	events
WHERE
	events.id = a_event_id
LIMIT
	1
$$;



CREATE FUNCTION public.get_event_jsonb(a_event_id bytea) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
SELECT
	jsonb_build_object(
		'id', ENCODE(id, 'hex'), 
		'pubkey', ENCODE(pubkey, 'hex'),
		'created_at', created_at,
		'kind', kind, 
		'tags', tags, 
		'content', content::text,
		'sig', ENCODE(sig, 'hex'))
FROM
	events
WHERE
	events.id = a_event_id
LIMIT
	1
$$;



CREATE FUNCTION public.humaness_threshold_trustrank() RETURNS real
    LANGUAGE sql STABLE
    AS $$select rank from pubkey_trustrank order by rank desc limit 1 offset 50000$$;



CREATE FUNCTION public.is_event_hidden(a_user_pubkey bytea, a_scope public.cmr_scope, a_event_id bytea) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
SELECT EXISTS (SELECT 1 FROM events WHERE events.id = a_event_id AND is_pubkey_hidden(a_user_pubkey, a_scope, events.pubkey))
$$;



CREATE FUNCTION public.is_pubkey_hidden(a_user_pubkey bytea, a_scope public.cmr_scope, a_pubkey bytea) RETURNS boolean
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM cmr_pubkeys_allowed
        WHERE user_pubkey = a_user_pubkey AND pubkey = a_pubkey
    ) THEN
        RETURN false;
    END IF;

    IF EXISTS (
        SELECT 1 FROM cmr_pubkeys_scopes
        WHERE user_pubkey = a_user_pubkey AND pubkey = a_pubkey AND scope = a_scope
    ) THEN
        RETURN true;
    END IF;

    IF EXISTS (
        SELECT 1 FROM lists
        WHERE pubkey = a_pubkey AND list = 'spam_block'
    ) THEN
        RETURN true;
    END IF;

    RETURN 
        is_pubkey_hidden_by_group(a_user_pubkey, a_scope, a_pubkey, 'primal_spam', 'spam') OR
        is_pubkey_hidden_by_group(a_user_pubkey, a_scope, a_pubkey, 'primal_nsfw', 'nsfw');
END
$$;



CREATE FUNCTION public.is_pubkey_hidden_by_group(a_user_pubkey bytea, a_scope public.cmr_scope, a_pubkey bytea, a_cmr_grp public.cmr_grp, a_fl_grp public.filterlist_grp) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
SELECT
    EXISTS (
        SELECT 1 FROM cmr_groups cmr, filterlist_pubkey fl
        WHERE 
            cmr.user_pubkey = a_user_pubkey AND cmr.grp = a_cmr_grp AND cmr.scope = a_scope AND 
            fl.pubkey = a_pubkey AND fl.blocked AND fl.grp = a_fl_grp AND
            NOT EXISTS (SELECT 1 FROM filterlist_pubkey fl2 WHERE fl2.pubkey = a_pubkey AND NOT fl2.blocked))
$$;



CREATE FUNCTION public.long_form_content_feed(a_pubkey bytea DEFAULT NULL::bytea, a_notes character varying DEFAULT 'follows'::character varying, a_topic character varying DEFAULT NULL::character varying, a_curation character varying DEFAULT NULL::character varying, a_minwords bigint DEFAULT 0, a_limit bigint DEFAULT 20, a_since bigint DEFAULT 0, a_until bigint DEFAULT (EXTRACT(epoch FROM now()))::bigint, a_offset bigint DEFAULT 0, a_user_pubkey bytea DEFAULT NULL::bytea, a_apply_humaness_check boolean DEFAULT false) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
	posts post[];
BEGIN
    IF a_limit >= 1000 THEN
        RAISE EXCEPTION 'limit too big';
    END IF;

    IF a_curation IS NOT NULL and a_pubkey IS NOT NULL THEN
        posts := ARRAY (select distinct r.p FROM (
            select 
                (reads.latest_eid, reads.published_at)::post as p
            from 
                parametrized_replaceable_events pre,
                a_tags at,
                reads
            where 
                pre.pubkey = a_pubkey and pre.identifier = a_curation and pre.kind = 30004 and
                pre.event_id = at.eid and 
                at.ref_kind = 30023 and at.ref_pubkey = reads.pubkey and at.ref_identifier = reads.identifier and
                reads.published_at >= a_since and reads.published_at <= a_until and
                reads.words >= a_minwords
            order by reads.published_at desc limit a_limit offset a_offset) r);
    ELSIF a_pubkey IS NULL THEN
        posts := ARRAY (select distinct r.p FROM (
            select (latest_eid, published_at)::post as p
            from reads
            where 
                published_at >= a_since and published_at <= a_until and
                words >= a_minwords
                and (a_topic is null or topics @@ plainto_tsquery('simple', replace(a_topic, ' ', '-')))
            order by published_at desc limit a_limit offset a_offset) r);
    ELSIF a_notes = 'zappedbyfollows' THEN
        posts := ARRAY (select distinct r.p FROM (
            select (rs.latest_eid, rs.published_at)::post as p
            from pubkey_followers pf, reads rs, reads_versions rv, zap_receipts zr
            where 
                pf.follower_pubkey = a_pubkey and 
                pf.pubkey = zr.sender and zr.target_eid = rv.eid and
                rv.pubkey = rs.pubkey and rv.identifier = rs.identifier and
                rs.published_at >= a_since and rs.published_at <= a_until and
                rs.words >= a_minwords
            order by rs.published_at desc limit a_limit offset a_offset) r);
    ELSE
        IF a_notes = 'follows' AND EXISTS (select 1 from pubkey_followers pf where pf.follower_pubkey = a_pubkey limit 1) THEN
            posts := ARRAY (select distinct r.p FROM (
                select (reads.latest_eid, reads.published_at)::post as p
                from reads, pubkey_followers pf
                where 
                    pf.follower_pubkey = a_pubkey and pf.pubkey = reads.pubkey and 
                    reads.published_at >= a_since and reads.published_at <= a_until and
                    reads.words >= a_minwords
                    and (a_topic is null or reads.topics @@ plainto_tsquery('simple', replace(a_topic, ' ', '-')))
                order by reads.published_at desc limit a_limit offset a_offset) r);
        ELSIF a_notes = 'authored' THEN
            posts := ARRAY (select distinct r.p FROM (
                select (reads.latest_eid, reads.published_at)::post as p
                from reads
                where 
                    reads.pubkey = a_pubkey and 
                    reads.published_at >= a_since and reads.published_at <= a_until and
                    reads.words >= a_minwords
                    and (a_topic is null or topics @@ plainto_tsquery('simple', replace(a_topic, ' ', '-')))
                order by published_at desc limit a_limit offset a_offset) r);
        ELSE
            RAISE EXCEPTION 'unsupported type of notes';
        END IF;
    END IF;

    RETURN QUERY SELECT * FROM enrich_feed_events(posts, a_user_pubkey, a_apply_humaness_check, 'published_at');
END
$$;



CREATE FUNCTION public.notification_is_hidden(type bigint, arg1 bytea, arg2 bytea) RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$
SELECT 
    CASE type
    WHEN 1 THEN user_is_human(arg1)
    WHEN 2 THEN user_is_human(arg1)

    WHEN 3 THEN user_is_human(arg2)
    WHEN 4 THEN user_is_human(arg2)
    WHEN 5 THEN user_is_human(arg2)
    WHEN 6 THEN user_is_human(arg2)

    WHEN 7 THEN user_is_human(arg2)
    /* WHEN 8 THEN user_is_human(arg3) */

    WHEN 101 THEN user_is_human(arg2)
    WHEN 102 THEN user_is_human(arg2)
    WHEN 103 THEN user_is_human(arg2)
    WHEN 104 THEN user_is_human(arg2)

    /* WHEN 201 THEN user_is_human(arg3) */
    /* WHEN 202 THEN user_is_human(arg3) */
    /* WHEN 203 THEN user_is_human(arg3) */
    /* WHEN 204 THEN user_is_human(arg3) */
    END CASE
$$;



CREATE FUNCTION public.notification_is_visible(type bigint, arg1 bytea, arg2 bytea) RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$
SELECT
    CASE type
    WHEN 1 THEN user_is_human(arg1)
    WHEN 2 THEN user_is_human(arg1)

    WHEN 3 THEN user_is_human(arg2)
    WHEN 4 THEN user_is_human(arg2)
    WHEN 5 THEN user_is_human(arg2)
    WHEN 6 THEN user_is_human(arg2)

    WHEN 7 THEN user_is_human(arg2)
    /* WHEN 8 THEN user_is_human(arg3) */

    WHEN 101 THEN user_is_human(arg2)
    WHEN 102 THEN user_is_human(arg2)
    WHEN 103 THEN user_is_human(arg2)
    WHEN 104 THEN user_is_human(arg2)

    /* WHEN 201 THEN user_is_human(arg3) */
    /* WHEN 202 THEN user_is_human(arg3) */
    /* WHEN 203 THEN user_is_human(arg3) */
    /* WHEN 204 THEN user_is_human(arg3) */
    END CASE
$$;



CREATE FUNCTION public.notification_is_visible(type bigint, arg1 bytea, arg2 bytea, a_user_pubkey bytea) RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$
SELECT
    CASE type
    WHEN 1 THEN user_is_human(arg1, a_user_pubkey)
    WHEN 2 THEN user_is_human(arg1, a_user_pubkey)

    WHEN 3 THEN user_is_human(arg2, a_user_pubkey)
    WHEN 4 THEN user_is_human(arg2, a_user_pubkey)
    WHEN 5 THEN user_is_human(arg2, a_user_pubkey)
    WHEN 6 THEN user_is_human(arg2, a_user_pubkey)

    WHEN 7 THEN user_is_human(arg2, a_user_pubkey)
    /* WHEN 8 THEN user_is_human(arg3, a_user_pubkey) */

    WHEN 101 THEN user_is_human(arg2, a_user_pubkey)
    WHEN 102 THEN user_is_human(arg2, a_user_pubkey)
    WHEN 103 THEN user_is_human(arg2, a_user_pubkey)
    WHEN 104 THEN user_is_human(arg2, a_user_pubkey)

    /* WHEN 201 THEN user_is_human(arg3, a_user_pubkey) */
    /* WHEN 202 THEN user_is_human(arg3, a_user_pubkey) */
    /* WHEN 203 THEN user_is_human(arg3, a_user_pubkey) */
    /* WHEN 204 THEN user_is_human(arg3, a_user_pubkey) */
    END CASE
$$;



CREATE FUNCTION public.primal_verified_names(a_pubkeys bytea[]) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    r jsonb;
BEGIN
    SELECT json_object_agg(ENCODE(pubkey, 'hex'), name) INTO r FROM verified_users WHERE pubkey = ANY(a_pubkeys) and default_name;
    IF r IS NOT NULL THEN
        RETURN NEXT jsonb_build_object('kind', c_USER_PRIMAL_NAMES(), 'content', r::text);
    END IF;

    SELECT json_object_agg(
        ENCODE(pubkey, 'hex'), 
        jsonb_build_object('style', style, 'custom_badge', custom_badge, 'avatar_glow', avatar_glow))
    INTO r FROM membership_legend_customization WHERE pubkey = ANY(a_pubkeys);
    IF r IS NOT NULL THEN
        RETURN NEXT jsonb_build_object('kind', c_MEMBERSHIP_LEGEND_CUSTOMIZATION(), 'content', r::text);
    END IF;

    SELECT json_object_agg(
        ENCODE(pubkey, 'hex'), 
        jsonb_build_object('cohort_1', cohort_1, 'cohort_2', cohort_2, 'tier', tier, 'expires_on', extract(epoch from valid_until)::int8))
    INTO r FROM memberships WHERE pubkey = ANY(a_pubkeys) AND 
    (tier = 'premium' or tier = 'premium-legend')
    ;
    IF r IS NOT NULL THEN
        RETURN NEXT jsonb_build_object('kind', c_MEMBERSHIP_COHORTS(), 'content', r::text);
    END IF;
END
$$;



CREATE FUNCTION public.raise_notice(a text) RETURNS void
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
RAISE NOTICE '%', a;
END;
$$;



CREATE PROCEDURE public.record_trusted_pubkey_followers_cnt()
    LANGUAGE plpgsql
    AS $$
DECLARE
    t timestamp := NOW();
BEGIN
    WITH fc AS (
        SELECT 
            pf.pubkey, COUNT(1) as cnt
        FROM 
            pubkey_followers pf, pubkey_trustrank tr1, pubkey_trustrank tr2
        WHERE 
            pf.pubkey = tr1.pubkey AND tr1.rank > 0 AND user_has_bio(tr1.pubkey) AND
            pf.follower_pubkey = tr2.pubkey AND tr2.rank > 0
        GROUP BY pf.pubkey
    )
    INSERT INTO trusted_pubkey_followers_cnt
    SELECT t, fc.pubkey, fc.cnt
    FROM fc;
END
$$;



CREATE FUNCTION public.response_messages_for_post(a_event_id bytea, a_user_pubkey bytea, a_is_referenced_event boolean, a_depth bigint) RETURNS SETOF public.response_messages_for_post_res
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
	e event%ROWTYPE;
    eid bytea;
    pk bytea;
BEGIN
    IF a_depth = 0 THEN
        RETURN;
    END IF;

	e := get_event(a_event_id);

    IF EXISTS (
        SELECT 1 FROM pubkey_followers pf 
        WHERE pf.follower_pubkey = a_user_pubkey AND e.pubkey = pf.pubkey
    ) THEN
        -- user follows publisher
    ELSIF event_is_deleted(e.id) OR is_pubkey_hidden(a_user_pubkey, 'content', e.pubkey) THEN
        RETURN;
    END IF;

    DECLARE
        e_jsonb jsonb := get_event_jsonb(e.id);
    BEGIN
        IF e_jsonb IS null THEN
            RETURN;
        END IF;
        RETURN NEXT (e_jsonb, a_is_referenced_event);
    END;

	RETURN NEXT (get_event_jsonb(meta_data.value), false) FROM meta_data WHERE e.pubkey = meta_data.key;

    FOR eid IN 
        (
            SELECT arg1 FROM basic_tags WHERE id = a_event_id AND tag = 'e'
        ) UNION (
            SELECT argeid FROM event_mentions em WHERE em.eid = a_event_id AND tag = 'e'
        )
    LOOP
        RETURN QUERY SELECT * FROM response_messages_for_post(eid, a_user_pubkey, true, a_depth-1);
    END LOOP;

    FOR pk IN 
        (
            SELECT arg1 FROM basic_tags WHERE id = a_event_id AND tag in ('p', 'P')
        ) UNION (
            SELECT argpubkey FROM event_mentions em WHERE em.eid = a_event_id AND tag in ('p', 'P')
        )
    LOOP
        RETURN NEXT (get_event_jsonb(meta_data.value), false) FROM meta_data WHERE pk = meta_data.key;
    END LOOP;

    FOR eid IN 
        (
            SELECT pre.event_id 
            FROM a_tags at, parametrized_replaceable_events pre 
            WHERE at.eid = a_event_id AND at.ref_kind = pre.kind AND at.ref_pubkey = pre.pubkey AND at.ref_identifier = pre.identifier
        ) UNION (
            SELECT pre.event_id
            FROM event_mentions em, parametrized_replaceable_events pre 
            WHERE em.eid = a_event_id AND em.tag = 'a' AND em.argkind = pre.kind AND em.argpubkey = pre.pubkey AND em.argid = pre.identifier
        )
    LOOP
        RETURN QUERY SELECT * FROM response_messages_for_post(eid, a_user_pubkey, true, a_depth-1);
    END LOOP;
END;
$$;



CREATE FUNCTION public.safe_json(i text, fallback jsonb) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
BEGIN
    RETURN i::jsonb;
EXCEPTION
    WHEN others THEN
        RETURN fallback;
END;
$$;



CREATE FUNCTION public.safe_jsonb(data text) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
    AS $$
BEGIN
    RETURN data::jsonb;
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END;
$$;



CREATE FUNCTION public.test_pubkeys(a_name text) RETURNS bytea
    LANGUAGE sql
    AS $$ select pubkey from test_pubkeys where name = a_name $$;



CREATE FUNCTION public.thread_view(a_event_id bytea, a_limit bigint DEFAULT 20, a_since bigint DEFAULT 0, a_until bigint DEFAULT (EXTRACT(epoch FROM now()))::bigint, a_offset bigint DEFAULT 0, a_user_pubkey bytea DEFAULT NULL::bytea, a_apply_humaness_check boolean DEFAULT false) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    IF  EXISTS (SELECT 1 FROM filterlist WHERE grp = 'csam' AND target_type = 'event' AND target = a_event_id AND blocked LIMIT 1) OR
        EXISTS (SELECT 1 FROM events es, filterlist fl WHERE es.id = a_event_id AND fl.target = es.pubkey AND fl.target_type = 'pubkey' AND fl.grp = 'csam' AND fl.blocked LIMIT 1)
    THEN
        RETURN;
    END IF;
    IF NOT is_event_hidden(a_user_pubkey, 'content', a_event_id) AND NOT event_is_deleted(a_event_id) AND 
        NOT EXISTS (SELECT 1 FROM filterlist WHERE target = a_event_id AND target_type = 'event' AND grp = 'spam' AND blocked)
    THEN
        RETURN QUERY SELECT DISTINCT * FROM enrich_feed_events(
            ARRAY(SELECT r FROM thread_view_reply_posts(
                a_event_id, 
                a_limit, a_since, a_until, a_offset) r),
            a_user_pubkey, a_apply_humaness_check);
    END IF;

    RETURN QUERY SELECT DISTINCT * FROM enrich_feed_events(
        ARRAY(SELECT r FROM thread_view_parent_posts(a_event_id) r ORDER BY r.created_at), 
        a_user_pubkey, false);
END
$$;



CREATE FUNCTION public.thread_view_parent_posts(a_event_id bytea) RETURNS SETOF public.post
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    peid bytea := a_event_id;
BEGIN
    WHILE true LOOP
        RETURN QUERY SELECT peid, created_at FROM events WHERE id = peid;
        FOR peid IN SELECT value FROM event_thread_parents WHERE key = peid LOOP
        END LOOP;
        IF NOT FOUND THEN
            EXIT;
        END IF;
    END LOOP;
END
$$;



CREATE FUNCTION public.thread_view_reply_posts(a_event_id bytea, a_limit bigint DEFAULT 20, a_since bigint DEFAULT 0, a_until bigint DEFAULT (EXTRACT(epoch FROM now()))::bigint, a_offset bigint DEFAULT 0) RETURNS SETOF public.post
    LANGUAGE sql STABLE
    AS $$
select reply_event_id, reply_created_at from event_replies
where event_id = a_event_id and reply_created_at >= a_since and reply_created_at <= a_until
order by reply_created_at desc limit a_limit offset a_offset;
$$;



CREATE FUNCTION public.try_cast_jsonb(a_json text, a_default jsonb) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
    AS $$
BEGIN
  BEGIN
    RETURN a_json::jsonb;
  EXCEPTION
    WHEN OTHERS THEN
       RETURN a_default;
  END;
END;
$$;



CREATE FUNCTION public.update_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
   NEW.updated_at = now();
   RETURN NEW;
END; $$;



CREATE PROCEDURE public.update_user_relative_daily_follower_count_increases()
    LANGUAGE plpgsql
    AS $$
DECLARE
    ts1 timestamp;
    ts2 timestamp;
BEGIN
    SELECT t INTO ts2 FROM trusted_pubkey_followers_cnt ORDER BY t DESC LIMIT 1;
    /* SELECT t INTO ts1 FROM trusted_pubkey_followers_cnt ORDER BY t DESC LIMIT 1 OFFSET 1; */
    SELECT t INTO ts1 FROM trusted_pubkey_followers_cnt WHERE t < ts2 - INTERVAL '24h' ORDER BY t DESC LIMIT 1;
    /* SELECT t INTO ts1 FROM trusted_pubkey_followers_cnt WHERE t < ts2 - INTERVAL '3h' ORDER BY t DESC LIMIT 1; */

    CREATE TABLE IF NOT EXISTS daily_followers_cnt_increases (
        pubkey bytea not null, 
        cnt int8 not null, 
        increase int8 not null, 
        ratio float4 not null, 
        primary key (pubkey)
    );

    TRUNCATE daily_followers_cnt_increases;

    WITH 
        t1 AS (SELECT pubkey, cnt FROM trusted_pubkey_followers_cnt WHERE t = ts1),
        t2 AS (SELECT pubkey, cnt FROM trusted_pubkey_followers_cnt WHERE t = ts2)
    INSERT INTO daily_followers_cnt_increases 
        SELECT pubkey, cnt, dcnt, dcnt::float4/cnt AS relcnt FROM (
            SELECT t1.pubkey, t1.cnt, t2.cnt-t1.cnt AS dcnt 
            FROM t1, t2 
            WHERE t1.pubkey = t2.pubkey) a 
        WHERE dcnt > 0 ORDER BY relcnt DESC LIMIT 10000;

    COMMIT;
END
$$;



CREATE FUNCTION public.user_follows_posts(a_pubkey bytea, a_since bigint, a_until bigint, a_include_replies bigint, a_limit bigint, a_offset bigint) RETURNS SETOF public.post
    LANGUAGE sql STABLE
    AS $$
SELECT
	pe.event_id,
	pe.created_at
FROM
	pubkey_events pe,
	pubkey_followers pf
WHERE
	pf.follower_pubkey = a_pubkey AND
	pf.pubkey = pe.pubkey AND
	pe.created_at >= a_since AND
	pe.created_at <= a_until AND
	(
		pe.is_reply = 0 OR
		pe.is_reply = a_include_replies
	)
ORDER BY
	pe.created_at DESC
LIMIT
	a_limit
OFFSET
	a_offset
$$;



CREATE FUNCTION public.user_has_bio(a_pubkey bytea) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
SELECT coalesce(length(try_cast_jsonb(es.content::text, '{}')->>'about'), 0) > 0
FROM meta_data md, events es 
WHERE md.key = a_pubkey AND md.value = es.id
LIMIT 1
$$;



CREATE FUNCTION public.user_infos(a_pubkeys bytea[]) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    mdeid bytea;
    r jsonb;
BEGIN
    FOR mdeid IN SELECT value FROM meta_data WHERE key = ANY(a_pubkeys) LOOP
        RETURN NEXT get_event_jsonb(mdeid);
        RETURN QUERY SELECT * FROM event_media_response(mdeid);
        RETURN QUERY SELECT * FROM event_preview_response(mdeid);
    END LOOP;

    SELECT json_object_agg(ENCODE(key, 'hex'), value) INTO r FROM pubkey_followers_cnt WHERE key = ANY(a_pubkeys);
	RETURN NEXT jsonb_build_object('kind', c_USER_SCORES(), 'content', r::text);
	RETURN NEXT jsonb_build_object('kind', c_USER_FOLLOWER_COUNTS(), 'content', r::text);

    RETURN QUERY SELECT * FROM primal_verified_names(a_pubkeys);
END
$$;



CREATE FUNCTION public.user_infos(a_pubkeys text[]) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
SELECT * FROM user_infos(ARRAY (SELECT DECODE(UNNEST(a_pubkeys), 'hex')))
$$;



CREATE FUNCTION public.user_is_human(a_pubkey bytea) RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$
SELECT (
    EXISTS (SELECT 1 FROM pubkey_trustrank ptr WHERE ptr.pubkey = a_pubkey) OR
    EXISTS (SELECT 1 FROM human_override ho WHERE ho.pubkey = a_pubkey AND ho.is_human)
)
$$;



CREATE FUNCTION public.user_is_human(a_pubkey bytea, a_user_pubkey bytea) RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$
SELECT (
    EXISTS (SELECT 1 FROM pubkey_trustrank ptr WHERE ptr.pubkey = a_pubkey) OR
    EXISTS (SELECT 1 FROM human_override ho WHERE ho.pubkey = a_pubkey AND ho.is_human) OR
    EXISTS (SELECT 1 FROM pubkey_followers WHERE pubkey = a_pubkey AND follower_pubkey = a_user_pubkey)
)
$$;



CREATE FUNCTION public.wsconntasks(a_port bigint DEFAULT 14001) RETURNS TABLE(tokio_task bigint, task bigint, trace character varying)
    LANGUAGE sql STABLE
    AS $$
SELECT * FROM dblink(format('host=127.0.0.1 port=%s', a_port), 'select * from tasks;') AS t(tokio_task int8, task int8, trace varchar)
$$;



CREATE FUNCTION public.zap_response(r record, a_user_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$	
DECLARE
    pk bytea;
BEGIN
    IF (a_user_pubkey IS NOT null AND is_pubkey_hidden(a_user_pubkey, 'content', r.sender)) OR
        is_pubkey_hidden(r.receiver, 'content', r.sender) 
    THEN
        RETURN;
    END IF;

    FOR pk IN VALUES (r.sender), (r.receiver) LOOP
        RETURN NEXT get_event_jsonb(meta_data.value) FROM meta_data WHERE pk = meta_data.key;
    END LOOP;

    RETURN NEXT get_event_jsonb(r.zap_receipt_id);

    RETURN NEXT jsonb_build_object(
        'kind', c_ZAP_EVENT(),
        'content', json_build_object( 
            'event_id', ENCODE(r.event_id, 'hex'), 
            'created_at', r.created_at, 
            'sender', ENCODE(r.sender, 'hex'),
            'receiver', ENCODE(r.receiver, 'hex'),
            'amount_sats', r.amount_sats,
            'zap_receipt_id', ENCODE(r.zap_receipt_id, 'hex'))::text);
END $$;



CREATE TABLE public.a_tags_1_7d98c5333f (
    i bigint NOT NULL,
    eid bytea NOT NULL,
    kind bigint NOT NULL,
    created_at bigint NOT NULL,
    ref_kind bigint NOT NULL,
    ref_pubkey bytea NOT NULL,
    ref_identifier character varying NOT NULL,
    ref_arg4 character varying NOT NULL,
    imported_at bigint NOT NULL
);



CREATE VIEW public.a_tags AS
 SELECT a_tags_1_7d98c5333f.i,
    a_tags_1_7d98c5333f.eid,
    a_tags_1_7d98c5333f.kind,
    a_tags_1_7d98c5333f.created_at,
    a_tags_1_7d98c5333f.ref_kind,
    a_tags_1_7d98c5333f.ref_pubkey,
    a_tags_1_7d98c5333f.ref_identifier,
    a_tags_1_7d98c5333f.ref_arg4,
    a_tags_1_7d98c5333f.imported_at
   FROM public.a_tags_1_7d98c5333f;



CREATE SEQUENCE public.a_tags_1_7d98c5333f_i_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;



ALTER SEQUENCE public.a_tags_1_7d98c5333f_i_seq OWNED BY public.a_tags_1_7d98c5333f.i;



CREATE TABLE public.advsearch_5_d7da6f551e (
    i bigint NOT NULL,
    id bytea,
    pubkey bytea NOT NULL,
    created_at bigint NOT NULL,
    kind bigint NOT NULL,
    content_tsv tsvector NOT NULL,
    hashtag_tsv tsvector NOT NULL,
    reply_tsv tsvector NOT NULL,
    mention_tsv tsvector NOT NULL,
    filter_tsv tsvector NOT NULL,
    url_tsv tsvector NOT NULL
);



CREATE VIEW public.advsearch AS
 SELECT advsearch_5_d7da6f551e.i,
    advsearch_5_d7da6f551e.id,
    advsearch_5_d7da6f551e.pubkey,
    advsearch_5_d7da6f551e.created_at,
    advsearch_5_d7da6f551e.kind,
    advsearch_5_d7da6f551e.content_tsv,
    advsearch_5_d7da6f551e.hashtag_tsv,
    advsearch_5_d7da6f551e.reply_tsv,
    advsearch_5_d7da6f551e.mention_tsv,
    advsearch_5_d7da6f551e.filter_tsv,
    advsearch_5_d7da6f551e.url_tsv
   FROM public.advsearch_5_d7da6f551e;



CREATE SEQUENCE public.advsearch_5_d7da6f551e_i_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;



ALTER SEQUENCE public.advsearch_5_d7da6f551e_i_seq OWNED BY public.advsearch_5_d7da6f551e.i;



CREATE TABLE public.allow_list_1_f1da08e9c8 (
    key bytea NOT NULL,
    value bytea NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.allow_list AS
 SELECT allow_list_1_f1da08e9c8.key,
    allow_list_1_f1da08e9c8.value,
    allow_list_1_f1da08e9c8.rowid
   FROM public.allow_list_1_f1da08e9c8;



CREATE TABLE public.basic_tags_6_62c3d17c2f (
    i bigint NOT NULL,
    id bytea NOT NULL,
    pubkey bytea NOT NULL,
    created_at bigint NOT NULL,
    kind bigint NOT NULL,
    tag character(1) NOT NULL,
    arg1 bytea NOT NULL,
    arg3 character varying NOT NULL,
    imported_at bigint NOT NULL
);



CREATE VIEW public.basic_tags AS
 SELECT basic_tags_6_62c3d17c2f.i,
    basic_tags_6_62c3d17c2f.id,
    basic_tags_6_62c3d17c2f.pubkey,
    basic_tags_6_62c3d17c2f.created_at,
    basic_tags_6_62c3d17c2f.kind,
    basic_tags_6_62c3d17c2f.tag,
    basic_tags_6_62c3d17c2f.arg1,
    basic_tags_6_62c3d17c2f.arg3,
    basic_tags_6_62c3d17c2f.imported_at
   FROM public.basic_tags_6_62c3d17c2f;



CREATE SEQUENCE public.basic_tags_6_62c3d17c2f_i_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;



ALTER SEQUENCE public.basic_tags_6_62c3d17c2f_i_seq OWNED BY public.basic_tags_6_62c3d17c2f.i;



CREATE TABLE public.bookmarks_1_43f5248b56 (
    pubkey bytea NOT NULL,
    event_id bytea NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.bookmarks AS
 SELECT bookmarks_1_43f5248b56.pubkey,
    bookmarks_1_43f5248b56.event_id,
    bookmarks_1_43f5248b56.rowid
   FROM public.bookmarks_1_43f5248b56;



CREATE UNLOGGED TABLE public.cache (
    key text NOT NULL,
    value jsonb NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);



CREATE TABLE public.cmr_groups (
    user_pubkey bytea,
    grp public.cmr_grp NOT NULL,
    scope public.cmr_scope NOT NULL
);



CREATE TABLE public.cmr_pubkeys_allowed (
    user_pubkey bytea,
    pubkey bytea NOT NULL
);



CREATE TABLE public.cmr_pubkeys_parent (
    user_pubkey bytea,
    pubkey bytea NOT NULL,
    parent bytea NOT NULL
);



CREATE TABLE public.cmr_pubkeys_scopes (
    user_pubkey bytea,
    pubkey bytea NOT NULL,
    scope public.cmr_scope NOT NULL
);



CREATE TABLE public.contact_lists_1_1abdf474bd (
    key bytea NOT NULL,
    value bytea NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.contact_lists AS
 SELECT contact_lists_1_1abdf474bd.key,
    contact_lists_1_1abdf474bd.value,
    contact_lists_1_1abdf474bd.rowid
   FROM public.contact_lists_1_1abdf474bd;



CREATE TABLE public.coverages_1_8656fc443b (
    name character varying NOT NULL,
    t bigint NOT NULL,
    t2 bigint NOT NULL
);



CREATE TABLE public.dag_1_4bd2aaff98 (
    output character varying NOT NULL,
    input character varying NOT NULL
);



CREATE TABLE public.daily_followers_cnt_increases (
    pubkey bytea NOT NULL,
    cnt bigint NOT NULL,
    increase bigint NOT NULL,
    ratio real NOT NULL
);



CREATE TABLE public.deleted_events_1_0249f47b16 (
    event_id bytea NOT NULL,
    deletion_event_id bytea NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.deleted_events AS
 SELECT deleted_events_1_0249f47b16.event_id,
    deleted_events_1_0249f47b16.deletion_event_id,
    deleted_events_1_0249f47b16.rowid
   FROM public.deleted_events_1_0249f47b16;



CREATE TABLE public.dvm_feeds (
    pubkey bytea NOT NULL,
    identifier character varying NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    results jsonb,
    kind character varying NOT NULL,
    personalized boolean NOT NULL,
    ok boolean NOT NULL
);



CREATE TABLE public.event_attributes_1_3196ca546f (
    event_id bytea NOT NULL,
    key character varying NOT NULL,
    value bigint NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.event_attributes AS
 SELECT event_attributes_1_3196ca546f.event_id,
    event_attributes_1_3196ca546f.key,
    event_attributes_1_3196ca546f.value,
    event_attributes_1_3196ca546f.rowid
   FROM public.event_attributes_1_3196ca546f;



CREATE TABLE public.event_created_at_1_7a51e16c5c (
    event_id bytea NOT NULL,
    created_at bigint NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.event_created_at AS
 SELECT event_created_at_1_7a51e16c5c.event_id,
    event_created_at_1_7a51e16c5c.created_at,
    event_created_at_1_7a51e16c5c.rowid
   FROM public.event_created_at_1_7a51e16c5c;



CREATE TABLE public.event_hashtags_1_295f217c0e (
    event_id bytea NOT NULL,
    hashtag character varying NOT NULL,
    created_at bigint NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.event_hashtags AS
 SELECT event_hashtags_1_295f217c0e.event_id,
    event_hashtags_1_295f217c0e.hashtag,
    event_hashtags_1_295f217c0e.created_at,
    event_hashtags_1_295f217c0e.rowid
   FROM public.event_hashtags_1_295f217c0e;



CREATE TABLE public.event_hooks (
    event_id bytea NOT NULL,
    funcall text NOT NULL
);



CREATE TABLE public.event_media_1_30bf07e9cf (
    event_id bytea NOT NULL,
    url character varying NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.event_media AS
 SELECT event_media_1_30bf07e9cf.event_id,
    event_media_1_30bf07e9cf.url,
    event_media_1_30bf07e9cf.rowid
   FROM public.event_media_1_30bf07e9cf;



CREATE TABLE public.event_mentions_1_a056fb6737 (
    eid bytea NOT NULL,
    tag character(1) NOT NULL,
    argeid bytea,
    argpubkey bytea,
    argkind bigint,
    argid character varying
);



CREATE VIEW public.event_mentions AS
 SELECT event_mentions_1_a056fb6737.eid,
    event_mentions_1_a056fb6737.tag,
    event_mentions_1_a056fb6737.argeid,
    event_mentions_1_a056fb6737.argpubkey,
    event_mentions_1_a056fb6737.argkind,
    event_mentions_1_a056fb6737.argid
   FROM public.event_mentions_1_a056fb6737;



CREATE TABLE public.event_mentions_1_0b730615c4 (
    eid bytea NOT NULL,
    tag character(1) NOT NULL,
    argeid bytea,
    argpubkey bytea,
    argkind bigint,
    argid character varying
);



CREATE TABLE public.event_mentions_1_6738bfddaf (
    eid bytea NOT NULL,
    tag character(1) NOT NULL,
    argeid bytea NOT NULL,
    argpubkey bytea NOT NULL,
    argkind bigint NOT NULL,
    argid character varying NOT NULL
);



CREATE TABLE public.event_preview_1_310cef356e (
    event_id bytea NOT NULL,
    url character varying NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.event_preview AS
 SELECT event_preview_1_310cef356e.event_id,
    event_preview_1_310cef356e.url,
    event_preview_1_310cef356e.rowid
   FROM public.event_preview_1_310cef356e;



CREATE TABLE public.event_pubkey_action_refs_1_f32e1ff589 (
    event_id bytea NOT NULL,
    ref_event_id bytea NOT NULL,
    ref_pubkey bytea NOT NULL,
    ref_created_at bigint NOT NULL,
    ref_kind bigint NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.event_pubkey_action_refs AS
 SELECT event_pubkey_action_refs_1_f32e1ff589.event_id,
    event_pubkey_action_refs_1_f32e1ff589.ref_event_id,
    event_pubkey_action_refs_1_f32e1ff589.ref_pubkey,
    event_pubkey_action_refs_1_f32e1ff589.ref_created_at,
    event_pubkey_action_refs_1_f32e1ff589.ref_kind,
    event_pubkey_action_refs_1_f32e1ff589.rowid
   FROM public.event_pubkey_action_refs_1_f32e1ff589;



CREATE TABLE public.event_pubkey_actions_1_d62afee35d (
    event_id bytea NOT NULL,
    pubkey bytea NOT NULL,
    created_at bigint NOT NULL,
    updated_at bigint NOT NULL,
    replied bigint NOT NULL,
    liked bigint NOT NULL,
    reposted bigint NOT NULL,
    zapped bigint NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.event_pubkey_actions AS
 SELECT event_pubkey_actions_1_d62afee35d.event_id,
    event_pubkey_actions_1_d62afee35d.pubkey,
    event_pubkey_actions_1_d62afee35d.created_at,
    event_pubkey_actions_1_d62afee35d.updated_at,
    event_pubkey_actions_1_d62afee35d.replied,
    event_pubkey_actions_1_d62afee35d.liked,
    event_pubkey_actions_1_d62afee35d.reposted,
    event_pubkey_actions_1_d62afee35d.zapped,
    event_pubkey_actions_1_d62afee35d.rowid
   FROM public.event_pubkey_actions_1_d62afee35d;



CREATE TABLE public.event_relay (
    event_id bytea NOT NULL,
    relay_url text
);



CREATE TABLE public.event_replies_1_9d033b5bb3 (
    event_id bytea NOT NULL,
    reply_event_id bytea NOT NULL,
    reply_created_at bigint NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.event_replies AS
 SELECT event_replies_1_9d033b5bb3.event_id,
    event_replies_1_9d033b5bb3.reply_event_id,
    event_replies_1_9d033b5bb3.reply_created_at,
    event_replies_1_9d033b5bb3.rowid
   FROM public.event_replies_1_9d033b5bb3;



CREATE TABLE public.event_sentiment_1_d3d7a00a54 (
    eid bytea NOT NULL,
    model character varying NOT NULL,
    topsentiment character(1) NOT NULL,
    positive_prob double precision NOT NULL,
    negative_prob double precision NOT NULL,
    question_prob double precision NOT NULL,
    neutral_prob double precision NOT NULL,
    imported_at bigint NOT NULL
);



CREATE VIEW public.event_sentiment AS
 SELECT event_sentiment_1_d3d7a00a54.eid,
    event_sentiment_1_d3d7a00a54.model,
    event_sentiment_1_d3d7a00a54.topsentiment,
    event_sentiment_1_d3d7a00a54.positive_prob,
    event_sentiment_1_d3d7a00a54.negative_prob,
    event_sentiment_1_d3d7a00a54.question_prob,
    event_sentiment_1_d3d7a00a54.neutral_prob,
    event_sentiment_1_d3d7a00a54.imported_at
   FROM public.event_sentiment_1_d3d7a00a54;



CREATE TABLE public.event_stats_1_1b380f4869 (
    event_id bytea NOT NULL,
    author_pubkey bytea NOT NULL,
    created_at bigint NOT NULL,
    likes bigint NOT NULL,
    replies bigint NOT NULL,
    mentions bigint NOT NULL,
    reposts bigint NOT NULL,
    zaps bigint NOT NULL,
    satszapped bigint NOT NULL,
    score bigint NOT NULL,
    score24h bigint NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.event_stats AS
 SELECT event_stats_1_1b380f4869.event_id,
    event_stats_1_1b380f4869.author_pubkey,
    event_stats_1_1b380f4869.created_at,
    event_stats_1_1b380f4869.likes,
    event_stats_1_1b380f4869.replies,
    event_stats_1_1b380f4869.mentions,
    event_stats_1_1b380f4869.reposts,
    event_stats_1_1b380f4869.zaps,
    event_stats_1_1b380f4869.satszapped,
    event_stats_1_1b380f4869.score,
    event_stats_1_1b380f4869.score24h,
    event_stats_1_1b380f4869.rowid
   FROM public.event_stats_1_1b380f4869;



CREATE TABLE public.event_stats_by_pubkey_1_4ecc48a026 (
    event_id bytea NOT NULL,
    author_pubkey bytea NOT NULL,
    created_at bigint NOT NULL,
    likes bigint NOT NULL,
    replies bigint NOT NULL,
    mentions bigint NOT NULL,
    reposts bigint NOT NULL,
    zaps bigint NOT NULL,
    satszapped bigint NOT NULL,
    score bigint NOT NULL,
    score24h bigint NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.event_stats_by_pubkey AS
 SELECT event_stats_by_pubkey_1_4ecc48a026.event_id,
    event_stats_by_pubkey_1_4ecc48a026.author_pubkey,
    event_stats_by_pubkey_1_4ecc48a026.created_at,
    event_stats_by_pubkey_1_4ecc48a026.likes,
    event_stats_by_pubkey_1_4ecc48a026.replies,
    event_stats_by_pubkey_1_4ecc48a026.mentions,
    event_stats_by_pubkey_1_4ecc48a026.reposts,
    event_stats_by_pubkey_1_4ecc48a026.zaps,
    event_stats_by_pubkey_1_4ecc48a026.satszapped,
    event_stats_by_pubkey_1_4ecc48a026.score,
    event_stats_by_pubkey_1_4ecc48a026.score24h,
    event_stats_by_pubkey_1_4ecc48a026.rowid
   FROM public.event_stats_by_pubkey_1_4ecc48a026;



CREATE VIEW public.event_tags AS
 SELECT event.id,
    event.pubkey,
    event.kind,
    event.created_at,
    (jsonb_array_elements(event.tags) ->> 0) AS tag,
    (jsonb_array_elements(event.tags) ->> 1) AS arg1
   FROM public.event;



CREATE TABLE public.event_thread_parents_1_e17bf16c98 (
    key bytea NOT NULL,
    value bytea NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.event_thread_parents AS
 SELECT event_thread_parents_1_e17bf16c98.key,
    event_thread_parents_1_e17bf16c98.value,
    event_thread_parents_1_e17bf16c98.rowid
   FROM public.event_thread_parents_1_e17bf16c98;



CREATE TABLE public.event_zapped_1_7ebdbebf92 (
    event_id bytea NOT NULL,
    zap_sender bytea NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.event_zapped AS
 SELECT event_zapped_1_7ebdbebf92.event_id,
    event_zapped_1_7ebdbebf92.zap_sender,
    event_zapped_1_7ebdbebf92.rowid
   FROM public.event_zapped_1_7ebdbebf92;



CREATE VIEW public.events AS
 SELECT event.id,
    event.pubkey,
    event.created_at,
    event.kind,
    event.tags,
    event.content,
    event.sig,
    event.imported_at
   FROM public.event;



CREATE TABLE public.filterlist (
    target bytea NOT NULL,
    target_type public.filterlist_target NOT NULL,
    blocked boolean NOT NULL,
    grp public.filterlist_grp NOT NULL,
    added_at bigint,
    comment character varying
);



CREATE TABLE public.filterlist_pubkey (
    pubkey bytea NOT NULL,
    blocked boolean NOT NULL,
    grp public.filterlist_grp NOT NULL
);



CREATE TABLE public.hashtags_1_1e5c72161a (
    hashtag character varying NOT NULL,
    score bigint NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.hashtags AS
 SELECT hashtags_1_1e5c72161a.hashtag,
    hashtags_1_1e5c72161a.score,
    hashtags_1_1e5c72161a.rowid
   FROM public.hashtags_1_1e5c72161a;



CREATE TABLE public.human_override (
    pubkey bytea NOT NULL,
    is_human boolean,
    added_at timestamp without time zone DEFAULT now(),
    source character varying
);



CREATE TABLE public.lists (
    list character varying(200) NOT NULL,
    pubkey bytea NOT NULL,
    added_at integer NOT NULL
);



CREATE TABLE public.logs_1_d241bdb71c (
    t timestamp without time zone NOT NULL,
    module character varying NOT NULL,
    func character varying NOT NULL,
    type character varying NOT NULL,
    d jsonb NOT NULL
);



CREATE TABLE public.media_1_16fa35f2dc (
    url character varying NOT NULL,
    media_url character varying NOT NULL,
    size character varying NOT NULL,
    animated bigint NOT NULL,
    imported_at bigint NOT NULL,
    download_duration double precision NOT NULL,
    width bigint NOT NULL,
    height bigint NOT NULL,
    mimetype character varying NOT NULL,
    category character varying NOT NULL,
    category_confidence double precision NOT NULL,
    duration double precision NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.media AS
 SELECT media_1_16fa35f2dc.url,
    media_1_16fa35f2dc.media_url,
    media_1_16fa35f2dc.size,
    media_1_16fa35f2dc.animated,
    media_1_16fa35f2dc.imported_at,
    media_1_16fa35f2dc.download_duration,
    media_1_16fa35f2dc.width,
    media_1_16fa35f2dc.height,
    media_1_16fa35f2dc.mimetype,
    media_1_16fa35f2dc.category,
    media_1_16fa35f2dc.category_confidence,
    media_1_16fa35f2dc.duration,
    media_1_16fa35f2dc.rowid
   FROM public.media_1_16fa35f2dc;



CREATE TABLE public.media_storage (
    media_url character varying NOT NULL,
    storage_provider character varying NOT NULL,
    added_at bigint NOT NULL,
    key character varying NOT NULL,
    h character varying NOT NULL,
    ext character varying NOT NULL,
    content_type character varying NOT NULL,
    size bigint NOT NULL
);



CREATE TABLE public.membership_legend_customization (
    pubkey bytea NOT NULL,
    style character varying NOT NULL,
    custom_badge boolean NOT NULL,
    avatar_glow boolean NOT NULL
);



CREATE TABLE public.memberships (
    pubkey bytea,
    tier character varying(300),
    valid_until timestamp without time zone,
    name character varying(500),
    used_storage bigint,
    cohort_1 character varying,
    cohort_2 character varying,
    recurring boolean,
    created_at timestamp without time zone,
    platform_id character varying,
    class_id character varying,
    origin character varying
);



CREATE TABLE public.meta_data_1_323bc43167 (
    key bytea NOT NULL,
    value bytea NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.meta_data AS
 SELECT meta_data_1_323bc43167.key,
    meta_data_1_323bc43167.value,
    meta_data_1_323bc43167.rowid
   FROM public.meta_data_1_323bc43167;



CREATE TABLE public.mute_list_1_f693a878b9 (
    key bytea NOT NULL,
    value bytea NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.mute_list AS
 SELECT mute_list_1_f693a878b9.key,
    mute_list_1_f693a878b9.value,
    mute_list_1_f693a878b9.rowid
   FROM public.mute_list_1_f693a878b9;



CREATE TABLE public.mute_list_2_1_949b3d746b (
    key bytea NOT NULL,
    value bytea NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.mute_list_2 AS
 SELECT mute_list_2_1_949b3d746b.key,
    mute_list_2_1_949b3d746b.value,
    mute_list_2_1_949b3d746b.rowid
   FROM public.mute_list_2_1_949b3d746b;



CREATE TABLE public.mute_lists_1_d90e559628 (
    key bytea NOT NULL,
    value bytea NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.mute_lists AS
 SELECT mute_lists_1_d90e559628.key,
    mute_lists_1_d90e559628.value,
    mute_lists_1_d90e559628.rowid
   FROM public.mute_lists_1_d90e559628;



CREATE TABLE public.node_outputs_1_cfe6037c9f (
    output character varying NOT NULL,
    def jsonb NOT NULL
);



CREATE TABLE public.note_length_1_15d66ffae6 (
    eid bytea NOT NULL,
    length bigint NOT NULL
);



CREATE VIEW public.note_length AS
 SELECT note_length_1_15d66ffae6.eid,
    note_length_1_15d66ffae6.length
   FROM public.note_length_1_15d66ffae6;



CREATE TABLE public.note_stats_1_07d205f278 (
    eid bytea NOT NULL,
    long_replies bigint NOT NULL
);



CREATE VIEW public.note_stats AS
 SELECT note_stats_1_07d205f278.eid,
    note_stats_1_07d205f278.long_replies
   FROM public.note_stats_1_07d205f278;



CREATE TABLE public.og_zap_receipts_1_dc85307383 (
    zap_receipt_id bytea NOT NULL,
    created_at bigint NOT NULL,
    sender bytea NOT NULL,
    receiver bytea NOT NULL,
    amount_sats bigint NOT NULL,
    event_id bytea NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.og_zap_receipts AS
 SELECT og_zap_receipts_1_dc85307383.zap_receipt_id,
    og_zap_receipts_1_dc85307383.created_at,
    og_zap_receipts_1_dc85307383.sender,
    og_zap_receipts_1_dc85307383.receiver,
    og_zap_receipts_1_dc85307383.amount_sats,
    og_zap_receipts_1_dc85307383.event_id,
    og_zap_receipts_1_dc85307383.rowid
   FROM public.og_zap_receipts_1_dc85307383;



CREATE TABLE public.parameterized_replaceable_list_1_d02d7ecc62 (
    pubkey bytea NOT NULL,
    identifier character varying NOT NULL,
    created_at bigint NOT NULL,
    event_id bytea NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.parameterized_replaceable_list AS
 SELECT parameterized_replaceable_list_1_d02d7ecc62.pubkey,
    parameterized_replaceable_list_1_d02d7ecc62.identifier,
    parameterized_replaceable_list_1_d02d7ecc62.created_at,
    parameterized_replaceable_list_1_d02d7ecc62.event_id,
    parameterized_replaceable_list_1_d02d7ecc62.rowid
   FROM public.parameterized_replaceable_list_1_d02d7ecc62;



CREATE TABLE public.parametrized_replaceable_events_1_cbe75c8d53 (
    pubkey bytea NOT NULL,
    kind bigint NOT NULL,
    identifier character varying NOT NULL,
    event_id bytea NOT NULL,
    created_at bigint NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.parametrized_replaceable_events AS
 SELECT parametrized_replaceable_events_1_cbe75c8d53.pubkey,
    parametrized_replaceable_events_1_cbe75c8d53.kind,
    parametrized_replaceable_events_1_cbe75c8d53.identifier,
    parametrized_replaceable_events_1_cbe75c8d53.event_id,
    parametrized_replaceable_events_1_cbe75c8d53.created_at,
    parametrized_replaceable_events_1_cbe75c8d53.rowid
   FROM public.parametrized_replaceable_events_1_cbe75c8d53;



CREATE TABLE public.preview_1_44299731c7 (
    url character varying NOT NULL,
    imported_at bigint NOT NULL,
    download_duration double precision NOT NULL,
    mimetype character varying NOT NULL,
    category character varying NOT NULL,
    category_confidence double precision NOT NULL,
    md_title character varying NOT NULL,
    md_description character varying NOT NULL,
    md_image character varying NOT NULL,
    icon_url character varying NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.preview AS
 SELECT preview_1_44299731c7.url,
    preview_1_44299731c7.imported_at,
    preview_1_44299731c7.download_duration,
    preview_1_44299731c7.mimetype,
    preview_1_44299731c7.category,
    preview_1_44299731c7.category_confidence,
    preview_1_44299731c7.md_title,
    preview_1_44299731c7.md_description,
    preview_1_44299731c7.md_image,
    preview_1_44299731c7.icon_url,
    preview_1_44299731c7.rowid
   FROM public.preview_1_44299731c7;



CREATE TABLE public.pubkey_bookmarks (
    pubkey bytea NOT NULL,
    ref_event_id bytea,
    ref_kind bytea,
    ref_pubkey bytea,
    ref_identifier bytea
);



CREATE TABLE public.pubkey_content_zap_cnt_1_236df2f369 (
    pubkey bytea NOT NULL,
    cnt bigint NOT NULL
);



CREATE VIEW public.pubkey_content_zap_cnt AS
 SELECT pubkey_content_zap_cnt_1_236df2f369.pubkey,
    pubkey_content_zap_cnt_1_236df2f369.cnt
   FROM public.pubkey_content_zap_cnt_1_236df2f369;



CREATE TABLE public.pubkey_directmsgs_1_c794110a2c (
    receiver bytea NOT NULL,
    sender bytea NOT NULL,
    created_at bigint NOT NULL,
    event_id bytea NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.pubkey_directmsgs AS
 SELECT pubkey_directmsgs_1_c794110a2c.receiver,
    pubkey_directmsgs_1_c794110a2c.sender,
    pubkey_directmsgs_1_c794110a2c.created_at,
    pubkey_directmsgs_1_c794110a2c.event_id,
    pubkey_directmsgs_1_c794110a2c.rowid
   FROM public.pubkey_directmsgs_1_c794110a2c;



CREATE TABLE public.pubkey_directmsgs_cnt_1_efdf9742a6 (
    receiver bytea NOT NULL,
    sender bytea,
    cnt bigint NOT NULL,
    latest_at bigint NOT NULL,
    latest_event_id bytea NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.pubkey_directmsgs_cnt AS
 SELECT pubkey_directmsgs_cnt_1_efdf9742a6.receiver,
    pubkey_directmsgs_cnt_1_efdf9742a6.sender,
    pubkey_directmsgs_cnt_1_efdf9742a6.cnt,
    pubkey_directmsgs_cnt_1_efdf9742a6.latest_at,
    pubkey_directmsgs_cnt_1_efdf9742a6.latest_event_id,
    pubkey_directmsgs_cnt_1_efdf9742a6.rowid
   FROM public.pubkey_directmsgs_cnt_1_efdf9742a6;



CREATE TABLE public.pubkey_events_1_1dcbfe1466 (
    pubkey bytea NOT NULL,
    event_id bytea NOT NULL,
    created_at bigint NOT NULL,
    is_reply bigint NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.pubkey_events AS
 SELECT pubkey_events_1_1dcbfe1466.pubkey,
    pubkey_events_1_1dcbfe1466.event_id,
    pubkey_events_1_1dcbfe1466.created_at,
    pubkey_events_1_1dcbfe1466.is_reply,
    pubkey_events_1_1dcbfe1466.rowid
   FROM public.pubkey_events_1_1dcbfe1466;



CREATE TABLE public.pubkey_followers_1_d52305fb47 (
    pubkey bytea NOT NULL,
    follower_pubkey bytea NOT NULL,
    follower_contact_list_event_id bytea NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.pubkey_followers AS
 SELECT pubkey_followers_1_d52305fb47.pubkey,
    pubkey_followers_1_d52305fb47.follower_pubkey,
    pubkey_followers_1_d52305fb47.follower_contact_list_event_id,
    pubkey_followers_1_d52305fb47.rowid
   FROM public.pubkey_followers_1_d52305fb47;



CREATE TABLE public.pubkey_followers_cnt_1_a6f7e200e7 (
    key bytea NOT NULL,
    value bigint NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.pubkey_followers_cnt AS
 SELECT pubkey_followers_cnt_1_a6f7e200e7.key,
    pubkey_followers_cnt_1_a6f7e200e7.value,
    pubkey_followers_cnt_1_a6f7e200e7.rowid
   FROM public.pubkey_followers_cnt_1_a6f7e200e7;



CREATE TABLE public.pubkey_ids_1_54b55dd09c (
    key bytea NOT NULL,
    value bigint NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.pubkey_ids AS
 SELECT pubkey_ids_1_54b55dd09c.key,
    pubkey_ids_1_54b55dd09c.value,
    pubkey_ids_1_54b55dd09c.rowid
   FROM public.pubkey_ids_1_54b55dd09c;



CREATE TABLE public.pubkey_ln_address_1_d3649b2898 (
    pubkey bytea NOT NULL,
    ln_address character varying NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.pubkey_ln_address AS
 SELECT pubkey_ln_address_1_d3649b2898.pubkey,
    pubkey_ln_address_1_d3649b2898.ln_address,
    pubkey_ln_address_1_d3649b2898.rowid
   FROM public.pubkey_ln_address_1_d3649b2898;



CREATE TABLE public.pubkey_media_cnt_1_b5e2a488b1 (
    pubkey bytea NOT NULL,
    cnt bigint NOT NULL
);



CREATE VIEW public.pubkey_media_cnt AS
 SELECT pubkey_media_cnt_1_b5e2a488b1.pubkey,
    pubkey_media_cnt_1_b5e2a488b1.cnt
   FROM public.pubkey_media_cnt_1_b5e2a488b1;



CREATE TABLE public.pubkey_notification_cnts_1_d78f6fcade (
    pubkey bytea NOT NULL,
    type1 bigint DEFAULT 0,
    type2 bigint DEFAULT 0,
    type3 bigint DEFAULT 0,
    type4 bigint DEFAULT 0,
    type5 bigint DEFAULT 0,
    type6 bigint DEFAULT 0,
    type7 bigint DEFAULT 0,
    type8 bigint DEFAULT 0,
    type101 bigint DEFAULT 0,
    type102 bigint DEFAULT 0,
    type103 bigint DEFAULT 0,
    type104 bigint DEFAULT 0,
    type201 bigint DEFAULT 0,
    type202 bigint DEFAULT 0,
    type203 bigint DEFAULT 0,
    type204 bigint DEFAULT 0,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.pubkey_notification_cnts AS
 SELECT pubkey_notification_cnts_1_d78f6fcade.pubkey,
    pubkey_notification_cnts_1_d78f6fcade.type1,
    pubkey_notification_cnts_1_d78f6fcade.type2,
    pubkey_notification_cnts_1_d78f6fcade.type3,
    pubkey_notification_cnts_1_d78f6fcade.type4,
    pubkey_notification_cnts_1_d78f6fcade.type5,
    pubkey_notification_cnts_1_d78f6fcade.type6,
    pubkey_notification_cnts_1_d78f6fcade.type7,
    pubkey_notification_cnts_1_d78f6fcade.type8,
    pubkey_notification_cnts_1_d78f6fcade.type101,
    pubkey_notification_cnts_1_d78f6fcade.type102,
    pubkey_notification_cnts_1_d78f6fcade.type103,
    pubkey_notification_cnts_1_d78f6fcade.type104,
    pubkey_notification_cnts_1_d78f6fcade.type201,
    pubkey_notification_cnts_1_d78f6fcade.type202,
    pubkey_notification_cnts_1_d78f6fcade.type203,
    pubkey_notification_cnts_1_d78f6fcade.type204,
    pubkey_notification_cnts_1_d78f6fcade.rowid
   FROM public.pubkey_notification_cnts_1_d78f6fcade;



CREATE TABLE public.pubkey_notifications_1_e5459ab9dd (
    pubkey bytea NOT NULL,
    created_at bigint NOT NULL,
    type bigint NOT NULL,
    arg1 bytea NOT NULL,
    arg2 bytea,
    arg3 jsonb,
    arg4 jsonb,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.pubkey_notifications AS
 SELECT pubkey_notifications_1_e5459ab9dd.pubkey,
    pubkey_notifications_1_e5459ab9dd.created_at,
    pubkey_notifications_1_e5459ab9dd.type,
    pubkey_notifications_1_e5459ab9dd.arg1,
    pubkey_notifications_1_e5459ab9dd.arg2,
    pubkey_notifications_1_e5459ab9dd.arg3,
    pubkey_notifications_1_e5459ab9dd.arg4,
    pubkey_notifications_1_e5459ab9dd.rowid
   FROM public.pubkey_notifications_1_e5459ab9dd;



CREATE TABLE public.pubkey_trustrank (
    pubkey bytea NOT NULL,
    rank double precision NOT NULL
);



CREATE TABLE public.pubkey_zapped_1_17f1f622a9 (
    pubkey bytea NOT NULL,
    zaps bigint NOT NULL,
    satszapped bigint NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.pubkey_zapped AS
 SELECT pubkey_zapped_1_17f1f622a9.pubkey,
    pubkey_zapped_1_17f1f622a9.zaps,
    pubkey_zapped_1_17f1f622a9.satszapped,
    pubkey_zapped_1_17f1f622a9.rowid
   FROM public.pubkey_zapped_1_17f1f622a9;



CREATE TABLE public.reads_12_68c6bbfccd (
    pubkey bytea NOT NULL,
    identifier character varying NOT NULL,
    published_at bigint NOT NULL,
    latest_eid bytea NOT NULL,
    latest_created_at bigint NOT NULL,
    likes bigint NOT NULL,
    zaps bigint NOT NULL,
    satszapped bigint NOT NULL,
    replies bigint NOT NULL,
    reposts bigint NOT NULL,
    topics tsvector NOT NULL,
    words bigint NOT NULL,
    lang character varying NOT NULL,
    lang_prob double precision NOT NULL,
    image character varying NOT NULL,
    summary character varying NOT NULL
);



CREATE VIEW public.reads AS
 SELECT reads_12_68c6bbfccd.pubkey,
    reads_12_68c6bbfccd.identifier,
    reads_12_68c6bbfccd.published_at,
    reads_12_68c6bbfccd.latest_eid,
    reads_12_68c6bbfccd.latest_created_at,
    reads_12_68c6bbfccd.likes,
    reads_12_68c6bbfccd.zaps,
    reads_12_68c6bbfccd.satszapped,
    reads_12_68c6bbfccd.replies,
    reads_12_68c6bbfccd.reposts,
    reads_12_68c6bbfccd.topics,
    reads_12_68c6bbfccd.words,
    reads_12_68c6bbfccd.lang,
    reads_12_68c6bbfccd.lang_prob,
    reads_12_68c6bbfccd.image,
    reads_12_68c6bbfccd.summary
   FROM public.reads_12_68c6bbfccd;



CREATE TABLE public.reads_11_2a4d2ce519 (
    pubkey bytea NOT NULL,
    identifier character varying NOT NULL,
    published_at bigint NOT NULL,
    latest_eid bytea NOT NULL,
    latest_created_at bigint NOT NULL,
    likes bigint NOT NULL,
    zaps bigint NOT NULL,
    satszapped bigint NOT NULL,
    replies bigint NOT NULL,
    reposts bigint NOT NULL,
    topics tsvector NOT NULL,
    words bigint NOT NULL,
    lang character varying NOT NULL,
    lang_prob double precision NOT NULL
);



CREATE TABLE public.reads_versions_12_b537d4df66 (
    pubkey bytea NOT NULL,
    identifier character varying NOT NULL,
    eid bytea NOT NULL
);



CREATE VIEW public.reads_versions AS
 SELECT reads_versions_12_b537d4df66.pubkey,
    reads_versions_12_b537d4df66.identifier,
    reads_versions_12_b537d4df66.eid
   FROM public.reads_versions_12_b537d4df66;



CREATE TABLE public.reads_versions_11_fb53a8e0b4 (
    pubkey bytea NOT NULL,
    identifier character varying NOT NULL,
    eid bytea NOT NULL
);



CREATE TABLE public.relay_list_metadata_1_801a17fc93 (
    pubkey bytea NOT NULL,
    event_id bytea NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.relay_list_metadata AS
 SELECT relay_list_metadata_1_801a17fc93.pubkey,
    relay_list_metadata_1_801a17fc93.event_id,
    relay_list_metadata_1_801a17fc93.rowid
   FROM public.relay_list_metadata_1_801a17fc93;



CREATE TABLE public.relay_url_map (
    src character varying NOT NULL,
    dest character varying NOT NULL
);



CREATE TABLE public.relays (
    url text NOT NULL,
    times_referenced bigint NOT NULL
);



CREATE TABLE public.scheduled_hooks (
    execute_at bigint NOT NULL,
    funcall text NOT NULL
);



CREATE TABLE public.score_expiry (
    event_id bytea NOT NULL,
    author_pubkey bytea NOT NULL,
    change bigint NOT NULL,
    expire_at bigint NOT NULL
);



CREATE TABLE public.stuff (
    data text NOT NULL,
    created_at bigint NOT NULL
);



CREATE TABLE public.test_pubkeys (
    name character varying NOT NULL,
    pubkey bytea NOT NULL
);



CREATE TABLE public.trelays (
    relay_url text,
    cnt bigint
);



CREATE TABLE public.trusted_pubkey_followers_cnt (
    t timestamp without time zone NOT NULL,
    pubkey bytea NOT NULL,
    cnt bigint NOT NULL
);



CREATE VIEW public.trusted_users_trusted_followers AS
 SELECT pf.pubkey,
    tr1.rank AS pubkey_rank,
    pf.follower_pubkey,
    tr2.rank AS follower_pubkey_rank
   FROM public.pubkey_followers pf,
    public.pubkey_trustrank tr1,
    public.pubkey_trustrank tr2
  WHERE ((pf.pubkey = tr1.pubkey) AND (pf.follower_pubkey = tr2.pubkey));



CREATE TABLE public.user_search (
    pubkey bytea NOT NULL,
    event_id bytea NOT NULL,
    name tsvector,
    username tsvector,
    display_name tsvector,
    displayname tsvector,
    nip05 tsvector,
    lud16 tsvector
);



CREATE TABLE public.vars (
    name character varying NOT NULL,
    value jsonb
);



CREATE TABLE public.verified_users (
    name character varying(200) NOT NULL,
    pubkey bytea NOT NULL,
    default_name boolean NOT NULL,
    added_at timestamp without time zone
);

ALTER TABLE ONLY public.verified_users REPLICA IDENTITY FULL;



CREATE TABLE public.video_thumbnails_1_107d5a46eb (
    video_url character varying NOT NULL,
    thumbnail_url character varying NOT NULL,
    rowid bigint DEFAULT 0
);



CREATE VIEW public.video_thumbnails AS
 SELECT video_thumbnails_1_107d5a46eb.video_url,
    video_thumbnails_1_107d5a46eb.thumbnail_url,
    video_thumbnails_1_107d5a46eb.rowid
   FROM public.video_thumbnails_1_107d5a46eb;



CREATE UNLOGGED TABLE public.wsconnlog (
    t timestamp without time zone NOT NULL,
    run bigint NOT NULL,
    task bigint NOT NULL,
    tokio_task bigint NOT NULL,
    info jsonb NOT NULL,
    func character varying,
    conn bigint
);



CREATE TABLE public.wsconnruns (
    run bigint NOT NULL,
    tstart timestamp without time zone NOT NULL,
    servername character varying NOT NULL,
    port bigint NOT NULL
);



CREATE SEQUENCE public.wsconnruns_run_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;



ALTER SEQUENCE public.wsconnruns_run_seq OWNED BY public.wsconnruns.run;



CREATE TABLE public.wsconnvars (
    name character varying NOT NULL,
    value jsonb NOT NULL
);



CREATE TABLE public.zap_receipts_1_9fe40119b2 (
    eid bytea NOT NULL,
    created_at bigint NOT NULL,
    target_eid bytea NOT NULL,
    sender bytea NOT NULL,
    receiver bytea NOT NULL,
    satszapped bigint NOT NULL,
    imported_at bigint NOT NULL
);



CREATE VIEW public.zap_receipts AS
 SELECT zap_receipts_1_9fe40119b2.eid,
    zap_receipts_1_9fe40119b2.created_at,
    zap_receipts_1_9fe40119b2.target_eid,
    zap_receipts_1_9fe40119b2.sender,
    zap_receipts_1_9fe40119b2.receiver,
    zap_receipts_1_9fe40119b2.satszapped,
    zap_receipts_1_9fe40119b2.imported_at
   FROM public.zap_receipts_1_9fe40119b2;



ALTER TABLE ONLY public.a_tags_1_7d98c5333f ALTER COLUMN i SET DEFAULT nextval('public.a_tags_1_7d98c5333f_i_seq'::regclass);



ALTER TABLE ONLY public.advsearch_5_d7da6f551e ALTER COLUMN i SET DEFAULT nextval('public.advsearch_5_d7da6f551e_i_seq'::regclass);



ALTER TABLE ONLY public.basic_tags_6_62c3d17c2f ALTER COLUMN i SET DEFAULT nextval('public.basic_tags_6_62c3d17c2f_i_seq'::regclass);



ALTER TABLE ONLY public.wsconnruns ALTER COLUMN run SET DEFAULT nextval('public.wsconnruns_run_seq'::regclass);



ALTER TABLE ONLY public.a_tags_1_7d98c5333f
    ADD CONSTRAINT a_tags_1_7d98c5333f_eid_ref_kind_ref_pubkey_ref_identifier__key UNIQUE (eid, ref_kind, ref_pubkey, ref_identifier, ref_arg4);



ALTER TABLE ONLY public.a_tags_1_7d98c5333f
    ADD CONSTRAINT a_tags_1_7d98c5333f_pkey PRIMARY KEY (i);



ALTER TABLE ONLY public.advsearch_5_d7da6f551e
    ADD CONSTRAINT advsearch_5_d7da6f551e_id_key UNIQUE (id);



ALTER TABLE ONLY public.advsearch_5_d7da6f551e
    ADD CONSTRAINT advsearch_5_d7da6f551e_pkey PRIMARY KEY (i);



ALTER TABLE ONLY public.allow_list_1_f1da08e9c8
    ADD CONSTRAINT allow_list_1_f1da08e9c8_pkey PRIMARY KEY (key);



ALTER TABLE ONLY public.basic_tags_6_62c3d17c2f
    ADD CONSTRAINT basic_tags_6_62c3d17c2f_id_tag_arg1_arg3_key UNIQUE (id, tag, arg1, arg3);



ALTER TABLE ONLY public.basic_tags_6_62c3d17c2f
    ADD CONSTRAINT basic_tags_6_62c3d17c2f_pkey PRIMARY KEY (i);



ALTER TABLE ONLY public.bookmarks_1_43f5248b56
    ADD CONSTRAINT bookmarks_1_43f5248b56_pkey PRIMARY KEY (pubkey);



ALTER TABLE ONLY public.cache
    ADD CONSTRAINT cache_pkey PRIMARY KEY (key);



ALTER TABLE ONLY public.contact_lists_1_1abdf474bd
    ADD CONSTRAINT contact_lists_1_1abdf474bd_pkey PRIMARY KEY (key);



ALTER TABLE ONLY public.coverages_1_8656fc443b
    ADD CONSTRAINT coverages_1_8656fc443b_name_t_key UNIQUE (name, t);



ALTER TABLE ONLY public.dag_1_4bd2aaff98
    ADD CONSTRAINT dag_1_4bd2aaff98_output_input_key UNIQUE (output, input);



ALTER TABLE ONLY public.daily_followers_cnt_increases
    ADD CONSTRAINT daily_followers_cnt_increases_pkey PRIMARY KEY (pubkey);



ALTER TABLE ONLY public.deleted_events_1_0249f47b16
    ADD CONSTRAINT deleted_events_1_0249f47b16_pkey PRIMARY KEY (event_id);



ALTER TABLE ONLY public.dvm_feeds
    ADD CONSTRAINT dvm_feeds_pkey PRIMARY KEY (pubkey, identifier);



ALTER TABLE ONLY public.event_created_at_1_7a51e16c5c
    ADD CONSTRAINT event_created_at_1_7a51e16c5c_pkey PRIMARY KEY (event_id);



ALTER TABLE ONLY public.event_media_1_30bf07e9cf
    ADD CONSTRAINT event_media_1_30bf07e9cf_pkey PRIMARY KEY (event_id, url);



ALTER TABLE ONLY public.event_mentions_1_0b730615c4
    ADD CONSTRAINT event_mentions_1_0b730615c4_pkey PRIMARY KEY (eid);



ALTER TABLE ONLY public.event_mentions_1_6738bfddaf
    ADD CONSTRAINT event_mentions_1_6738bfddaf_pkey PRIMARY KEY (eid, tag, argeid, argpubkey, argkind, argid);



ALTER TABLE ONLY public.event
    ADD CONSTRAINT event_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.event_pubkey_actions_1_d62afee35d
    ADD CONSTRAINT event_pubkey_actions_1_d62afee35d_pkey PRIMARY KEY (event_id, pubkey);



ALTER TABLE ONLY public.event_relay
    ADD CONSTRAINT event_relay_pkey PRIMARY KEY (event_id);



ALTER TABLE ONLY public.event_sentiment_1_d3d7a00a54
    ADD CONSTRAINT event_sentiment_1_d3d7a00a54_pkey PRIMARY KEY (eid, model);



ALTER TABLE ONLY public.event_thread_parents_1_e17bf16c98
    ADD CONSTRAINT event_thread_parents_1_e17bf16c98_pkey PRIMARY KEY (key);



ALTER TABLE ONLY public.filterlist
    ADD CONSTRAINT filterlist_pkey PRIMARY KEY (target, target_type, blocked, grp);



ALTER TABLE ONLY public.human_override
    ADD CONSTRAINT human_override_pkey PRIMARY KEY (pubkey);



ALTER TABLE ONLY public.media_storage
    ADD CONSTRAINT media_storage_pk PRIMARY KEY (h, storage_provider);



ALTER TABLE ONLY public.membership_legend_customization
    ADD CONSTRAINT membership_legend_customization_pk PRIMARY KEY (pubkey);



ALTER TABLE ONLY public.meta_data_1_323bc43167
    ADD CONSTRAINT meta_data_1_323bc43167_pkey PRIMARY KEY (key);



ALTER TABLE ONLY public.mute_list_1_f693a878b9
    ADD CONSTRAINT mute_list_1_f693a878b9_pkey PRIMARY KEY (key);



ALTER TABLE ONLY public.mute_list_2_1_949b3d746b
    ADD CONSTRAINT mute_list_2_1_949b3d746b_pkey PRIMARY KEY (key);



ALTER TABLE ONLY public.mute_lists_1_d90e559628
    ADD CONSTRAINT mute_lists_1_d90e559628_pkey PRIMARY KEY (key);



ALTER TABLE ONLY public.node_outputs_1_cfe6037c9f
    ADD CONSTRAINT node_outputs_1_cfe6037c9f_pkey PRIMARY KEY (output);



ALTER TABLE ONLY public.note_length_1_15d66ffae6
    ADD CONSTRAINT note_length_1_15d66ffae6_pkey PRIMARY KEY (eid);



ALTER TABLE ONLY public.note_stats_1_07d205f278
    ADD CONSTRAINT note_stats_1_07d205f278_pkey PRIMARY KEY (eid);



ALTER TABLE ONLY public.pubkey_content_zap_cnt_1_236df2f369
    ADD CONSTRAINT pubkey_content_zap_cnt_1_236df2f369_pkey PRIMARY KEY (pubkey);



ALTER TABLE ONLY public.pubkey_followers_cnt_1_a6f7e200e7
    ADD CONSTRAINT pubkey_followers_cnt_1_a6f7e200e7_pkey PRIMARY KEY (key);



ALTER TABLE ONLY public.pubkey_ids_1_54b55dd09c
    ADD CONSTRAINT pubkey_ids_1_54b55dd09c_pkey PRIMARY KEY (key);



ALTER TABLE ONLY public.pubkey_ln_address_1_d3649b2898
    ADD CONSTRAINT pubkey_ln_address_1_d3649b2898_pkey PRIMARY KEY (pubkey);



ALTER TABLE ONLY public.pubkey_media_cnt_1_b5e2a488b1
    ADD CONSTRAINT pubkey_media_cnt_1_b5e2a488b1_pkey PRIMARY KEY (pubkey);



ALTER TABLE ONLY public.pubkey_notification_cnts_1_d78f6fcade
    ADD CONSTRAINT pubkey_notification_cnts_1_d78f6fcade_pkey PRIMARY KEY (pubkey);



ALTER TABLE ONLY public.pubkey_trustrank
    ADD CONSTRAINT pubkey_trustrank_pkey PRIMARY KEY (pubkey);



ALTER TABLE ONLY public.pubkey_zapped_1_17f1f622a9
    ADD CONSTRAINT pubkey_zapped_1_17f1f622a9_pkey PRIMARY KEY (pubkey);



ALTER TABLE ONLY public.reads_11_2a4d2ce519
    ADD CONSTRAINT reads_11_2a4d2ce519_pkey PRIMARY KEY (pubkey, identifier);



ALTER TABLE ONLY public.reads_12_68c6bbfccd
    ADD CONSTRAINT reads_12_68c6bbfccd_pkey PRIMARY KEY (pubkey, identifier);



ALTER TABLE ONLY public.reads_versions_11_fb53a8e0b4
    ADD CONSTRAINT reads_versions_11_fb53a8e0b4_pubkey_identifier_eid_key UNIQUE (pubkey, identifier, eid);



ALTER TABLE ONLY public.reads_versions_12_b537d4df66
    ADD CONSTRAINT reads_versions_12_b537d4df66_pubkey_identifier_eid_key UNIQUE (pubkey, identifier, eid);



ALTER TABLE ONLY public.relay_list_metadata_1_801a17fc93
    ADD CONSTRAINT relay_list_metadata_1_801a17fc93_pkey PRIMARY KEY (pubkey);



ALTER TABLE ONLY public.relay_url_map
    ADD CONSTRAINT relay_url_map_pkey PRIMARY KEY (src);



ALTER TABLE ONLY public.relays
    ADD CONSTRAINT relays_pkey PRIMARY KEY (url);



ALTER TABLE ONLY public.trusted_pubkey_followers_cnt
    ADD CONSTRAINT trusted_pubkey_followers_cnt_pkey PRIMARY KEY (t, pubkey);



ALTER TABLE ONLY public.user_search
    ADD CONSTRAINT user_search_pkey PRIMARY KEY (pubkey);



ALTER TABLE ONLY public.vars
    ADD CONSTRAINT vars_pk PRIMARY KEY (name);



ALTER TABLE ONLY public.wsconnruns
    ADD CONSTRAINT wsconnruns_pkey PRIMARY KEY (run);



ALTER TABLE ONLY public.wsconnvars
    ADD CONSTRAINT wsconnvars_pkey PRIMARY KEY (name);



ALTER TABLE ONLY public.zap_receipts_1_9fe40119b2
    ADD CONSTRAINT zap_receipts_1_9fe40119b2_pkey PRIMARY KEY (eid);



CREATE INDEX a_tags_1_7d98c5333f_created_at_idx ON public.a_tags_1_7d98c5333f USING btree (created_at);



CREATE INDEX a_tags_1_7d98c5333f_eid_idx ON public.a_tags_1_7d98c5333f USING btree (eid);



CREATE INDEX a_tags_1_7d98c5333f_imported_at_idx ON public.a_tags_1_7d98c5333f USING btree (imported_at);



CREATE INDEX a_tags_1_7d98c5333f_ref_kind_ref_pubkey_idx ON public.a_tags_1_7d98c5333f USING btree (ref_kind, ref_pubkey);



CREATE INDEX a_tags_1_7d98c5333f_ref_kind_ref_pubkey_ref_identifier_idx ON public.a_tags_1_7d98c5333f USING btree (ref_kind, ref_pubkey, ref_identifier);



CREATE INDEX advsearch_5_d7da6f551e_content_tsv_idx ON public.advsearch_5_d7da6f551e USING gin (content_tsv);



CREATE INDEX advsearch_5_d7da6f551e_created_at_idx ON public.advsearch_5_d7da6f551e USING btree (created_at);



CREATE INDEX advsearch_5_d7da6f551e_filter_tsv_idx ON public.advsearch_5_d7da6f551e USING gin (filter_tsv);



CREATE INDEX advsearch_5_d7da6f551e_hashtag_tsv_idx ON public.advsearch_5_d7da6f551e USING gin (hashtag_tsv);



CREATE INDEX advsearch_5_d7da6f551e_id_idx ON public.advsearch_5_d7da6f551e USING btree (id);



CREATE INDEX advsearch_5_d7da6f551e_kind_idx ON public.advsearch_5_d7da6f551e USING btree (kind);



CREATE INDEX advsearch_5_d7da6f551e_mention_tsv_idx ON public.advsearch_5_d7da6f551e USING gin (mention_tsv);



CREATE INDEX advsearch_5_d7da6f551e_pubkey_created_at_desc_idx ON public.advsearch_5_d7da6f551e USING btree (pubkey, created_at DESC);



CREATE INDEX advsearch_5_d7da6f551e_pubkey_idx ON public.advsearch_5_d7da6f551e USING btree (pubkey);



CREATE INDEX advsearch_5_d7da6f551e_reply_tsv_idx ON public.advsearch_5_d7da6f551e USING gin (reply_tsv);



CREATE INDEX advsearch_5_d7da6f551e_url_tsv_idx ON public.advsearch_5_d7da6f551e USING gin (url_tsv);



CREATE INDEX allow_list_1_f1da08e9c8_key_idx ON public.allow_list_1_f1da08e9c8 USING btree (key);



CREATE INDEX allow_list_1_f1da08e9c8_rowid_idx ON public.allow_list_1_f1da08e9c8 USING btree (rowid);



CREATE INDEX basic_tags_6_62c3d17c2f_arg1_idx ON public.basic_tags_6_62c3d17c2f USING hash (arg1);



CREATE INDEX basic_tags_6_62c3d17c2f_created_at_idx ON public.basic_tags_6_62c3d17c2f USING btree (created_at);



CREATE INDEX basic_tags_6_62c3d17c2f_id_idx ON public.basic_tags_6_62c3d17c2f USING btree (id);



CREATE INDEX basic_tags_6_62c3d17c2f_imported_at_idx ON public.basic_tags_6_62c3d17c2f USING btree (imported_at);



CREATE INDEX basic_tags_6_62c3d17c2f_pubkey_idx ON public.basic_tags_6_62c3d17c2f USING btree (pubkey);



CREATE INDEX bookmarks_1_43f5248b56_pubkey_idx ON public.bookmarks_1_43f5248b56 USING btree (pubkey);



CREATE INDEX bookmarks_1_43f5248b56_rowid_idx ON public.bookmarks_1_43f5248b56 USING btree (rowid);



CREATE INDEX cmr_groups_user_pubkey_grp_scope_idx ON public.cmr_groups USING btree (user_pubkey, grp, scope);



CREATE INDEX cmr_pubkeys_allowed_user_pubkey_pubkey_idx ON public.cmr_pubkeys_allowed USING btree (user_pubkey, pubkey);



CREATE INDEX cmr_pubkeys_parent_user_pubkey_pubkey_idx ON public.cmr_pubkeys_parent USING btree (user_pubkey, pubkey);



CREATE INDEX cmr_pubkeys_scopes_user_pubkey_pubkey_scope_idx ON public.cmr_pubkeys_scopes USING btree (user_pubkey, pubkey, scope);



CREATE INDEX contact_lists_1_1abdf474bd_key_idx ON public.contact_lists_1_1abdf474bd USING btree (key);



CREATE INDEX contact_lists_1_1abdf474bd_rowid_idx ON public.contact_lists_1_1abdf474bd USING btree (rowid);



CREATE INDEX coverages_1_8656fc443b_name_idx ON public.coverages_1_8656fc443b USING btree (name);



CREATE INDEX dag_1_4bd2aaff98_input_idx ON public.dag_1_4bd2aaff98 USING btree (input);



CREATE INDEX dag_1_4bd2aaff98_output_idx ON public.dag_1_4bd2aaff98 USING btree (output);



CREATE INDEX deleted_events_1_0249f47b16_event_id_idx ON public.deleted_events_1_0249f47b16 USING btree (event_id);



CREATE INDEX deleted_events_1_0249f47b16_rowid_idx ON public.deleted_events_1_0249f47b16 USING btree (rowid);



CREATE INDEX event_attributes_1_3196ca546f_event_id_idx ON public.event_attributes_1_3196ca546f USING btree (event_id);



CREATE INDEX event_attributes_1_3196ca546f_key_value_idx ON public.event_attributes_1_3196ca546f USING btree (key, value);



CREATE INDEX event_attributes_1_3196ca546f_rowid_idx ON public.event_attributes_1_3196ca546f USING btree (rowid);



CREATE INDEX event_created_at_1_7a51e16c5c_created_at_idx ON public.event_created_at_1_7a51e16c5c USING btree (created_at);



CREATE INDEX event_created_at_1_7a51e16c5c_rowid_idx ON public.event_created_at_1_7a51e16c5c USING btree (rowid);



CREATE INDEX event_created_at_idx ON public.event USING btree (created_at);



CREATE INDEX event_created_at_kind ON public.event USING btree (created_at, kind);



CREATE INDEX event_hashtags_1_295f217c0e_created_at_idx ON public.event_hashtags_1_295f217c0e USING btree (created_at);



CREATE INDEX event_hashtags_1_295f217c0e_event_id_idx ON public.event_hashtags_1_295f217c0e USING btree (event_id);



CREATE INDEX event_hashtags_1_295f217c0e_hashtag_idx ON public.event_hashtags_1_295f217c0e USING btree (hashtag);



CREATE INDEX event_hashtags_1_295f217c0e_rowid_idx ON public.event_hashtags_1_295f217c0e USING btree (rowid);



CREATE INDEX event_hooks_event_id_idx ON public.event_hooks USING btree (event_id);



CREATE INDEX event_imported_at ON public.event USING btree (imported_at);



CREATE INDEX event_imported_at_id_idx ON public.event USING btree (imported_at, id);



CREATE INDEX event_imported_at_kind_idx ON public.event USING btree (imported_at, kind);



CREATE INDEX event_kind ON public.event USING btree (kind);



CREATE INDEX event_media_1_30bf07e9cf_event_id_idx ON public.event_media_1_30bf07e9cf USING btree (event_id);



CREATE INDEX event_media_1_30bf07e9cf_rowid_idx ON public.event_media_1_30bf07e9cf USING btree (rowid);



CREATE INDEX event_media_1_30bf07e9cf_url_idx ON public.event_media_1_30bf07e9cf USING btree (url);



CREATE INDEX event_mentions_1_a056fb6737_eid_idx ON public.event_mentions_1_a056fb6737 USING btree (eid);



CREATE INDEX event_preview_1_310cef356e_event_id_idx ON public.event_preview_1_310cef356e USING btree (event_id);



CREATE INDEX event_preview_1_310cef356e_rowid_idx ON public.event_preview_1_310cef356e USING btree (rowid);



CREATE INDEX event_preview_1_310cef356e_url_idx ON public.event_preview_1_310cef356e USING btree (url);



CREATE INDEX event_pubkey ON public.event USING btree (pubkey);



CREATE INDEX event_pubkey_action_refs_1_f32e1ff589_event_id_idx ON public.event_pubkey_action_refs_1_f32e1ff589 USING btree (event_id);



CREATE INDEX event_pubkey_action_refs_1_f32e1ff589_ref_created_at_idx ON public.event_pubkey_action_refs_1_f32e1ff589 USING btree (ref_created_at);



CREATE INDEX event_pubkey_action_refs_1_f32e1ff589_ref_event_id_idx ON public.event_pubkey_action_refs_1_f32e1ff589 USING btree (ref_event_id);



CREATE INDEX event_pubkey_action_refs_1_f32e1ff589_ref_event_id_ref_kind_idx ON public.event_pubkey_action_refs_1_f32e1ff589 USING btree (ref_event_id, ref_kind);



CREATE INDEX event_pubkey_action_refs_1_f32e1ff589_ref_event_id_ref_pubkey_i ON public.event_pubkey_action_refs_1_f32e1ff589 USING btree (ref_event_id, ref_pubkey);



CREATE INDEX event_pubkey_action_refs_1_f32e1ff589_ref_kind_idx ON public.event_pubkey_action_refs_1_f32e1ff589 USING btree (ref_kind);



CREATE INDEX event_pubkey_action_refs_1_f32e1ff589_ref_pubkey_idx ON public.event_pubkey_action_refs_1_f32e1ff589 USING btree (ref_pubkey);



CREATE INDEX event_pubkey_action_refs_1_f32e1ff589_rowid_idx ON public.event_pubkey_action_refs_1_f32e1ff589 USING btree (rowid);



CREATE INDEX event_pubkey_actions_1_d62afee35d_created_at_idx ON public.event_pubkey_actions_1_d62afee35d USING btree (created_at);



CREATE INDEX event_pubkey_actions_1_d62afee35d_event_id_idx ON public.event_pubkey_actions_1_d62afee35d USING btree (event_id);



CREATE INDEX event_pubkey_actions_1_d62afee35d_pubkey_idx ON public.event_pubkey_actions_1_d62afee35d USING btree (pubkey);



CREATE INDEX event_pubkey_actions_1_d62afee35d_rowid_idx ON public.event_pubkey_actions_1_d62afee35d USING btree (rowid);



CREATE INDEX event_pubkey_actions_1_d62afee35d_updated_at_idx ON public.event_pubkey_actions_1_d62afee35d USING btree (updated_at);



CREATE INDEX event_replies_1_9d033b5bb3_event_id_idx ON public.event_replies_1_9d033b5bb3 USING btree (event_id);



CREATE INDEX event_replies_1_9d033b5bb3_reply_created_at_idx ON public.event_replies_1_9d033b5bb3 USING btree (reply_created_at);



CREATE INDEX event_replies_1_9d033b5bb3_rowid_idx ON public.event_replies_1_9d033b5bb3 USING btree (rowid);



CREATE INDEX event_sentiment_1_d3d7a00a54_topsentiment_idx ON public.event_sentiment_1_d3d7a00a54 USING btree (topsentiment);



CREATE INDEX event_stats_1_1b380f4869_author_pubkey_created_at_idx ON public.event_stats_1_1b380f4869 USING btree (author_pubkey, created_at);



CREATE INDEX event_stats_1_1b380f4869_author_pubkey_idx ON public.event_stats_1_1b380f4869 USING btree (author_pubkey);



CREATE INDEX event_stats_1_1b380f4869_author_pubkey_satszapped_idx ON public.event_stats_1_1b380f4869 USING btree (author_pubkey, satszapped);



CREATE INDEX event_stats_1_1b380f4869_author_pubkey_score24h_idx ON public.event_stats_1_1b380f4869 USING btree (author_pubkey, score24h);



CREATE INDEX event_stats_1_1b380f4869_author_pubkey_score_idx ON public.event_stats_1_1b380f4869 USING btree (author_pubkey, score);



CREATE INDEX event_stats_1_1b380f4869_created_at_idx ON public.event_stats_1_1b380f4869 USING btree (created_at);



CREATE INDEX event_stats_1_1b380f4869_created_at_satszapped_idx ON public.event_stats_1_1b380f4869 USING btree (created_at, satszapped);



CREATE INDEX event_stats_1_1b380f4869_created_at_score24h_idx ON public.event_stats_1_1b380f4869 USING btree (created_at, score24h);



CREATE INDEX event_stats_1_1b380f4869_event_id_idx ON public.event_stats_1_1b380f4869 USING btree (event_id);



CREATE INDEX event_stats_1_1b380f4869_likes_idx ON public.event_stats_1_1b380f4869 USING btree (likes);



CREATE INDEX event_stats_1_1b380f4869_mentions_idx ON public.event_stats_1_1b380f4869 USING btree (mentions);



CREATE INDEX event_stats_1_1b380f4869_replies_idx ON public.event_stats_1_1b380f4869 USING btree (replies);



CREATE INDEX event_stats_1_1b380f4869_reposts_idx ON public.event_stats_1_1b380f4869 USING btree (reposts);



CREATE INDEX event_stats_1_1b380f4869_rowid_idx ON public.event_stats_1_1b380f4869 USING btree (rowid);



CREATE INDEX event_stats_1_1b380f4869_satszapped_idx ON public.event_stats_1_1b380f4869 USING btree (satszapped);



CREATE INDEX event_stats_1_1b380f4869_score24h_idx ON public.event_stats_1_1b380f4869 USING btree (score24h);



CREATE INDEX event_stats_1_1b380f4869_score_idx ON public.event_stats_1_1b380f4869 USING btree (score);



CREATE INDEX event_stats_1_1b380f4869_zaps_idx ON public.event_stats_1_1b380f4869 USING btree (zaps);



CREATE INDEX event_stats_by_pubkey_1_4ecc48a026_author_pubkey_idx ON public.event_stats_by_pubkey_1_4ecc48a026 USING btree (author_pubkey);



CREATE INDEX event_stats_by_pubkey_1_4ecc48a026_created_at_idx ON public.event_stats_by_pubkey_1_4ecc48a026 USING btree (created_at);



CREATE INDEX event_stats_by_pubkey_1_4ecc48a026_created_at_satszapped_idx ON public.event_stats_by_pubkey_1_4ecc48a026 USING btree (created_at, satszapped);



CREATE INDEX event_stats_by_pubkey_1_4ecc48a026_created_at_score24h_idx ON public.event_stats_by_pubkey_1_4ecc48a026 USING btree (created_at, score24h);



CREATE INDEX event_stats_by_pubkey_1_4ecc48a026_event_id_idx ON public.event_stats_by_pubkey_1_4ecc48a026 USING btree (event_id);



CREATE INDEX event_stats_by_pubkey_1_4ecc48a026_rowid_idx ON public.event_stats_by_pubkey_1_4ecc48a026 USING btree (rowid);



CREATE INDEX event_stats_by_pubkey_1_4ecc48a026_satszapped_idx ON public.event_stats_by_pubkey_1_4ecc48a026 USING btree (satszapped);



CREATE INDEX event_stats_by_pubkey_1_4ecc48a026_score24h_idx ON public.event_stats_by_pubkey_1_4ecc48a026 USING btree (score24h);



CREATE INDEX event_stats_by_pubkey_1_4ecc48a026_score_idx ON public.event_stats_by_pubkey_1_4ecc48a026 USING btree (score);



CREATE INDEX event_thread_parents_1_e17bf16c98_key_idx ON public.event_thread_parents_1_e17bf16c98 USING btree (key);



CREATE INDEX event_thread_parents_1_e17bf16c98_rowid_idx ON public.event_thread_parents_1_e17bf16c98 USING btree (rowid);



CREATE INDEX event_zapped_1_7ebdbebf92_event_id_zap_sender_idx ON public.event_zapped_1_7ebdbebf92 USING btree (event_id, zap_sender);



CREATE INDEX event_zapped_1_7ebdbebf92_rowid_idx ON public.event_zapped_1_7ebdbebf92 USING btree (rowid);



CREATE INDEX filterlist_pubkey_pubkey_blocked_grp_idx ON public.filterlist_pubkey USING btree (pubkey, blocked, grp);



CREATE INDEX hashtags_1_1e5c72161a_hashtag_idx ON public.hashtags_1_1e5c72161a USING btree (hashtag);



CREATE INDEX hashtags_1_1e5c72161a_rowid_idx ON public.hashtags_1_1e5c72161a USING btree (rowid);



CREATE INDEX hashtags_1_1e5c72161a_score_idx ON public.hashtags_1_1e5c72161a USING btree (score);



CREATE INDEX human_override_pubkey ON public.human_override USING btree (pubkey);



CREATE INDEX lists_added_at ON public.lists USING btree (added_at DESC);



CREATE INDEX lists_list ON public.lists USING btree (list);



CREATE INDEX lists_pubkey ON public.lists USING btree (pubkey);



CREATE INDEX logs_1_d241bdb71c_eid ON public.logs_1_d241bdb71c USING btree (((d ->> 'eid'::text)));



CREATE INDEX logs_1_d241bdb71c_func_idx ON public.logs_1_d241bdb71c USING btree (func);



CREATE INDEX logs_1_d241bdb71c_module_idx ON public.logs_1_d241bdb71c USING btree (module);



CREATE INDEX logs_1_d241bdb71c_t_idx ON public.logs_1_d241bdb71c USING btree (t);



CREATE INDEX logs_1_d241bdb71c_type_idx ON public.logs_1_d241bdb71c USING btree (type);



CREATE INDEX media_1_16fa35f2dc_category_idx ON public.media_1_16fa35f2dc USING btree (category);



CREATE INDEX media_1_16fa35f2dc_imported_at_idx ON public.media_1_16fa35f2dc USING btree (imported_at);



CREATE INDEX media_1_16fa35f2dc_media_url_idx ON public.media_1_16fa35f2dc USING btree (media_url);



CREATE INDEX media_1_16fa35f2dc_rowid_idx ON public.media_1_16fa35f2dc USING btree (rowid);



CREATE INDEX media_1_16fa35f2dc_url_idx ON public.media_1_16fa35f2dc USING btree (url);



CREATE INDEX media_1_16fa35f2dc_url_size_animated_idx ON public.media_1_16fa35f2dc USING btree (url, size, animated);



CREATE INDEX media_storage_added_at_idx ON public.media_storage USING btree (added_at);



CREATE INDEX media_storage_h_idx ON public.media_storage USING btree (h);



CREATE INDEX memberships_pubkey ON public.memberships USING btree (pubkey);



CREATE INDEX meta_data_1_323bc43167_key_idx ON public.meta_data_1_323bc43167 USING btree (key);



CREATE INDEX meta_data_1_323bc43167_rowid_idx ON public.meta_data_1_323bc43167 USING btree (rowid);



CREATE INDEX mute_list_1_f693a878b9_key_idx ON public.mute_list_1_f693a878b9 USING btree (key);



CREATE INDEX mute_list_1_f693a878b9_rowid_idx ON public.mute_list_1_f693a878b9 USING btree (rowid);



CREATE INDEX mute_list_2_1_949b3d746b_key_idx ON public.mute_list_2_1_949b3d746b USING btree (key);



CREATE INDEX mute_list_2_1_949b3d746b_rowid_idx ON public.mute_list_2_1_949b3d746b USING btree (rowid);



CREATE INDEX mute_lists_1_d90e559628_key_idx ON public.mute_lists_1_d90e559628 USING btree (key);



CREATE INDEX mute_lists_1_d90e559628_rowid_idx ON public.mute_lists_1_d90e559628 USING btree (rowid);



CREATE INDEX og_zap_receipts_1_dc85307383_amount_sats_idx ON public.og_zap_receipts_1_dc85307383 USING btree (amount_sats);



CREATE INDEX og_zap_receipts_1_dc85307383_created_at_idx ON public.og_zap_receipts_1_dc85307383 USING btree (created_at);



CREATE INDEX og_zap_receipts_1_dc85307383_event_id_idx ON public.og_zap_receipts_1_dc85307383 USING btree (event_id);



CREATE INDEX og_zap_receipts_1_dc85307383_receiver_idx ON public.og_zap_receipts_1_dc85307383 USING btree (receiver);



CREATE INDEX og_zap_receipts_1_dc85307383_rowid_idx ON public.og_zap_receipts_1_dc85307383 USING btree (rowid);



CREATE INDEX og_zap_receipts_1_dc85307383_sender_idx ON public.og_zap_receipts_1_dc85307383 USING btree (sender);



CREATE INDEX parameterized_replaceable_list_1_d02d7ecc62_created_at_idx ON public.parameterized_replaceable_list_1_d02d7ecc62 USING btree (created_at);



CREATE INDEX parameterized_replaceable_list_1_d02d7ecc62_identifier_idx ON public.parameterized_replaceable_list_1_d02d7ecc62 USING btree (identifier);



CREATE INDEX parameterized_replaceable_list_1_d02d7ecc62_pubkey_idx ON public.parameterized_replaceable_list_1_d02d7ecc62 USING btree (pubkey);



CREATE INDEX parameterized_replaceable_list_1_d02d7ecc62_rowid_idx ON public.parameterized_replaceable_list_1_d02d7ecc62 USING btree (rowid);



CREATE INDEX parametrized_replaceable_events_1_cbe75c8d53_created_at_idx ON public.parametrized_replaceable_events_1_cbe75c8d53 USING btree (created_at);



CREATE INDEX parametrized_replaceable_events_1_cbe75c8d53_event_id_idx ON public.parametrized_replaceable_events_1_cbe75c8d53 USING btree (event_id);



CREATE INDEX parametrized_replaceable_events_1_cbe75c8d53_identifier_idx ON public.parametrized_replaceable_events_1_cbe75c8d53 USING btree (identifier);



CREATE INDEX parametrized_replaceable_events_1_cbe75c8d53_kind_idx ON public.parametrized_replaceable_events_1_cbe75c8d53 USING btree (kind);



CREATE INDEX parametrized_replaceable_events_1_cbe75c8d53_pubkey_idx ON public.parametrized_replaceable_events_1_cbe75c8d53 USING btree (pubkey);



CREATE INDEX parametrized_replaceable_events_1_cbe75c8d53_rowid_idx ON public.parametrized_replaceable_events_1_cbe75c8d53 USING btree (rowid);



CREATE INDEX preview_1_44299731c7_category_idx ON public.preview_1_44299731c7 USING btree (category);



CREATE INDEX preview_1_44299731c7_imported_at_idx ON public.preview_1_44299731c7 USING btree (imported_at);



CREATE INDEX preview_1_44299731c7_rowid_idx ON public.preview_1_44299731c7 USING btree (rowid);



CREATE INDEX preview_1_44299731c7_url_idx ON public.preview_1_44299731c7 USING btree (url);



CREATE INDEX pubkey_bookmarks_pubkey_ref_event_id ON public.pubkey_bookmarks USING btree (pubkey, ref_event_id);



CREATE INDEX pubkey_bookmarks_ref_event_id ON public.pubkey_bookmarks USING btree (ref_event_id);



CREATE INDEX pubkey_content_zap_cnt_1_236df2f369_pubkey_idx ON public.pubkey_content_zap_cnt_1_236df2f369 USING btree (pubkey);



CREATE INDEX pubkey_directmsgs_1_c794110a2c_created_at_idx ON public.pubkey_directmsgs_1_c794110a2c USING btree (created_at);



CREATE INDEX pubkey_directmsgs_1_c794110a2c_receiver_event_id_idx ON public.pubkey_directmsgs_1_c794110a2c USING btree (receiver, event_id);



CREATE INDEX pubkey_directmsgs_1_c794110a2c_receiver_idx ON public.pubkey_directmsgs_1_c794110a2c USING btree (receiver);



CREATE INDEX pubkey_directmsgs_1_c794110a2c_receiver_sender_idx ON public.pubkey_directmsgs_1_c794110a2c USING btree (receiver, sender);



CREATE INDEX pubkey_directmsgs_1_c794110a2c_rowid_idx ON public.pubkey_directmsgs_1_c794110a2c USING btree (rowid);



CREATE INDEX pubkey_directmsgs_1_c794110a2c_sender_idx ON public.pubkey_directmsgs_1_c794110a2c USING btree (sender);



CREATE INDEX pubkey_directmsgs_cnt_1_efdf9742a6_receiver_idx ON public.pubkey_directmsgs_cnt_1_efdf9742a6 USING btree (receiver);



CREATE INDEX pubkey_directmsgs_cnt_1_efdf9742a6_receiver_sender_idx ON public.pubkey_directmsgs_cnt_1_efdf9742a6 USING btree (receiver, sender);



CREATE INDEX pubkey_directmsgs_cnt_1_efdf9742a6_rowid_idx ON public.pubkey_directmsgs_cnt_1_efdf9742a6 USING btree (rowid);



CREATE INDEX pubkey_directmsgs_cnt_1_efdf9742a6_sender_idx ON public.pubkey_directmsgs_cnt_1_efdf9742a6 USING btree (sender);



CREATE INDEX pubkey_events_1_1dcbfe1466_created_at_idx ON public.pubkey_events_1_1dcbfe1466 USING btree (created_at);



CREATE INDEX pubkey_events_1_1dcbfe1466_created_at_pubkey_idx ON public.pubkey_events_1_1dcbfe1466 USING btree (created_at DESC, pubkey);



CREATE INDEX pubkey_events_1_1dcbfe1466_event_id_idx ON public.pubkey_events_1_1dcbfe1466 USING btree (event_id);



CREATE INDEX pubkey_events_1_1dcbfe1466_pubkey_created_at_idx ON public.pubkey_events_1_1dcbfe1466 USING btree (pubkey, created_at);



CREATE INDEX pubkey_events_1_1dcbfe1466_pubkey_idx ON public.pubkey_events_1_1dcbfe1466 USING btree (pubkey);



CREATE INDEX pubkey_events_1_1dcbfe1466_pubkey_is_reply_idx ON public.pubkey_events_1_1dcbfe1466 USING btree (pubkey, is_reply);



CREATE INDEX pubkey_events_1_1dcbfe1466_rowid_idx ON public.pubkey_events_1_1dcbfe1466 USING btree (rowid);



CREATE INDEX pubkey_followers_1_d52305fb47_follower_contact_list_event_id_id ON public.pubkey_followers_1_d52305fb47 USING btree (follower_contact_list_event_id);



CREATE INDEX pubkey_followers_1_d52305fb47_follower_pubkey_idx ON public.pubkey_followers_1_d52305fb47 USING btree (follower_pubkey);



CREATE INDEX pubkey_followers_1_d52305fb47_follower_pubkey_pubkey_idx ON public.pubkey_followers_1_d52305fb47 USING btree (follower_pubkey, pubkey);



CREATE INDEX pubkey_followers_1_d52305fb47_pubkey_idx ON public.pubkey_followers_1_d52305fb47 USING btree (pubkey);



CREATE INDEX pubkey_followers_1_d52305fb47_rowid_idx ON public.pubkey_followers_1_d52305fb47 USING btree (rowid);



CREATE INDEX pubkey_followers_cnt_1_a6f7e200e7_key_idx ON public.pubkey_followers_cnt_1_a6f7e200e7 USING btree (key);



CREATE INDEX pubkey_followers_cnt_1_a6f7e200e7_rowid_idx ON public.pubkey_followers_cnt_1_a6f7e200e7 USING btree (rowid);



CREATE INDEX pubkey_followers_cnt_1_a6f7e200e7_value_idx ON public.pubkey_followers_cnt_1_a6f7e200e7 USING btree (value);



CREATE INDEX pubkey_ids_1_54b55dd09c_key_idx ON public.pubkey_ids_1_54b55dd09c USING btree (key);



CREATE INDEX pubkey_ids_1_54b55dd09c_rowid_idx ON public.pubkey_ids_1_54b55dd09c USING btree (rowid);



CREATE INDEX pubkey_ln_address_1_d3649b2898_ln_address_idx ON public.pubkey_ln_address_1_d3649b2898 USING btree (ln_address);



CREATE INDEX pubkey_ln_address_1_d3649b2898_pubkey_idx ON public.pubkey_ln_address_1_d3649b2898 USING btree (pubkey);



CREATE INDEX pubkey_ln_address_1_d3649b2898_rowid_idx ON public.pubkey_ln_address_1_d3649b2898 USING btree (rowid);



CREATE INDEX pubkey_media_cnt_1_b5e2a488b1_pubkey_idx ON public.pubkey_media_cnt_1_b5e2a488b1 USING btree (pubkey);



CREATE INDEX pubkey_notification_cnts_1_d78f6fcade_pubkey_idx ON public.pubkey_notification_cnts_1_d78f6fcade USING btree (pubkey);



CREATE INDEX pubkey_notification_cnts_1_d78f6fcade_rowid_idx ON public.pubkey_notification_cnts_1_d78f6fcade USING btree (rowid);



CREATE INDEX pubkey_notifications_1_e5459ab9dd_arg1_idx ON public.pubkey_notifications_1_e5459ab9dd USING btree (arg1);



CREATE INDEX pubkey_notifications_1_e5459ab9dd_arg2_idx ON public.pubkey_notifications_1_e5459ab9dd USING btree (arg2);



CREATE INDEX pubkey_notifications_1_e5459ab9dd_created_at_idx ON public.pubkey_notifications_1_e5459ab9dd USING btree (created_at);



CREATE INDEX pubkey_notifications_1_e5459ab9dd_pubkey_arg1_idx_ ON public.pubkey_notifications_1_e5459ab9dd USING btree (pubkey, arg1) WHERE ((type <> 1) AND (type <> 2));



CREATE INDEX pubkey_notifications_1_e5459ab9dd_pubkey_arg2_idx_ ON public.pubkey_notifications_1_e5459ab9dd USING btree (pubkey, arg2) WHERE ((type <> 1) AND (type <> 2));



CREATE INDEX pubkey_notifications_1_e5459ab9dd_pubkey_created_at_idx ON public.pubkey_notifications_1_e5459ab9dd USING btree (pubkey, created_at);



CREATE INDEX pubkey_notifications_1_e5459ab9dd_pubkey_created_at_type_idx ON public.pubkey_notifications_1_e5459ab9dd USING btree (pubkey, created_at, type);



CREATE INDEX pubkey_notifications_1_e5459ab9dd_pubkey_idx ON public.pubkey_notifications_1_e5459ab9dd USING btree (pubkey);



CREATE INDEX pubkey_notifications_1_e5459ab9dd_rowid_idx ON public.pubkey_notifications_1_e5459ab9dd USING btree (rowid);



CREATE INDEX pubkey_notifications_1_e5459ab9dd_type_idx ON public.pubkey_notifications_1_e5459ab9dd USING btree (type);



CREATE INDEX pubkey_zapped_1_17f1f622a9_pubkey_idx ON public.pubkey_zapped_1_17f1f622a9 USING btree (pubkey);



CREATE INDEX pubkey_zapped_1_17f1f622a9_rowid_idx ON public.pubkey_zapped_1_17f1f622a9 USING btree (rowid);



CREATE INDEX pubkey_zapped_1_17f1f622a9_satszapped_idx ON public.pubkey_zapped_1_17f1f622a9 USING btree (satszapped);



CREATE INDEX pubkey_zapped_1_17f1f622a9_zaps_idx ON public.pubkey_zapped_1_17f1f622a9 USING btree (zaps);



CREATE INDEX reads_11_2a4d2ce519_identifier_idx ON public.reads_11_2a4d2ce519 USING btree (identifier);



CREATE INDEX reads_11_2a4d2ce519_pubkey_idx ON public.reads_11_2a4d2ce519 USING btree (pubkey);



CREATE INDEX reads_11_2a4d2ce519_published_at_idx ON public.reads_11_2a4d2ce519 USING btree (published_at);



CREATE INDEX reads_11_2a4d2ce519_topics_idx ON public.reads_11_2a4d2ce519 USING gin (topics);



CREATE INDEX reads_12_68c6bbfccd_identifier_idx ON public.reads_12_68c6bbfccd USING btree (identifier);



CREATE INDEX reads_12_68c6bbfccd_pubkey_idx ON public.reads_12_68c6bbfccd USING btree (pubkey);



CREATE INDEX reads_12_68c6bbfccd_published_at_idx ON public.reads_12_68c6bbfccd USING btree (published_at);



CREATE INDEX reads_12_68c6bbfccd_topics_idx ON public.reads_12_68c6bbfccd USING gin (topics);



CREATE INDEX reads_versions_11_fb53a8e0b4_eid_idx ON public.reads_versions_11_fb53a8e0b4 USING hash (eid);



CREATE INDEX reads_versions_11_fb53a8e0b4_identifier_idx ON public.reads_versions_11_fb53a8e0b4 USING btree (identifier);



CREATE INDEX reads_versions_11_fb53a8e0b4_pubkey_idx ON public.reads_versions_11_fb53a8e0b4 USING btree (pubkey);



CREATE INDEX reads_versions_12_b537d4df66_eid_idx ON public.reads_versions_12_b537d4df66 USING hash (eid);



CREATE INDEX reads_versions_12_b537d4df66_identifier_idx ON public.reads_versions_12_b537d4df66 USING btree (identifier);



CREATE INDEX reads_versions_12_b537d4df66_pubkey_idx ON public.reads_versions_12_b537d4df66 USING btree (pubkey);



CREATE INDEX relay_list_metadata_1_801a17fc93_pubkey_idx ON public.relay_list_metadata_1_801a17fc93 USING btree (pubkey);



CREATE INDEX relay_list_metadata_1_801a17fc93_rowid_idx ON public.relay_list_metadata_1_801a17fc93 USING btree (rowid);



CREATE INDEX relays_times_referenced_idx ON public.relays USING btree (times_referenced DESC);



CREATE INDEX scheduled_hooks_execute_at_idx ON public.scheduled_hooks USING btree (execute_at);



CREATE INDEX score_expiry_event_id_idx ON public.score_expiry USING btree (event_id);



CREATE INDEX score_expiry_expire_at_idx ON public.score_expiry USING btree (expire_at);



CREATE INDEX stuff_created_at ON public.stuff USING btree (created_at DESC);



CREATE INDEX user_search_display_name_idx ON public.user_search USING gin (display_name);



CREATE INDEX user_search_displayname_idx ON public.user_search USING gin (displayname);



CREATE INDEX user_search_lud16_idx ON public.user_search USING gin (lud16);



CREATE INDEX user_search_name_idx ON public.user_search USING gin (name);



CREATE INDEX user_search_nip05_idx ON public.user_search USING gin (nip05);



CREATE INDEX user_search_username_idx ON public.user_search USING gin (username);



CREATE INDEX verified_users_name ON public.verified_users USING btree (name);



CREATE INDEX verified_users_pubkey ON public.verified_users USING btree (pubkey);



CREATE INDEX video_thumbnails_1_107d5a46eb_rowid_idx ON public.video_thumbnails_1_107d5a46eb USING btree (rowid);



CREATE INDEX video_thumbnails_1_107d5a46eb_thumbnail_url_idx ON public.video_thumbnails_1_107d5a46eb USING btree (thumbnail_url);



CREATE INDEX video_thumbnails_1_107d5a46eb_video_url_idx ON public.video_thumbnails_1_107d5a46eb USING btree (video_url);



CREATE INDEX wsconnlog_t_idx ON public.wsconnlog USING btree (t);



CREATE INDEX zap_receipts_1_9fe40119b2_imported_at_idx ON public.zap_receipts_1_9fe40119b2 USING btree (imported_at);



CREATE INDEX zap_receipts_1_9fe40119b2_receiver_idx ON public.zap_receipts_1_9fe40119b2 USING btree (receiver);



CREATE INDEX zap_receipts_1_9fe40119b2_sender_idx ON public.zap_receipts_1_9fe40119b2 USING btree (sender);



CREATE INDEX zap_receipts_1_9fe40119b2_target_eid_idx ON public.zap_receipts_1_9fe40119b2 USING btree (target_eid);



CREATE TRIGGER update_cache_updated_at BEFORE UPDATE ON public.cache FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();



