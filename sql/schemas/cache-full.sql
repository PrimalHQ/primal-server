--
-- PostgreSQL database dump
--

-- Dumped from database version 16.4
-- Dumped by pg_dump version 17.5

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

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
DROP INDEX public.text_metadata_event_id_idx;
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
DROP INDEX public.reads_latest_eid_idx;
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
DROP INDEX public.media_storage_sha256_idx;
DROP INDEX public.media_storage_media_block_id_idx;
DROP INDEX public.media_storage_key_sha256_idx;
DROP INDEX public.media_storage_h_idx;
DROP INDEX public.media_storage_added_at_idx;
DROP INDEX public.media_1_16fa35f2dc_url_size_animated_idx;
DROP INDEX public.media_1_16fa35f2dc_url_idx;
DROP INDEX public.media_1_16fa35f2dc_size_animated_idx;
DROP INDEX public.media_1_16fa35f2dc_rowid_idx;
DROP INDEX public.media_1_16fa35f2dc_orig_sha256_size_animated_idx;
DROP INDEX public.media_1_16fa35f2dc_orig_sha256_idx;
DROP INDEX public.media_1_16fa35f2dc_media_url_idx;
DROP INDEX public.media_1_16fa35f2dc_imported_at_idx;
DROP INDEX public.media_1_16fa35f2dc_category_idx;
DROP INDEX public.logs_1_d241bdb71c_type_idx;
DROP INDEX public.logs_1_d241bdb71c_t_idx;
DROP INDEX public.logs_1_d241bdb71c_module_idx;
DROP INDEX public.logs_1_d241bdb71c_func_idx;
DROP INDEX public.logs_1_d241bdb71c_eid;
DROP INDEX public.live_event_participants_kind_pubkey_identifier_idx;
DROP INDEX public.live_event_participants_kind_participant_pubkey_idx;
DROP INDEX public.lists_pubkey;
DROP INDEX public.lists_list;
DROP INDEX public.lists_added_at;
DROP INDEX public.human_override_pubkey;
DROP INDEX public.hashtags_1_1e5c72161a_score_idx;
DROP INDEX public.hashtags_1_1e5c72161a_rowid_idx;
DROP INDEX public.hashtags_1_1e5c72161a_hashtag_idx;
DROP INDEX public.follow_lists_pubkey_identifier_idx;
DROP INDEX public.filterlist_pubkey_pubkey_blocked_grp_idx;
DROP INDEX public.fetcher_relays_updated_at_index;
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
DROP INDEX public.event_stats_1_1b380f4869_score_created_at_idx;
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
DROP INDEX public.event_relays_imported_at_idx;
DROP INDEX public.event_relays_event_id_idx;
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
DROP INDEX public.event_mentions_1_a056fb6737_unique;
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
DROP INDEX public.cmr_words_user_pubkey_idx;
DROP INDEX public.cmr_words_2_user_pubkey_idx;
DROP INDEX public.cmr_threads_user_pubkey_event_id_idx;
DROP INDEX public.cmr_pubkeys_scopes_user_pubkey_pubkey_scope_idx;
DROP INDEX public.cmr_pubkeys_parent_user_pubkey_pubkey_idx;
DROP INDEX public.cmr_pubkeys_allowed_user_pubkey_pubkey_idx;
DROP INDEX public.cmr_hashtags_user_pubkey_idx;
DROP INDEX public.cmr_hashtags_2_user_pubkey_idx;
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
ALTER TABLE ONLY public.vars DROP CONSTRAINT vars_pkey;
ALTER TABLE ONLY public.user_search DROP CONSTRAINT user_search_pkey;
ALTER TABLE ONLY public.trusted_pubkey_followers_cnt DROP CONSTRAINT trusted_pubkey_followers_cnt_pkey;
ALTER TABLE ONLY public.text_metadata DROP CONSTRAINT text_metadata_pkey;
ALTER TABLE ONLY public.replaceable_events DROP CONSTRAINT replaceable_events_pk;
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
ALTER TABLE ONLY public.notification_types DROP CONSTRAINT notification_types_pk;
ALTER TABLE ONLY public.note_stats_1_07d205f278 DROP CONSTRAINT note_stats_1_07d205f278_pkey;
ALTER TABLE ONLY public.note_length_1_15d66ffae6 DROP CONSTRAINT note_length_1_15d66ffae6_pkey;
ALTER TABLE ONLY public.node_outputs_1_cfe6037c9f DROP CONSTRAINT node_outputs_1_cfe6037c9f_pkey;
ALTER TABLE ONLY public.muted_threads DROP CONSTRAINT muted_threads_pkey;
ALTER TABLE ONLY public.mute_lists_1_d90e559628 DROP CONSTRAINT mute_lists_1_d90e559628_pkey;
ALTER TABLE ONLY public.mute_list_2_1_949b3d746b DROP CONSTRAINT mute_list_2_1_949b3d746b_pkey;
ALTER TABLE ONLY public.mute_list_1_f693a878b9 DROP CONSTRAINT mute_list_1_f693a878b9_pkey;
ALTER TABLE ONLY public.meta_data_1_323bc43167 DROP CONSTRAINT meta_data_1_323bc43167_pkey;
ALTER TABLE ONLY public.memberships DROP CONSTRAINT memberships_pk;
ALTER TABLE ONLY public.membership_legend_customization DROP CONSTRAINT membership_legend_customization_pk;
ALTER TABLE ONLY public.media_storage_priority DROP CONSTRAINT media_storage_priority_pk;
ALTER TABLE ONLY public.media_storage DROP CONSTRAINT media_storage_pk;
ALTER TABLE ONLY public.media_metadata DROP CONSTRAINT media_metadata_pkey;
ALTER TABLE ONLY public.live_event_participants DROP CONSTRAINT live_event_participants_pkey;
ALTER TABLE ONLY public.known_relays DROP CONSTRAINT known_relays_pkey;
ALTER TABLE ONLY public.id_table DROP CONSTRAINT id_table_pkey;
ALTER TABLE ONLY public.human_override DROP CONSTRAINT human_override_pkey;
ALTER TABLE ONLY public.follow_lists DROP CONSTRAINT follow_lists_pkey;
ALTER TABLE ONLY public.filterlist DROP CONSTRAINT filterlist_pkey;
ALTER TABLE ONLY public.fetcher_relays DROP CONSTRAINT fetcher_relays_pk;
ALTER TABLE ONLY public.event_thread_parents_1_e17bf16c98 DROP CONSTRAINT event_thread_parents_1_e17bf16c98_pkey;
ALTER TABLE ONLY public.event_stats_2 DROP CONSTRAINT event_stats_2_pkey;
ALTER TABLE ONLY public.event_sentiment_1_d3d7a00a54 DROP CONSTRAINT event_sentiment_1_d3d7a00a54_pkey;
ALTER TABLE ONLY public.event_relays DROP CONSTRAINT event_relays_pkey;
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
ALTER TABLE ONLY public.counter_by_bytea DROP CONSTRAINT counter_by_bytea_pkey;
ALTER TABLE ONLY public.contact_lists_1_1abdf474bd DROP CONSTRAINT contact_lists_1_1abdf474bd_pkey;
ALTER TABLE ONLY public.cmr_words DROP CONSTRAINT cmr_words_pkey;
ALTER TABLE ONLY public.cmr_words_2 DROP CONSTRAINT cmr_words_2_pkey;
ALTER TABLE ONLY public.cmr_threads DROP CONSTRAINT cmr_threads_pkey;
ALTER TABLE ONLY public.cmr_hashtags DROP CONSTRAINT cmr_hashtags_pkey;
ALTER TABLE ONLY public.cmr_hashtags_2 DROP CONSTRAINT cmr_hashtags_2_pkey;
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
DROP SEQUENCE studio.idx_seq;
DROP VIEW public.zap_receipts;
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
DROP TABLE public.text_metadata;
DROP TABLE public.test_pubkeys;
DROP TABLE public.stuff;
DROP TABLE public.score_expiry;
DROP TABLE public.scheduled_hooks;
DROP TABLE public.replaceable_events;
DROP TABLE public.relays;
DROP TABLE public.relay_url_map;
DROP VIEW public.relay_list_metadata;
DROP TABLE public.reads_versions_11_fb53a8e0b4;
DROP VIEW public.reads_versions;
DROP TABLE public.reads_11_2a4d2ce519;
DROP VIEW public.reads;
DROP VIEW public.pubkey_zapped;
DROP TABLE public.pubkey_trustrank;
DROP VIEW public.pubkey_notifications;
DROP VIEW public.pubkey_notification_cnts;
DROP TABLE public.pubkey_notification_cnts_1_d78f6fcade;
DROP VIEW public.pubkey_media_cnt;
DROP VIEW public.pubkey_ln_address;
DROP VIEW public.pubkey_ids;
DROP VIEW public.pubkey_followers_cnt;
DROP VIEW public.pubkey_followers;
DROP VIEW public.pubkey_events;
DROP VIEW public.pubkey_directmsgs_cnt;
DROP TABLE public.pubkey_directmsgs_cnt_1_efdf9742a6;
DROP VIEW public.pubkey_directmsgs;
DROP VIEW public.pubkey_content_zap_cnt;
DROP TABLE public.pubkey_bookmarks;
DROP VIEW public.preview;
DROP TABLE public.preview_1_44299731c7;
DROP VIEW public.parametrized_replaceable_events;
DROP VIEW public.parameterized_replaceable_list;
DROP VIEW public.og_zap_receipts;
DROP TABLE public.notification_types;
DROP VIEW public.note_stats;
DROP VIEW public.note_length;
DROP TABLE public.node_outputs_1_cfe6037c9f;
DROP TABLE public.muted_threads;
DROP VIEW public.mute_lists;
DROP VIEW public.mute_list_2;
DROP VIEW public.mute_list;
DROP VIEW public.meta_data;
DROP TABLE public.memberships;
DROP TABLE public.membership_legend_customization;
DROP TABLE public.media_storage_priority;
DROP TABLE public.media_storage;
DROP TABLE public.media_metadata;
DROP VIEW public.media;
DROP TABLE public.media_1_16fa35f2dc;
DROP TABLE public.logs_1_d241bdb71c;
DROP TABLE public.live_event_participants;
DROP TABLE public.lists;
DROP TABLE public.known_relays;
DROP TABLE public.id_table;
DROP TABLE public.human_override;
DROP VIEW public.hashtags;
DROP TABLE public.follow_lists;
DROP SEQUENCE public.id_seq;
DROP TABLE public.filterlist_pubkey;
DROP TABLE public.filterlist;
DROP TABLE public.fetcher_relays;
DROP VIEW public.events;
DROP VIEW public.event_zapped;
DROP VIEW public.event_thread_parents;
DROP VIEW public.event_tags;
DROP VIEW public.event_stats_by_pubkey;
DROP TABLE public.event_stats_2;
DROP VIEW public.event_stats;
DROP VIEW public.event_sentiment;
DROP VIEW public.event_replies;
DROP TABLE public.event_relays;
DROP TABLE public.event_relay;
DROP VIEW public.event_pubkey_actions;
DROP VIEW public.event_pubkey_action_refs;
DROP VIEW public.event_preview;
DROP TABLE public.event_preview_1_310cef356e;
DROP TABLE public.event_mentions_1_6738bfddaf;
DROP TABLE public.event_mentions_1_0b730615c4;
DROP VIEW public.event_mentions;
DROP VIEW public.event_media;
DROP TABLE public.event_media_1_30bf07e9cf;
DROP TABLE public.event_hooks;
DROP VIEW public.event_hashtags;
DROP VIEW public.event_created_at;
DROP VIEW public.event_attributes;
DROP TABLE public.dvm_feeds;
DROP VIEW public.deleted_events;
DROP TABLE public.daily_followers_cnt_increases;
DROP TABLE public.dag_1_4bd2aaff98;
DROP TABLE public.coverages_1_8656fc443b;
DROP TABLE public.counter_by_bytea;
DROP VIEW public.contact_lists;
DROP TABLE public.cmr_words_2;
DROP TABLE public.cmr_words;
DROP TABLE public.cmr_threads;
DROP TABLE public.cmr_pubkeys_scopes;
DROP TABLE public.cmr_pubkeys_parent;
DROP TABLE public.cmr_pubkeys_allowed;
DROP TABLE public.cmr_hashtags_2;
DROP TABLE public.cmr_hashtags;
DROP TABLE public.cmr_groups;
DROP TABLE public.cache;
DROP VIEW public.bookmarks;
DROP SEQUENCE public.basic_tags_6_62c3d17c2f_i_seq;
DROP VIEW public.basic_tags;
DROP VIEW public.allow_list;
DROP SEQUENCE public.advsearch_5_d7da6f551e_i_seq;
DROP VIEW public.advsearch;
DROP SEQUENCE public.a_tags_1_7d98c5333f_i_seq;
DROP VIEW public.a_tags;
DROP VIEW prod.zap_receipts;
DROP TABLE public.zap_receipts_1_9fe40119b2;
DROP VIEW prod.relay_list_metadata;
DROP TABLE public.relay_list_metadata_1_801a17fc93;
DROP VIEW prod.reads_versions;
DROP TABLE public.reads_versions_12_b537d4df66;
DROP VIEW prod.reads;
DROP TABLE public.reads_12_68c6bbfccd;
DROP VIEW prod.pubkey_zapped;
DROP TABLE public.pubkey_zapped_1_17f1f622a9;
DROP VIEW prod.pubkey_notifications;
DROP TABLE public.pubkey_notifications_1_e5459ab9dd;
DROP VIEW prod.pubkey_media_cnt;
DROP TABLE public.pubkey_media_cnt_1_b5e2a488b1;
DROP VIEW prod.pubkey_ln_address;
DROP TABLE public.pubkey_ln_address_1_d3649b2898;
DROP VIEW prod.pubkey_ids;
DROP TABLE public.pubkey_ids_1_54b55dd09c;
DROP VIEW prod.pubkey_followers_cnt;
DROP TABLE public.pubkey_followers_cnt_1_a6f7e200e7;
DROP VIEW prod.pubkey_followers;
DROP TABLE public.pubkey_followers_1_d52305fb47;
DROP VIEW prod.pubkey_events;
DROP TABLE public.pubkey_events_1_1dcbfe1466;
DROP VIEW prod.pubkey_directmsgs;
DROP TABLE public.pubkey_directmsgs_1_c794110a2c;
DROP VIEW prod.pubkey_content_zap_cnt;
DROP TABLE public.pubkey_content_zap_cnt_1_236df2f369;
DROP VIEW prod.parametrized_replaceable_events;
DROP TABLE public.parametrized_replaceable_events_1_cbe75c8d53;
DROP VIEW prod.parameterized_replaceable_list;
DROP TABLE public.parameterized_replaceable_list_1_d02d7ecc62;
DROP VIEW prod.og_zap_receipts;
DROP TABLE public.og_zap_receipts_1_dc85307383;
DROP VIEW prod.note_stats;
DROP TABLE public.note_stats_1_07d205f278;
DROP VIEW prod.note_length;
DROP TABLE public.note_length_1_15d66ffae6;
DROP VIEW prod.mute_lists;
DROP TABLE public.mute_lists_1_d90e559628;
DROP VIEW prod.mute_list_2;
DROP TABLE public.mute_list_2_1_949b3d746b;
DROP VIEW prod.mute_list;
DROP TABLE public.mute_list_1_f693a878b9;
DROP VIEW prod.meta_data;
DROP TABLE public.meta_data_1_323bc43167;
DROP VIEW prod.hashtags;
DROP TABLE public.hashtags_1_1e5c72161a;
DROP VIEW prod.events;
DROP VIEW prod.event_zapped;
DROP TABLE public.event_zapped_1_7ebdbebf92;
DROP VIEW prod.event_thread_parents;
DROP TABLE public.event_thread_parents_1_e17bf16c98;
DROP VIEW prod.event_stats_by_pubkey;
DROP TABLE public.event_stats_by_pubkey_1_4ecc48a026;
DROP VIEW prod.event_stats;
DROP TABLE public.event_stats_1_1b380f4869;
DROP VIEW prod.event_sentiment;
DROP TABLE public.event_sentiment_1_d3d7a00a54;
DROP VIEW prod.event_replies;
DROP TABLE public.event_replies_1_9d033b5bb3;
DROP VIEW prod.event_pubkey_actions;
DROP TABLE public.event_pubkey_actions_1_d62afee35d;
DROP VIEW prod.event_pubkey_action_refs;
DROP TABLE public.event_pubkey_action_refs_1_f32e1ff589;
DROP VIEW prod.event_mentions;
DROP TABLE public.event_mentions_1_a056fb6737;
DROP VIEW prod.event_hashtags;
DROP TABLE public.event_hashtags_1_295f217c0e;
DROP VIEW prod.event_created_at;
DROP TABLE public.event_created_at_1_7a51e16c5c;
DROP VIEW prod.event_attributes;
DROP TABLE public.event_attributes_1_3196ca546f;
DROP VIEW prod.deleted_events;
DROP TABLE public.deleted_events_1_0249f47b16;
DROP VIEW prod.contact_lists;
DROP TABLE public.contact_lists_1_1abdf474bd;
DROP VIEW prod.bookmarks;
DROP TABLE public.bookmarks_1_43f5248b56;
DROP VIEW prod.basic_tags;
DROP TABLE public.basic_tags_6_62c3d17c2f;
DROP VIEW prod.allow_list;
DROP TABLE public.allow_list_1_f1da08e9c8;
DROP VIEW prod.advsearch;
DROP TABLE public.advsearch_5_d7da6f551e;
DROP VIEW prod.a_tags;
DROP TABLE public.a_tags_1_7d98c5333f;
DROP SEQUENCE cache.id_seq;
DROP SEQUENCE agent.knowledge_id_seq;
DROP FUNCTION public.zap_response(r record, a_user_pubkey bytea);
DROP FUNCTION public.wsconntasks(a_port bigint);
DROP FUNCTION public.user_live_events(a_kind bigint, a_pubkey bytea);
DROP FUNCTION public.user_is_human(a_pubkey bytea, a_user_pubkey bytea);
DROP FUNCTION public.user_is_human(a_pubkey bytea);
DROP FUNCTION public.user_infos(a_pubkeys text[]);
DROP FUNCTION public.user_infos(a_pubkeys bytea[]);
DROP FUNCTION public.user_has_bio(a_pubkey bytea);
DROP FUNCTION public.user_follows_posts(a_pubkey bytea, a_since bigint, a_until bigint, a_include_replies bigint, a_limit bigint, a_offset bigint);
DROP FUNCTION public.user_blossom_servers(a_pubkeys bytea[]);
DROP FUNCTION public.user_blossom_relays(a_pubkeys bytea[]);
DROP PROCEDURE public.update_user_relative_daily_follower_count_increases();
DROP FUNCTION public.update_updated_at();
DROP FUNCTION public.try_cast_jsonb(a_json text, a_default jsonb);
DROP FUNCTION public.trusted_nostr_users(a_period character varying);
DROP FUNCTION public.thread_view_reply_posts(a_event_id bytea, a_limit bigint, a_since bigint, a_until bigint, a_offset bigint);
DROP FUNCTION public.thread_view_parent_posts(a_event_id bytea);
DROP FUNCTION public.thread_view(a_event_id bytea, a_limit bigint, a_since bigint, a_until bigint, a_offset bigint, a_user_pubkey bytea, a_apply_humaness_check boolean, a_include_parent_posts boolean);
DROP FUNCTION public.test_pubkeys(a_name text);
DROP FUNCTION public.safe_jsonb(data text);
DROP FUNCTION public.safe_json(i text, fallback jsonb);
DROP FUNCTION public.response_messages_for_post(a_event_id bytea, a_user_pubkey bytea, a_is_referenced_event boolean, a_depth bigint);
DROP FUNCTION public.referenced_event_is_note(a_event_id bytea);
DROP PROCEDURE public.record_trusted_pubkey_followers_cnt();
DROP FUNCTION public.raise_notice(a text);
DROP FUNCTION public.primal_verified_names(a_pubkeys bytea[]);
DROP FUNCTION public.notification_is_visible(type bigint, arg1 bytea, arg2 bytea, arg3 jsonb, a_user_pubkey bytea);
DROP FUNCTION public.long_form_content_feed(a_pubkey bytea, a_notes character varying, a_topic character varying, a_curation character varying, a_minwords bigint, a_limit bigint, a_since bigint, a_until bigint, a_offset bigint, a_user_pubkey bytea, a_apply_humaness_check boolean);
DROP FUNCTION public.live_feed_posts(a_kind bigint, a_pubkey bytea, a_identifier character varying, a_limit bigint);
DROP FUNCTION public.live_feed_initial_response(a_kind bigint, a_pubkey bytea, a_identifier character varying, a_user_pubkey bytea, a_limit bigint, a_apply_humaness_check boolean);
DROP FUNCTION public.is_pubkey_hidden_by_group(a_user_pubkey bytea, a_scope public.cmr_scope, a_pubkey bytea, a_cmr_grp public.cmr_grp, a_fl_grp public.filterlist_grp);
DROP FUNCTION public.is_pubkey_hidden(a_user_pubkey bytea, a_scope public.cmr_scope, a_pubkey bytea);
DROP FUNCTION public.is_event_hidden(a_user_pubkey bytea, a_scope public.cmr_scope, a_event_id bytea);
DROP FUNCTION public.humaness_threshold_trustrank();
DROP FUNCTION public.get_media_url(a_url character varying);
DROP FUNCTION public.get_event_jsonb(a_event_id bytea);
DROP FUNCTION public.get_event(a_event_id bytea);
DROP TABLE public.event;
DROP FUNCTION public.get_bookmarks(a_pubkey bytea);
DROP FUNCTION public.fetch_results_for_user_follows_posts(a_pubkey bytea, a_include_replies bigint, p_since bigint, p_until bigint, p_limit integer, p_offset integer, p_dt bigint, p_timeout numeric);
DROP FUNCTION public.feed_user_follows(a_pubkey bytea, a_since bigint, a_until bigint, a_include_replies bigint, a_limit bigint, a_offset bigint, a_user_pubkey bytea, a_apply_humaness_check boolean);
DROP FUNCTION public.feed_user_authored(a_pubkey bytea, a_since bigint, a_until bigint, a_include_replies bigint, a_limit bigint, a_offset bigint, a_user_pubkey bytea, a_apply_humaness_check boolean);
DROP FUNCTION public.extract_bolt11_tag(tags jsonb);
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
DROP FUNCTION public.c_studio_home_totals();
DROP FUNCTION public.c_studio_home_top_notes();
DROP FUNCTION public.c_studio_home_top_articles();
DROP FUNCTION public.c_studio_home_graph();
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
DROP EXTENSION vector;
DROP EXTENSION pg_relusage;
DROP EXTENSION pg_primal;
DROP EXTENSION pg_hint_plan;
DROP EXTENSION http;
DROP EXTENSION hstore;
DROP EXTENSION dblink;
DROP EXTENSION amcheck;
DROP EXTENSION age;
DROP EXTENSION plv8;
DROP EXTENSION pljava;
DROP SCHEMA studio;
DROP SCHEMA sqlj;
DROP SCHEMA prod;
DROP SCHEMA plrust;
DROP SCHEMA hint_plan;
DROP EXTENSION pg_cron;
DROP SCHEMA cache;
DROP SCHEMA agent;
DROP SCHEMA ag_catalog;
--
-- Name: ag_catalog; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA ag_catalog;


--
-- Name: agent; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA agent;


--
-- Name: cache; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA cache;


--
-- Name: pg_cron; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;


--
-- Name: EXTENSION pg_cron; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_cron IS 'Job scheduler for PostgreSQL';


--
-- Name: hint_plan; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA hint_plan;


--
-- Name: plrust; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA plrust;


--
-- Name: prod; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA prod;


--
-- Name: sqlj; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA sqlj;


--
-- Name: studio; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA studio;


--
-- Name: pljava; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pljava WITH SCHEMA sqlj;


--
-- Name: EXTENSION pljava; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pljava IS 'PL/Java procedural language (https://tada.github.io/pljava/)';


--
-- Name: plv8; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS plv8 WITH SCHEMA pg_catalog;


--
-- Name: EXTENSION plv8; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION plv8 IS 'PL/JavaScript (v8) trusted procedural language';


--
-- Name: age; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS age WITH SCHEMA ag_catalog;


--
-- Name: EXTENSION age; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION age IS 'AGE database extension';


--
-- Name: amcheck; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS amcheck WITH SCHEMA public;


--
-- Name: EXTENSION amcheck; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION amcheck IS 'functions for verifying relation integrity';


--
-- Name: dblink; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS dblink WITH SCHEMA public;


--
-- Name: EXTENSION dblink; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION dblink IS 'connect to other PostgreSQL databases from within a database';


--
-- Name: hstore; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS hstore WITH SCHEMA public;


--
-- Name: EXTENSION hstore; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION hstore IS 'data type for storing sets of (key, value) pairs';


--
-- Name: http; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS http WITH SCHEMA public;


--
-- Name: EXTENSION http; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION http IS 'HTTP client for PostgreSQL, allows web page retrieval inside the database.';


--
-- Name: pg_hint_plan; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_hint_plan WITH SCHEMA hint_plan;


--
-- Name: pg_primal; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_primal WITH SCHEMA public;


--
-- Name: EXTENSION pg_primal; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_primal IS 'pg_primal:  Created by pgrx';


--
-- Name: pg_relusage; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_relusage WITH SCHEMA public;


--
-- Name: EXTENSION pg_relusage; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_relusage IS 'Log all the queries that reference a particular column';


--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


--
-- Name: cmr_grp; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.cmr_grp AS ENUM (
    'primal_spam',
    'primal_nsfw'
);


--
-- Name: cmr_scope; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.cmr_scope AS ENUM (
    'content',
    'trending'
);


--
-- Name: filterlist_grp; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.filterlist_grp AS ENUM (
    'spam',
    'nsfw',
    'csam',
    'impersonation'
);


--
-- Name: filterlist_target; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.filterlist_target AS ENUM (
    'pubkey',
    'event'
);


--
-- Name: media_size; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.media_size AS ENUM (
    'original',
    'small',
    'medium',
    'large'
);


--
-- Name: post; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.post AS (
	event_id bytea,
	created_at bigint
);


--
-- Name: response_messages_for_post_res; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.response_messages_for_post_res AS (
	e jsonb,
	is_referenced_event boolean
);


--
-- Name: c_collection_order(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_collection_order() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000161$$;


--
-- Name: c_event_actions_count(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_event_actions_count() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000115$$;


--
-- Name: c_event_relays(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_event_relays() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000141$$;


--
-- Name: c_event_stats(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_event_stats() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000100$$;


--
-- Name: c_link_metadata(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_link_metadata() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000128$$;


--
-- Name: c_long_form_metadata(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_long_form_metadata() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000144$$;


--
-- Name: c_media_metadata(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_media_metadata() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000119$$;


--
-- Name: c_membership_cohorts(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_membership_cohorts() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000169$$;


--
-- Name: c_membership_legend_customization(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_membership_legend_customization() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000168$$;


--
-- Name: c_range(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_range() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000113$$;


--
-- Name: c_referenced_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_referenced_event() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000107$$;


--
-- Name: c_studio_home_graph(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_studio_home_graph() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000902$$;


--
-- Name: c_studio_home_top_articles(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_studio_home_top_articles() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000904$$;


--
-- Name: c_studio_home_top_notes(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_studio_home_top_notes() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000903$$;


--
-- Name: c_studio_home_totals(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_studio_home_totals() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000901$$;


--
-- Name: c_user_follower_counts(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_user_follower_counts() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000133$$;


--
-- Name: c_user_primal_names(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_user_primal_names() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000158$$;


--
-- Name: c_user_scores(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_user_scores() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000108$$;


--
-- Name: c_zap_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_zap_event() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000129$$;


--
-- Name: content_moderation_filtering(jsonb, public.cmr_scope, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.content_moderation_filtering(a_results jsonb, a_scope public.cmr_scope, a_user_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
SELECT e 
FROM jsonb_array_elements(a_results) r(e) 
WHERE (e->>'pubkey' IS NULL OR NOT is_pubkey_hidden(a_user_pubkey, a_scope, DECODE(e->>'pubkey', 'hex'))) AND
      (e->>'id' IS NULL OR NOT EXISTS (
        SELECT 1 FROM cmr_pubkeys_scopes cmr, basic_tags bt
        WHERE bt.id = DECODE(e->>'id', 'hex') AND bt.tag = 'p' AND bt.arg1 = cmr.pubkey 
          AND cmr.user_pubkey = a_user_pubkey and cmr.scope = a_scope
        LIMIT 1))
$$;


--
-- Name: count_jsonb_keys(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.count_jsonb_keys(j jsonb) RETURNS bigint
    LANGUAGE sql
    AS $$ SELECT count(*) from (SELECT jsonb_object_keys(j)) v $$;


--
-- Name: enrich_feed_events(public.post[], bytea, boolean, character varying); Type: FUNCTION; Schema: public; Owner: -
--

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
        a_posts_sorted := ARRAY (SELECT (event_id, created_at)::post FROM UNNEST(a_posts) p GROUP BY event_id, created_at ORDER BY created_at DESC);
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

                IF a_apply_humaness_check AND NOT t.is_referenced_event AND e_kind != 0 AND NOT user_is_human(e_pubkey, a_user_pubkey) THEN
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
                END IF;

                IF e_kind = 1 OR e_kind = 30023 OR e_kind = 0 THEN
                    FOR r IN SELECT * FROM event_relay WHERE event_id = e_id LOOP
                        relay_url := r.relay_url;
                        FOR r IN SELECT dest FROM relay_url_map WHERE src = relay_url LIMIT 1 LOOP
                            relay_url := r.dest;
                        END LOOP;
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
                    -- RETURN QUERY SELECT get_event_jsonb(value) FROM contact_lists WHERE key = e_pubkey LIMIT 1; -- bugs prod ios app
                    -- RETURN QUERY SELECT get_event_jsonb(event_id) FROM relay_list_metadata WHERE pubkey = e_pubkey LIMIT 1;
                    RETURN QUERY SELECT * FROM user_live_events(30311, e_pubkey);
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
        RETURN QUERY SELECT * FROM user_blossom_servers(pubkeys);
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


--
-- Name: enrich_feed_events_(public.post[], bytea, boolean); Type: FUNCTION; Schema: public; Owner: -
--

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


--
-- Name: event_action_cnt(bytea, bytea); Type: FUNCTION; Schema: public; Owner: -
--

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


--
-- Name: event_is_deleted(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.event_is_deleted(a_event_id bytea) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
SELECT EXISTS (SELECT 1 FROM deleted_events WHERE event_id = a_event_id)
$$;


--
-- Name: event_media_response(bytea); Type: FUNCTION; Schema: public; Owner: -
--

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
            FOR r IN SELECT * FROM get_media_url(r_url) LOOP
                variants := variants || jsonb_build_array(jsonb_build_object(
                        's', SUBSTR(r.size, 1, 1),
                        'a', r.animated,
                        'w', r.width,
                        'h', r.height,
                        'mt', r.mimetype,
                        'dur', r.duration,
                        'media_url', r.media_url));
                root_mt := r.mimetype;
            END LOOP;
            resources := resources || jsonb_build_array(jsonb_build_object(
                    'url', r_url,
                    'variants', variants,
                    'mt', root_mt));
            FOR r_thumbnail_url IN 
                SELECT mu.media_url FROM video_thumbnails vt, get_media_url(vt.thumbnail_url) mu WHERE vt.video_url = r_url LOOP
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


--
-- Name: event_preview_response(bytea); Type: FUNCTION; Schema: public; Owner: -
--

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


--
-- Name: event_stats(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.event_stats(a_event_id bytea) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
	SELECT jsonb_build_object('kind', c_EVENT_STATS(), 'content', row_to_json(a)::text)
	FROM (
		SELECT ENCODE(a_event_id, 'hex') as event_id, likes, replies, mentions, reposts, zaps, satszapped, score, score24h, 0 as bookmarks
		FROM event_stats WHERE event_id = a_event_id
		LIMIT 1
	) a
$$;


--
-- Name: event_stats_for_long_form_content(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.event_stats_for_long_form_content(a_event_id bytea) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
	SELECT jsonb_build_object('kind', c_EVENT_STATS(), 'content', row_to_json(a)::text)
	FROM (
        SELECT ENCODE(a_event_id, 'hex') as event_id, likes, replies, 0 AS mentions, reposts, zaps, satszapped, 0 AS score, 0 AS score24h, 0 as bookmarks
        FROM reads WHERE latest_eid = a_event_id LIMIT 1
	) a
$$;


--
-- Name: event_zap_by_zap_receipt_id(bytea, bytea); Type: FUNCTION; Schema: public; Owner: -
--

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


--
-- Name: event_zaps(bytea, bytea); Type: FUNCTION; Schema: public; Owner: -
--

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


--
-- Name: event_zaps(bytea, character varying, bytea); Type: FUNCTION; Schema: public; Owner: -
--

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


--
-- Name: extract_bolt11_tag(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.extract_bolt11_tag(tags jsonb) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$
select elem ->> 1
from jsonb_array_elements(tags) as elem
where elem ->> 0 = 'bolt11'
limit 1
$$;


--
-- Name: feed_user_authored(bytea, bigint, bigint, bigint, bigint, bigint, bytea, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.feed_user_authored(a_pubkey bytea, a_since bigint, a_until bigint, a_include_replies bigint, a_limit bigint, a_offset bigint, a_user_pubkey bytea, a_apply_humaness_check boolean) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM filterlist WHERE grp in ('csam', 'impersonation') AND target_type = 'pubkey' AND target = a_pubkey AND blocked LIMIT 1) THEN
        RETURN;
    END IF;

    RETURN QUERY SELECT * FROM enrich_feed_events(
        ARRAY (
            select (pe.event_id, pe.created_at)::post
            from 
                pubkey_events pe
            where 
                pe.pubkey = a_pubkey and pe.created_at >= a_since and pe.created_at <= a_until and pe.is_reply = a_include_replies and
                referenced_event_is_note(pe.event_id)
            order by pe.created_at desc limit a_limit offset a_offset
        ),
        a_user_pubkey, a_apply_humaness_check);
END
$$;


--
-- Name: feed_user_follows(bytea, bigint, bigint, bigint, bigint, bigint, bytea, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.feed_user_follows(a_pubkey bytea, a_since bigint, a_until bigint, a_include_replies bigint, a_limit bigint, a_offset bigint, a_user_pubkey bytea, a_apply_humaness_check boolean) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
-- select raise_notice((a_pubkey, a_since, a_until, a_include_replies, a_limit, a_offset, a_user_pubkey, a_apply_humaness_check)::text);
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


--
-- Name: fetch_results_for_user_follows_posts(bytea, bigint, bigint, bigint, integer, integer, bigint, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fetch_results_for_user_follows_posts(a_pubkey bytea, a_include_replies bigint, p_since bigint, p_until bigint, p_limit integer, p_offset integer, p_dt bigint DEFAULT (1 * 3600), p_timeout numeric DEFAULT 7.0) RETURNS SETOF public.post
    LANGUAGE plpgsql
    AS $$
DECLARE
    dt_start bigint := p_dt;
    t_start  timestamp := clock_timestamp();
    t_end    timestamp := t_start + (p_timeout || ' seconds')::interval;
    t        bigint := p_until;
    done     boolean := false;
    current_timeout int;
    r        post;
    rs       post[] := ARRAY[]::post[];
    ids      bytea[] := ARRAY[]::bytea[];
    i        bigint;
BEGIN
    PERFORM set_config('statement_timeout', trunc(p_timeout * 1000)::text, true);
    WHILE (
        (array_length(rs, 1) is null OR array_length(rs, 1) < (p_limit + p_offset))
        AND p_since <= t
        AND clock_timestamp() < t_end
        AND NOT done
        )
        LOOP
            current_timeout := trunc(extract(epoch FROM (t_end - clock_timestamp())) * 1000);
            RAISE NOTICE 'current_timeout: %', current_timeout;
            IF current_timeout < 0 THEN
                RAISE NOTICE 'exit0';
                EXIT;
            END IF;

            BEGIN
                RAISE NOTICE 't: % .. % [ % h ]', t - p_dt, t, p_dt/3600;
                i := 0;
                FOR r IN SELECT pe.event_id, pe.created_at
                         FROM pubkey_events pe, pubkey_followers pf
                         WHERE
                             pf.follower_pubkey = a_pubkey AND
                             pf.pubkey = pe.pubkey AND
                             pe.created_at >= t - p_dt AND
                             pe.created_at <= t AND
                             (
                                 pe.is_reply = 0 OR
                                 pe.is_reply = a_include_replies
                             )
                           AND referenced_event_is_note(pe.event_id)
                         ORDER BY pe.created_at DESC LIMIT p_limit
                    LOOP
                        IF array_length(rs, 1) is not null AND array_length(rs, 1) >= (p_limit + p_offset)
                            OR clock_timestamp() >= t_end
                            OR done THEN
                            RAISE NOTICE 'exit1';
                            EXIT;
                        END IF;

                        IF NOT (r.event_id = ANY(ids)) THEN
                            ids := array_append(ids, r.event_id);
                            rs  := array_append(rs, r);
                            i   := i + 1;
                            RETURN NEXT r;
                            -- (If you need to signal early termination, you might set done := true here.)
                        END IF;
                    END LOOP;
            EXCEPTION WHEN query_canceled THEN
                RAISE NOTICE 'exit2';
                EXIT;
            END;

            IF i > 0 THEN
                t := rs[array_length(rs, 1)].created_at;
                p_dt := dt_start;
            ELSE
                t := t - p_dt;
                p_dt := p_dt * 4;
            END IF;
        END LOOP;

--     RETURN QUERY SELECT * from unnest(rs) OFFSET p_offset;
END;
$$;


--
-- Name: get_bookmarks(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_bookmarks(a_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
SELECT get_event_jsonb(event_id) FROM bookmarks WHERE pubkey = a_pubkey;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: event; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: get_event(bytea); Type: FUNCTION; Schema: public; Owner: -
--

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


--
-- Name: get_event_jsonb(bytea); Type: FUNCTION; Schema: public; Owner: -
--

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


--
-- Name: get_media_url(character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_media_url(a_url character varying) RETURNS TABLE(size character varying, animated bigint, width bigint, height bigint, mimetype character varying, duration double precision, media_url character varying)
    LANGUAGE sql
    AS $$
select distinct on (m.animated, m.media_url)
   sz.oldsize, m.animated, m.width, m.height, m.mimetype, m.duration, 
   case when (ms.media_url is not null and msp.storage_provider is not null) then ms.media_url
   else m.media_url
   end as media_url
from (values ('small', 'medium'), ('medium', 'large'), ('large', 'large'), ('original', 'original')) sz(oldsize, newsize),
     media m
       left join media_storage ms on ms.h = split_part(split_part(m.media_url, '/', -1), '.', 1)
       left join media_storage_priority msp on ms.storage_provider = msp.storage_provider
where m.url = a_url and m.size = sz.newsize and ms.media_block_id is null
order by m.animated desc, m.media_url, msp.priority
$$;


--
-- Name: humaness_threshold_trustrank(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.humaness_threshold_trustrank() RETURNS real
    LANGUAGE sql STABLE
    AS $$select rank from pubkey_trustrank order by rank desc limit 1 offset 50000$$;


--
-- Name: is_event_hidden(bytea, public.cmr_scope, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_event_hidden(a_user_pubkey bytea, a_scope public.cmr_scope, a_event_id bytea) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
SELECT EXISTS (
    SELECT 1
    FROM public.event e
    WHERE e.id = a_event_id AND (
        public.is_pubkey_hidden(a_user_pubkey, a_scope, e.pubkey)

        -- Check for muted words in content
        OR EXISTS (
            SELECT 1
            FROM public.cmr_words_2 w, advsearch s
            WHERE w.user_pubkey = a_user_pubkey
              AND w.scope = a_scope
              AND s.id = a_event_id
              AND s.content_tsv @@ w.words
        )

        -- Check for muted hashtags
        OR EXISTS (
            SELECT 1
            FROM public.cmr_hashtags_2 h, advsearch s
            WHERE h.user_pubkey = a_user_pubkey
              AND h.scope = a_scope
              AND s.id = a_event_id
              AND s.hashtag_tsv @@ h.hashtags
        )

        -- Check if the event *is* a muted thread root
        OR EXISTS (
            SELECT 1
            FROM public.cmr_threads t
            WHERE t.user_pubkey = a_user_pubkey
              AND t.scope = a_scope
              AND t.event_id = e.id
        )

        -- Check if the event *references* a muted thread root using the basic_tags table
        OR EXISTS (
            SELECT 1
            FROM public.basic_tags bt
            INNER JOIN public.cmr_threads t ON t.user_pubkey = a_user_pubkey AND t.scope = a_scope
            WHERE bt.id = a_event_id
              AND bt.tag = 'e'
              AND bt.arg1 = t.event_id
        )
    )
)
$$;


--
-- Name: is_pubkey_hidden(bytea, public.cmr_scope, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_pubkey_hidden(a_user_pubkey bytea, a_scope public.cmr_scope, a_pubkey bytea) RETURNS boolean
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM filterlist WHERE target = a_pubkey AND target_type = 'pubkey' AND blocked AND grp = 'impersonation') THEN
        RETURN true;
    END IF;

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


--
-- Name: is_pubkey_hidden_by_group(bytea, public.cmr_scope, bytea, public.cmr_grp, public.filterlist_grp); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_pubkey_hidden_by_group(a_user_pubkey bytea, a_scope public.cmr_scope, a_pubkey bytea, a_cmr_grp public.cmr_grp, a_fl_grp public.filterlist_grp) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
SELECT
    EXISTS (
        SELECT 1 FROM cmr_groups cmr, filterlist fl
        WHERE 
            cmr.user_pubkey = a_user_pubkey AND cmr.grp = a_cmr_grp AND cmr.scope = a_scope AND 
            fl.target = a_pubkey AND fl.target_type = 'pubkey' AND fl.blocked AND fl.grp = a_fl_grp AND
            NOT EXISTS (SELECT 1 FROM filterlist fl2 WHERE fl2.target = a_pubkey AND fl2.target_type = 'pubkey' AND NOT fl2.blocked))
$$;


--
-- Name: live_feed_initial_response(bigint, bytea, character varying, bytea, bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.live_feed_initial_response(a_kind bigint, a_pubkey bytea, a_identifier character varying, a_user_pubkey bytea, a_limit bigint DEFAULT 20, a_apply_humaness_check boolean DEFAULT true) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    -- RETURN QUERY SELECT * FROM enrich_feed_events(
    --     ARRAY (
    --         SELECT r
    --         FROM live_feed_posts(
    --             a_kind,
    --             a_pubkey,
    --             a_identifier,
    --             a_limit
    --         ) r),
    --     a_user_pubkey, a_apply_humaness_check);
    RETURN QUERY SELECT get_event_jsonb(r.event_id) FROM live_feed_posts(
                a_kind,
                a_pubkey,
                a_identifier,
                a_limit
            ) r;

    RETURN QUERY SELECT get_event_jsonb(eid)
        FROM a_tags 
        WHERE kind in (7, 9735)
          AND ref_kind = a_kind AND ref_pubkey = a_pubkey AND ref_identifier = a_identifier
        ORDER BY created_at DESC LIMIT 1000;
END
$$;


--
-- Name: live_feed_posts(bigint, bytea, character varying, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.live_feed_posts(a_kind bigint, a_pubkey bytea, a_identifier character varying, a_limit bigint DEFAULT 20) RETURNS SETOF public.post
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    RETURN QUERY SELECT eid, created_at 
        FROM a_tags 
        WHERE kind = 1311
          AND ref_kind = a_kind AND ref_pubkey = a_pubkey AND ref_identifier = a_identifier
        ORDER BY created_at DESC LIMIT 10000;
END
$$;


--
-- Name: long_form_content_feed(bytea, character varying, character varying, character varying, bigint, bigint, bigint, bigint, bigint, bytea, boolean); Type: FUNCTION; Schema: public; Owner: -
--

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


--
-- Name: notification_is_visible(bigint, bytea, bytea, jsonb, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notification_is_visible(type bigint, arg1 bytea, arg2 bytea, arg3 jsonb, a_user_pubkey bytea) RETURNS boolean
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
    WHEN 8 THEN user_is_human(decode(arg3 #>> '{}', 'hex'), a_user_pubkey)

    WHEN 101 THEN user_is_human(arg2, a_user_pubkey)
    WHEN 102 THEN user_is_human(arg2, a_user_pubkey)
    WHEN 103 THEN user_is_human(arg2, a_user_pubkey)
    WHEN 104 THEN user_is_human(arg2, a_user_pubkey)

    /* WHEN 201 THEN user_is_human(arg3, a_user_pubkey) */
    /* WHEN 202 THEN user_is_human(arg3, a_user_pubkey) */
    /* WHEN 203 THEN user_is_human(arg3, a_user_pubkey) */
    /* WHEN 204 THEN user_is_human(arg3, a_user_pubkey) */

    WHEN 301 THEN user_is_human(arg2, a_user_pubkey)
    WHEN 302 THEN user_is_human(arg2, a_user_pubkey)

    ELSE false
    END CASE
$$;


--
-- Name: primal_verified_names(bytea[]); Type: FUNCTION; Schema: public; Owner: -
--

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
        jsonb_build_object(
            'style', case when style = '' then null else style end,
            'custom_badge', custom_badge, 
            'avatar_glow', avatar_glow,
            'in_leaderboard', in_leaderboard,
            'current_shoutout', case when current_shoutout = '' or current_shoutout is null then 'Supporter of open networks and open source builders'
                                else current_shoutout
                                end
    ))
    INTO r FROM membership_legend_customization WHERE pubkey = ANY(a_pubkeys);
    IF r IS NOT NULL THEN
        RETURN NEXT jsonb_build_object('kind', c_MEMBERSHIP_LEGEND_CUSTOMIZATION(), 'content', r::text);
    END IF;

    SELECT json_object_agg(
        ENCODE(pubkey, 'hex'), 
        jsonb_build_object(
            'cohort_1', cohort_1, 
            'cohort_2', cohort_2, 
            'tier', tier, 
            'expires_on', extract(epoch from valid_until)::int8,
            'legend_since', extract(epoch from least(legend_since, premium_since))::int8,
            'premium_since', extract(epoch from premium_since)::int8
    ))
    INTO r FROM memberships WHERE pubkey = ANY(a_pubkeys) AND 
    (tier = 'premium' or tier = 'premium-legend')
    ;
    IF r IS NOT NULL THEN
        RETURN NEXT jsonb_build_object('kind', c_MEMBERSHIP_COHORTS(), 'content', r::text);
    END IF;
END
$$;


--
-- Name: raise_notice(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.raise_notice(a text) RETURNS void
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
RAISE NOTICE '%', a;
END;
$$;


--
-- Name: record_trusted_pubkey_followers_cnt(); Type: PROCEDURE; Schema: public; Owner: -
--

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


--
-- Name: referenced_event_is_note(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.referenced_event_is_note(a_event_id bytea) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
select
    case
        when es.kind = 1 then true
        when es.kind = 6 then exists (
            select 1 from basic_tags bt, events es2
            where bt.id = a_event_id and bt.tag = 'e' and bt.arg1 = es2.id and es2.kind = 1)
        else false
        end
from events es
where es.id = a_event_id
$$;


--
-- Name: response_messages_for_post(bytea, bytea, boolean, bigint); Type: FUNCTION; Schema: public; Owner: -
--

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

    IF event_is_deleted(e.id) THEN
        RETURN;
    ELSIF EXISTS (
        SELECT 1 FROM pubkey_followers pf 
        WHERE pf.follower_pubkey = a_user_pubkey AND e.pubkey = pf.pubkey
    ) THEN
        -- user follows publisher
    ELSIF is_pubkey_hidden(a_user_pubkey, 'content', e.pubkey) THEN
        RETURN;
    ELSIF is_event_hidden(a_user_pubkey, 'content', a_event_id) THEN
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


--
-- Name: safe_json(text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

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


--
-- Name: safe_jsonb(text); Type: FUNCTION; Schema: public; Owner: -
--

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


--
-- Name: test_pubkeys(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.test_pubkeys(a_name text) RETURNS bytea
    LANGUAGE sql
    AS $$ select pubkey from test_pubkeys where name = a_name $$;


--
-- Name: thread_view(bytea, bigint, bigint, bigint, bigint, bytea, boolean, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.thread_view(a_event_id bytea, a_limit bigint DEFAULT 20, a_since bigint DEFAULT 0, a_until bigint DEFAULT (EXTRACT(epoch FROM now()))::bigint, a_offset bigint DEFAULT 0, a_user_pubkey bytea DEFAULT NULL::bytea, a_apply_humaness_check boolean DEFAULT false, a_include_parent_posts boolean DEFAULT true) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    IF  EXISTS (SELECT 1 FROM filterlist WHERE grp in ('csam', 'impersonation') AND target_type = 'event' AND target = a_event_id AND blocked LIMIT 1) OR
        EXISTS (SELECT 1 FROM events es, filterlist fl WHERE es.id = a_event_id AND fl.target = es.pubkey AND fl.target_type = 'pubkey' AND fl.grp in ('csam', 'impersonation') AND fl.blocked LIMIT 1)
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

    IF a_include_parent_posts THEN
        RETURN QUERY SELECT DISTINCT * FROM enrich_feed_events(
            ARRAY(SELECT r FROM thread_view_parent_posts(a_event_id) r ORDER BY r.created_at), 
            a_user_pubkey, false);
    ELSE
        RETURN QUERY SELECT DISTINCT * FROM enrich_feed_events(
            ARRAY(SELECT (id, created_at)::post FROM events WHERE id = a_event_id),
            a_user_pubkey, a_apply_humaness_check);
    END IF;
END
$$;


--
-- Name: thread_view_parent_posts(bytea); Type: FUNCTION; Schema: public; Owner: -
--

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


--
-- Name: thread_view_reply_posts(bytea, bigint, bigint, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.thread_view_reply_posts(a_event_id bytea, a_limit bigint DEFAULT 20, a_since bigint DEFAULT 0, a_until bigint DEFAULT (EXTRACT(epoch FROM now()))::bigint, a_offset bigint DEFAULT 0) RETURNS SETOF public.post
    LANGUAGE sql STABLE
    AS $$
select reply_event_id, reply_created_at from event_replies
where event_id = a_event_id and reply_created_at >= a_since and reply_created_at <= a_until
order by reply_created_at desc limit a_limit offset a_offset;
$$;


--
-- Name: trusted_nostr_users(character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trusted_nostr_users(a_period character varying) RETURNS TABLE(t date, cnt integer)
    LANGUAGE sql
    AS $$
select date_trunc(a_period, to_timestamp(es.created_at))::date as t, count(distinct es.pubkey) as cnt
from events es, pubkey_trustrank tr
where es.pubkey = tr.pubkey
  and es.created_at >= extract(epoch from now() - interval '6 months')::int8
group by t order by t
$$;


--
-- Name: try_cast_jsonb(text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

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


--
-- Name: update_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
   NEW.updated_at = now();
   RETURN NEW;
END; $$;


--
-- Name: update_user_relative_daily_follower_count_increases(); Type: PROCEDURE; Schema: public; Owner: -
--

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


--
-- Name: user_blossom_relays(bytea[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_blossom_relays(a_pubkeys bytea[]) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    eid bytea;
BEGIN
    FOR eid IN SELECT event_id FROM replaceable_events WHERE pubkey = ANY(a_pubkeys) and kind = 10063 LOOP
            RETURN NEXT get_event_jsonb(eid);
        END LOOP;
END
$$;


--
-- Name: user_blossom_servers(bytea[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_blossom_servers(a_pubkeys bytea[]) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    eid bytea;
BEGIN
    FOR eid IN SELECT event_id FROM replaceable_events WHERE pubkey = ANY(a_pubkeys) and kind = 10063 LOOP
            RETURN NEXT get_event_jsonb(eid);
        END LOOP;
END
$$;


--
-- Name: user_follows_posts(bytea, bigint, bigint, bigint, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_follows_posts(a_pubkey bytea, a_since bigint, a_until bigint, a_include_replies bigint, a_limit bigint, a_offset bigint) RETURNS SETOF public.post
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    follows_cnt int8;
BEGIN
    -- a_since := a_since - 24*3600;
    -- a_until := a_until - 24*3600;
    a_since := a_since - 30;
    a_until := a_until - 30;

    select jsonb_array_length(es.tags) into follows_cnt from contact_lists cl, events es where cl.key = a_pubkey and cl.value = es.id;

    -- RAISE NOTICE 'user_follows_posts: % % % % % % %', a_pubkey, a_since, a_until, a_include_replies, a_limit, a_offset, follows_cnt;

    RETURN QUERY SELECT
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
        AND (follows_cnt < 5 OR referenced_event_is_note(pe.event_id))
    ORDER BY
        pe.created_at DESC
    LIMIT
        a_limit
    OFFSET
        a_offset;
END
$$;


--
-- Name: user_has_bio(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_has_bio(a_pubkey bytea) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
SELECT coalesce(length(try_cast_jsonb(es.content::text, '{}')->>'about'), 0) > 0
FROM meta_data md, events es 
WHERE md.key = a_pubkey AND md.value = es.id
LIMIT 1
$$;


--
-- Name: user_infos(bytea[]); Type: FUNCTION; Schema: public; Owner: -
--

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
    RETURN QUERY SELECT * FROM user_blossom_servers(a_pubkeys);
END
$$;


--
-- Name: user_infos(text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_infos(a_pubkeys text[]) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
SELECT * FROM user_infos(ARRAY (SELECT DECODE(UNNEST(a_pubkeys), 'hex')))
$$;


--
-- Name: user_is_human(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_is_human(a_pubkey bytea) RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$
SELECT (
    EXISTS (SELECT 1 FROM pubkey_trustrank ptr WHERE ptr.pubkey = a_pubkey) OR
    EXISTS (SELECT 1 FROM human_override ho WHERE ho.pubkey = a_pubkey AND ho.is_human)
)
$$;


--
-- Name: user_is_human(bytea, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_is_human(a_pubkey bytea, a_user_pubkey bytea) RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$
SELECT (
    EXISTS (SELECT 1 FROM pubkey_trustrank ptr WHERE ptr.pubkey = a_pubkey) OR
    EXISTS (SELECT 1 FROM human_override ho WHERE ho.pubkey = a_pubkey AND ho.is_human) OR
    EXISTS (SELECT 1 FROM pubkey_followers WHERE pubkey = a_pubkey AND follower_pubkey = a_user_pubkey)
)
$$;


--
-- Name: user_live_events(bigint, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_live_events(a_kind bigint, a_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
SELECT get_event_jsonb(lep.event_id)
FROM live_event_participants lep
WHERE lep.participant_pubkey = a_pubkey
  AND lep.kind = a_kind
$$;


--
-- Name: wsconntasks(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.wsconntasks(a_port bigint DEFAULT 14001) RETURNS TABLE(tokio_task bigint, task bigint, trace character varying)
    LANGUAGE sql STABLE
    AS $$
SELECT * FROM dblink(format('host=127.0.0.1 port=%s', a_port), 'select * from tasks;') AS t(tokio_task int8, task int8, trace varchar)
$$;


--
-- Name: zap_response(record, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.zap_response(r record, a_user_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$	
DECLARE
    pk bytea;
    pubkeys bytea[] := '{}';
BEGIN
    IF (a_user_pubkey IS NOT null AND is_pubkey_hidden(a_user_pubkey, 'content', r.sender)) OR
        is_pubkey_hidden(r.receiver, 'content', r.sender) 
    THEN
        RETURN;
    END IF;

    FOR pk IN VALUES (r.sender), (r.receiver) LOOP
        RETURN NEXT get_event_jsonb(meta_data.value) FROM meta_data WHERE pk = meta_data.key;
        pubkeys := array_append(pubkeys, pk);
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

    IF pubkeys != '{}' THEN
        RETURN QUERY SELECT * FROM primal_verified_names(pubkeys);
        RETURN QUERY SELECT * FROM user_blossom_servers(pubkeys);
    END IF;
END $$;


--
-- Name: knowledge_id_seq; Type: SEQUENCE; Schema: agent; Owner: -
--

CREATE SEQUENCE agent.knowledge_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: id_seq; Type: SEQUENCE; Schema: cache; Owner: -
--

CREATE SEQUENCE cache.id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: a_tags_1_7d98c5333f; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: a_tags; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.a_tags AS
 SELECT i,
    eid,
    kind,
    created_at,
    ref_kind,
    ref_pubkey,
    ref_identifier,
    ref_arg4,
    imported_at
   FROM public.a_tags_1_7d98c5333f;


--
-- Name: advsearch_5_d7da6f551e; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: advsearch; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.advsearch AS
 SELECT i,
    id,
    pubkey,
    created_at,
    kind,
    content_tsv,
    hashtag_tsv,
    reply_tsv,
    mention_tsv,
    filter_tsv,
    url_tsv
   FROM public.advsearch_5_d7da6f551e;


--
-- Name: allow_list_1_f1da08e9c8; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.allow_list_1_f1da08e9c8 (
    key bytea NOT NULL,
    value bytea NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: allow_list; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.allow_list AS
 SELECT key,
    value,
    rowid
   FROM public.allow_list_1_f1da08e9c8;


--
-- Name: basic_tags_6_62c3d17c2f; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: basic_tags; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.basic_tags AS
 SELECT i,
    id,
    pubkey,
    created_at,
    kind,
    tag,
    arg1,
    arg3,
    imported_at
   FROM public.basic_tags_6_62c3d17c2f;


--
-- Name: bookmarks_1_43f5248b56; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bookmarks_1_43f5248b56 (
    pubkey bytea NOT NULL,
    event_id bytea NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: bookmarks; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.bookmarks AS
 SELECT pubkey,
    event_id,
    rowid
   FROM public.bookmarks_1_43f5248b56;


--
-- Name: contact_lists_1_1abdf474bd; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.contact_lists_1_1abdf474bd (
    key bytea NOT NULL,
    value bytea NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: contact_lists; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.contact_lists AS
 SELECT key,
    value,
    rowid
   FROM public.contact_lists_1_1abdf474bd;


--
-- Name: deleted_events_1_0249f47b16; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.deleted_events_1_0249f47b16 (
    event_id bytea NOT NULL,
    deletion_event_id bytea NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: deleted_events; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.deleted_events AS
 SELECT event_id,
    deletion_event_id,
    rowid
   FROM public.deleted_events_1_0249f47b16;


--
-- Name: event_attributes_1_3196ca546f; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_attributes_1_3196ca546f (
    event_id bytea NOT NULL,
    key character varying NOT NULL,
    value bigint NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: event_attributes; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.event_attributes AS
 SELECT event_id,
    key,
    value,
    rowid
   FROM public.event_attributes_1_3196ca546f;


--
-- Name: event_created_at_1_7a51e16c5c; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_created_at_1_7a51e16c5c (
    event_id bytea NOT NULL,
    created_at bigint NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: event_created_at; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.event_created_at AS
 SELECT event_id,
    created_at,
    rowid
   FROM public.event_created_at_1_7a51e16c5c;


--
-- Name: event_hashtags_1_295f217c0e; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_hashtags_1_295f217c0e (
    event_id bytea NOT NULL,
    hashtag character varying NOT NULL,
    created_at bigint NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: event_hashtags; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.event_hashtags AS
 SELECT event_id,
    hashtag,
    created_at,
    rowid
   FROM public.event_hashtags_1_295f217c0e;


--
-- Name: event_mentions_1_a056fb6737; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_mentions_1_a056fb6737 (
    eid bytea NOT NULL,
    tag character(1) NOT NULL,
    argeid bytea,
    argpubkey bytea,
    argkind bigint,
    argid character varying
);


--
-- Name: event_mentions; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.event_mentions AS
 SELECT eid,
    tag,
    argeid,
    argpubkey,
    argkind,
    argid
   FROM public.event_mentions_1_a056fb6737;


--
-- Name: event_pubkey_action_refs_1_f32e1ff589; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_pubkey_action_refs_1_f32e1ff589 (
    event_id bytea NOT NULL,
    ref_event_id bytea NOT NULL,
    ref_pubkey bytea NOT NULL,
    ref_created_at bigint NOT NULL,
    ref_kind bigint NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: event_pubkey_action_refs; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.event_pubkey_action_refs AS
 SELECT event_id,
    ref_event_id,
    ref_pubkey,
    ref_created_at,
    ref_kind,
    rowid
   FROM public.event_pubkey_action_refs_1_f32e1ff589;


--
-- Name: event_pubkey_actions_1_d62afee35d; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: event_pubkey_actions; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.event_pubkey_actions AS
 SELECT event_id,
    pubkey,
    created_at,
    updated_at,
    replied,
    liked,
    reposted,
    zapped,
    rowid
   FROM public.event_pubkey_actions_1_d62afee35d;


--
-- Name: event_replies_1_9d033b5bb3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_replies_1_9d033b5bb3 (
    event_id bytea NOT NULL,
    reply_event_id bytea NOT NULL,
    reply_created_at bigint NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: event_replies; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.event_replies AS
 SELECT event_id,
    reply_event_id,
    reply_created_at,
    rowid
   FROM public.event_replies_1_9d033b5bb3;


--
-- Name: event_sentiment_1_d3d7a00a54; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: event_sentiment; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.event_sentiment AS
 SELECT eid,
    model,
    topsentiment,
    positive_prob,
    negative_prob,
    question_prob,
    neutral_prob,
    imported_at
   FROM public.event_sentiment_1_d3d7a00a54;


--
-- Name: event_stats_1_1b380f4869; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: event_stats; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.event_stats AS
 SELECT event_id,
    author_pubkey,
    created_at,
    likes,
    replies,
    mentions,
    reposts,
    zaps,
    satszapped,
    score,
    score24h,
    rowid
   FROM public.event_stats_1_1b380f4869;


--
-- Name: event_stats_by_pubkey_1_4ecc48a026; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: event_stats_by_pubkey; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.event_stats_by_pubkey AS
 SELECT event_id,
    author_pubkey,
    created_at,
    likes,
    replies,
    mentions,
    reposts,
    zaps,
    satszapped,
    score,
    score24h,
    rowid
   FROM public.event_stats_by_pubkey_1_4ecc48a026;


--
-- Name: event_thread_parents_1_e17bf16c98; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_thread_parents_1_e17bf16c98 (
    key bytea NOT NULL,
    value bytea NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: event_thread_parents; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.event_thread_parents AS
 SELECT key,
    value,
    rowid
   FROM public.event_thread_parents_1_e17bf16c98;


--
-- Name: event_zapped_1_7ebdbebf92; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_zapped_1_7ebdbebf92 (
    event_id bytea NOT NULL,
    zap_sender bytea NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: event_zapped; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.event_zapped AS
 SELECT event_id,
    zap_sender,
    rowid
   FROM public.event_zapped_1_7ebdbebf92;


--
-- Name: events; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.events AS
 SELECT id,
    pubkey,
    created_at,
    kind,
    tags,
    content,
    sig,
    imported_at
   FROM public.event;


--
-- Name: hashtags_1_1e5c72161a; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hashtags_1_1e5c72161a (
    hashtag character varying NOT NULL,
    score bigint NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: hashtags; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.hashtags AS
 SELECT hashtag,
    score,
    rowid
   FROM public.hashtags_1_1e5c72161a;


--
-- Name: meta_data_1_323bc43167; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.meta_data_1_323bc43167 (
    key bytea NOT NULL,
    value bytea NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: meta_data; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.meta_data AS
 SELECT key,
    value,
    rowid
   FROM public.meta_data_1_323bc43167;


--
-- Name: mute_list_1_f693a878b9; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mute_list_1_f693a878b9 (
    key bytea NOT NULL,
    value bytea NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: mute_list; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.mute_list AS
 SELECT key,
    value,
    rowid
   FROM public.mute_list_1_f693a878b9;


--
-- Name: mute_list_2_1_949b3d746b; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mute_list_2_1_949b3d746b (
    key bytea NOT NULL,
    value bytea NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: mute_list_2; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.mute_list_2 AS
 SELECT key,
    value,
    rowid
   FROM public.mute_list_2_1_949b3d746b;


--
-- Name: mute_lists_1_d90e559628; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mute_lists_1_d90e559628 (
    key bytea NOT NULL,
    value bytea NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: mute_lists; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.mute_lists AS
 SELECT key,
    value,
    rowid
   FROM public.mute_lists_1_d90e559628;


--
-- Name: note_length_1_15d66ffae6; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.note_length_1_15d66ffae6 (
    eid bytea NOT NULL,
    length bigint NOT NULL
);


--
-- Name: note_length; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.note_length AS
 SELECT eid,
    length
   FROM public.note_length_1_15d66ffae6;


--
-- Name: note_stats_1_07d205f278; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.note_stats_1_07d205f278 (
    eid bytea NOT NULL,
    long_replies bigint NOT NULL
);


--
-- Name: note_stats; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.note_stats AS
 SELECT eid,
    long_replies
   FROM public.note_stats_1_07d205f278;


--
-- Name: og_zap_receipts_1_dc85307383; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.og_zap_receipts_1_dc85307383 (
    zap_receipt_id bytea NOT NULL,
    created_at bigint NOT NULL,
    sender bytea NOT NULL,
    receiver bytea NOT NULL,
    amount_sats bigint NOT NULL,
    event_id bytea NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: og_zap_receipts; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.og_zap_receipts AS
 SELECT zap_receipt_id,
    created_at,
    sender,
    receiver,
    amount_sats,
    event_id,
    rowid
   FROM public.og_zap_receipts_1_dc85307383;


--
-- Name: parameterized_replaceable_list_1_d02d7ecc62; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.parameterized_replaceable_list_1_d02d7ecc62 (
    pubkey bytea NOT NULL,
    identifier character varying NOT NULL,
    created_at bigint NOT NULL,
    event_id bytea NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: parameterized_replaceable_list; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.parameterized_replaceable_list AS
 SELECT pubkey,
    identifier,
    created_at,
    event_id,
    rowid
   FROM public.parameterized_replaceable_list_1_d02d7ecc62;


--
-- Name: parametrized_replaceable_events_1_cbe75c8d53; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.parametrized_replaceable_events_1_cbe75c8d53 (
    pubkey bytea NOT NULL,
    kind bigint NOT NULL,
    identifier character varying NOT NULL,
    event_id bytea NOT NULL,
    created_at bigint NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: parametrized_replaceable_events; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.parametrized_replaceable_events AS
 SELECT pubkey,
    kind,
    identifier,
    event_id,
    created_at,
    rowid
   FROM public.parametrized_replaceable_events_1_cbe75c8d53;


--
-- Name: pubkey_content_zap_cnt_1_236df2f369; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pubkey_content_zap_cnt_1_236df2f369 (
    pubkey bytea NOT NULL,
    cnt bigint NOT NULL
);


--
-- Name: pubkey_content_zap_cnt; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.pubkey_content_zap_cnt AS
 SELECT pubkey,
    cnt
   FROM public.pubkey_content_zap_cnt_1_236df2f369;


--
-- Name: pubkey_directmsgs_1_c794110a2c; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pubkey_directmsgs_1_c794110a2c (
    receiver bytea NOT NULL,
    sender bytea NOT NULL,
    created_at bigint NOT NULL,
    event_id bytea NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: pubkey_directmsgs; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.pubkey_directmsgs AS
 SELECT receiver,
    sender,
    created_at,
    event_id,
    rowid
   FROM public.pubkey_directmsgs_1_c794110a2c;


--
-- Name: pubkey_events_1_1dcbfe1466; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pubkey_events_1_1dcbfe1466 (
    pubkey bytea NOT NULL,
    event_id bytea NOT NULL,
    created_at bigint NOT NULL,
    is_reply bigint NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: pubkey_events; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.pubkey_events AS
 SELECT pubkey,
    event_id,
    created_at,
    is_reply,
    rowid
   FROM public.pubkey_events_1_1dcbfe1466;


--
-- Name: pubkey_followers_1_d52305fb47; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pubkey_followers_1_d52305fb47 (
    pubkey bytea NOT NULL,
    follower_pubkey bytea NOT NULL,
    follower_contact_list_event_id bytea NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: pubkey_followers; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.pubkey_followers AS
 SELECT pubkey,
    follower_pubkey,
    follower_contact_list_event_id,
    rowid
   FROM public.pubkey_followers_1_d52305fb47;


--
-- Name: pubkey_followers_cnt_1_a6f7e200e7; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pubkey_followers_cnt_1_a6f7e200e7 (
    key bytea NOT NULL,
    value bigint NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: pubkey_followers_cnt; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.pubkey_followers_cnt AS
 SELECT key,
    value,
    rowid
   FROM public.pubkey_followers_cnt_1_a6f7e200e7;


--
-- Name: pubkey_ids_1_54b55dd09c; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pubkey_ids_1_54b55dd09c (
    key bytea NOT NULL,
    value bigint NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: pubkey_ids; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.pubkey_ids AS
 SELECT key,
    value,
    rowid
   FROM public.pubkey_ids_1_54b55dd09c;


--
-- Name: pubkey_ln_address_1_d3649b2898; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pubkey_ln_address_1_d3649b2898 (
    pubkey bytea NOT NULL,
    ln_address character varying NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: pubkey_ln_address; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.pubkey_ln_address AS
 SELECT pubkey,
    ln_address,
    rowid
   FROM public.pubkey_ln_address_1_d3649b2898;


--
-- Name: pubkey_media_cnt_1_b5e2a488b1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pubkey_media_cnt_1_b5e2a488b1 (
    pubkey bytea NOT NULL,
    cnt bigint NOT NULL
);


--
-- Name: pubkey_media_cnt; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.pubkey_media_cnt AS
 SELECT pubkey,
    cnt
   FROM public.pubkey_media_cnt_1_b5e2a488b1;


--
-- Name: pubkey_notifications_1_e5459ab9dd; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: pubkey_notifications; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.pubkey_notifications AS
 SELECT pubkey,
    created_at,
    type,
    arg1,
    arg2,
    arg3,
    arg4,
    rowid
   FROM public.pubkey_notifications_1_e5459ab9dd;


--
-- Name: pubkey_zapped_1_17f1f622a9; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pubkey_zapped_1_17f1f622a9 (
    pubkey bytea NOT NULL,
    zaps bigint NOT NULL,
    satszapped bigint NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: pubkey_zapped; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.pubkey_zapped AS
 SELECT pubkey,
    zaps,
    satszapped,
    rowid
   FROM public.pubkey_zapped_1_17f1f622a9;


--
-- Name: reads_12_68c6bbfccd; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: reads; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.reads AS
 SELECT pubkey,
    identifier,
    published_at,
    latest_eid,
    latest_created_at,
    likes,
    zaps,
    satszapped,
    replies,
    reposts,
    topics,
    words,
    lang,
    lang_prob,
    image,
    summary
   FROM public.reads_12_68c6bbfccd;


--
-- Name: reads_versions_12_b537d4df66; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reads_versions_12_b537d4df66 (
    pubkey bytea NOT NULL,
    identifier character varying NOT NULL,
    eid bytea NOT NULL
);


--
-- Name: reads_versions; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.reads_versions AS
 SELECT pubkey,
    identifier,
    eid
   FROM public.reads_versions_12_b537d4df66;


--
-- Name: relay_list_metadata_1_801a17fc93; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.relay_list_metadata_1_801a17fc93 (
    pubkey bytea NOT NULL,
    event_id bytea NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: relay_list_metadata; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.relay_list_metadata AS
 SELECT pubkey,
    event_id,
    rowid
   FROM public.relay_list_metadata_1_801a17fc93;


--
-- Name: zap_receipts_1_9fe40119b2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.zap_receipts_1_9fe40119b2 (
    eid bytea NOT NULL,
    created_at bigint NOT NULL,
    target_eid bytea NOT NULL,
    sender bytea NOT NULL,
    receiver bytea NOT NULL,
    satszapped bigint NOT NULL,
    imported_at bigint NOT NULL
);


--
-- Name: zap_receipts; Type: VIEW; Schema: prod; Owner: -
--

CREATE VIEW prod.zap_receipts AS
 SELECT eid,
    created_at,
    target_eid,
    sender,
    receiver,
    satszapped,
    imported_at
   FROM public.zap_receipts_1_9fe40119b2;


--
-- Name: a_tags; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.a_tags AS
 SELECT i,
    eid,
    kind,
    created_at,
    ref_kind,
    ref_pubkey,
    ref_identifier,
    ref_arg4,
    imported_at
   FROM public.a_tags_1_7d98c5333f;


--
-- Name: a_tags_1_7d98c5333f_i_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.a_tags_1_7d98c5333f_i_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: a_tags_1_7d98c5333f_i_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.a_tags_1_7d98c5333f_i_seq OWNED BY public.a_tags_1_7d98c5333f.i;


--
-- Name: advsearch; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.advsearch AS
 SELECT i,
    id,
    pubkey,
    created_at,
    kind,
    content_tsv,
    hashtag_tsv,
    reply_tsv,
    mention_tsv,
    filter_tsv,
    url_tsv
   FROM public.advsearch_5_d7da6f551e;


--
-- Name: advsearch_5_d7da6f551e_i_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.advsearch_5_d7da6f551e_i_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: advsearch_5_d7da6f551e_i_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.advsearch_5_d7da6f551e_i_seq OWNED BY public.advsearch_5_d7da6f551e.i;


--
-- Name: allow_list; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.allow_list AS
 SELECT key,
    value,
    rowid
   FROM public.allow_list_1_f1da08e9c8;


--
-- Name: basic_tags; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.basic_tags AS
 SELECT i,
    id,
    pubkey,
    created_at,
    kind,
    tag,
    arg1,
    arg3,
    imported_at
   FROM public.basic_tags_6_62c3d17c2f;


--
-- Name: basic_tags_6_62c3d17c2f_i_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.basic_tags_6_62c3d17c2f_i_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: basic_tags_6_62c3d17c2f_i_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.basic_tags_6_62c3d17c2f_i_seq OWNED BY public.basic_tags_6_62c3d17c2f.i;


--
-- Name: bookmarks; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.bookmarks AS
 SELECT pubkey,
    event_id,
    rowid
   FROM public.bookmarks_1_43f5248b56;


--
-- Name: cache; Type: TABLE; Schema: public; Owner: -
--

CREATE UNLOGGED TABLE public.cache (
    key text NOT NULL,
    value jsonb NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: cmr_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cmr_groups (
    user_pubkey bytea,
    grp public.cmr_grp NOT NULL,
    scope public.cmr_scope NOT NULL
);


--
-- Name: cmr_hashtags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cmr_hashtags (
    user_pubkey bytea NOT NULL,
    hashtag character varying NOT NULL,
    scope public.cmr_scope NOT NULL
);


--
-- Name: cmr_hashtags_2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cmr_hashtags_2 (
    user_pubkey bytea NOT NULL,
    scope public.cmr_scope NOT NULL,
    hashtags tsquery NOT NULL
);


--
-- Name: cmr_pubkeys_allowed; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cmr_pubkeys_allowed (
    user_pubkey bytea,
    pubkey bytea NOT NULL
);


--
-- Name: cmr_pubkeys_parent; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cmr_pubkeys_parent (
    user_pubkey bytea,
    pubkey bytea NOT NULL,
    parent bytea NOT NULL
);


--
-- Name: cmr_pubkeys_scopes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cmr_pubkeys_scopes (
    user_pubkey bytea,
    pubkey bytea NOT NULL,
    scope public.cmr_scope NOT NULL
);


--
-- Name: cmr_threads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cmr_threads (
    user_pubkey bytea NOT NULL,
    event_id bytea NOT NULL,
    scope public.cmr_scope NOT NULL
);


--
-- Name: cmr_words; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cmr_words (
    user_pubkey bytea NOT NULL,
    word character varying NOT NULL,
    scope public.cmr_scope NOT NULL
);


--
-- Name: cmr_words_2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cmr_words_2 (
    user_pubkey bytea NOT NULL,
    scope public.cmr_scope NOT NULL,
    words tsquery NOT NULL
);


--
-- Name: contact_lists; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.contact_lists AS
 SELECT key,
    value,
    rowid
   FROM public.contact_lists_1_1abdf474bd;


--
-- Name: counter_by_bytea; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.counter_by_bytea (
    type character varying NOT NULL,
    key bytea NOT NULL,
    cnt bigint NOT NULL
);


--
-- Name: coverages_1_8656fc443b; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.coverages_1_8656fc443b (
    name character varying NOT NULL,
    t bigint NOT NULL,
    t2 bigint NOT NULL
);


--
-- Name: dag_1_4bd2aaff98; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dag_1_4bd2aaff98 (
    output character varying NOT NULL,
    input character varying NOT NULL
);


--
-- Name: daily_followers_cnt_increases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_followers_cnt_increases (
    pubkey bytea NOT NULL,
    cnt bigint NOT NULL,
    increase bigint NOT NULL,
    ratio real NOT NULL
);


--
-- Name: deleted_events; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.deleted_events AS
 SELECT event_id,
    deletion_event_id,
    rowid
   FROM public.deleted_events_1_0249f47b16;


--
-- Name: dvm_feeds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dvm_feeds (
    pubkey bytea NOT NULL,
    identifier character varying NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    results jsonb,
    kind character varying NOT NULL,
    personalized boolean NOT NULL,
    ok boolean NOT NULL
);


--
-- Name: event_attributes; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_attributes AS
 SELECT event_id,
    key,
    value,
    rowid
   FROM public.event_attributes_1_3196ca546f;


--
-- Name: event_created_at; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_created_at AS
 SELECT event_id,
    created_at,
    rowid
   FROM public.event_created_at_1_7a51e16c5c;


--
-- Name: event_hashtags; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_hashtags AS
 SELECT event_id,
    hashtag,
    created_at,
    rowid
   FROM public.event_hashtags_1_295f217c0e;


--
-- Name: event_hooks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_hooks (
    event_id bytea NOT NULL,
    funcall text NOT NULL
);


--
-- Name: event_media_1_30bf07e9cf; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_media_1_30bf07e9cf (
    event_id bytea NOT NULL,
    url character varying NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: event_media; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_media AS
 SELECT event_id,
    url,
    rowid
   FROM public.event_media_1_30bf07e9cf;


--
-- Name: event_mentions; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_mentions AS
 SELECT eid,
    tag,
    argeid,
    argpubkey,
    argkind,
    argid
   FROM public.event_mentions_1_a056fb6737;


--
-- Name: event_mentions_1_0b730615c4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_mentions_1_0b730615c4 (
    eid bytea NOT NULL,
    tag character(1) NOT NULL,
    argeid bytea,
    argpubkey bytea,
    argkind bigint,
    argid character varying
);


--
-- Name: event_mentions_1_6738bfddaf; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_mentions_1_6738bfddaf (
    eid bytea NOT NULL,
    tag character(1) NOT NULL,
    argeid bytea NOT NULL,
    argpubkey bytea NOT NULL,
    argkind bigint NOT NULL,
    argid character varying NOT NULL
);


--
-- Name: event_preview_1_310cef356e; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_preview_1_310cef356e (
    event_id bytea NOT NULL,
    url character varying NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: event_preview; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_preview AS
 SELECT event_id,
    url,
    rowid
   FROM public.event_preview_1_310cef356e;


--
-- Name: event_pubkey_action_refs; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_pubkey_action_refs AS
 SELECT event_id,
    ref_event_id,
    ref_pubkey,
    ref_created_at,
    ref_kind,
    rowid
   FROM public.event_pubkey_action_refs_1_f32e1ff589;


--
-- Name: event_pubkey_actions; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_pubkey_actions AS
 SELECT event_id,
    pubkey,
    created_at,
    updated_at,
    replied,
    liked,
    reposted,
    zapped,
    rowid
   FROM public.event_pubkey_actions_1_d62afee35d;


--
-- Name: event_relay; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_relay (
    event_id bytea NOT NULL,
    relay_url text
);


--
-- Name: event_relays; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_relays (
    event_id bytea NOT NULL,
    relay_url character varying NOT NULL,
    imported_at bigint NOT NULL
);


--
-- Name: event_replies; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_replies AS
 SELECT event_id,
    reply_event_id,
    reply_created_at,
    rowid
   FROM public.event_replies_1_9d033b5bb3;


--
-- Name: event_sentiment; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_sentiment AS
 SELECT eid,
    model,
    topsentiment,
    positive_prob,
    negative_prob,
    question_prob,
    neutral_prob,
    imported_at
   FROM public.event_sentiment_1_d3d7a00a54;


--
-- Name: event_stats; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_stats AS
 SELECT event_id,
    author_pubkey,
    created_at,
    likes,
    replies,
    mentions,
    reposts,
    zaps,
    satszapped,
    score,
    score24h,
    rowid
   FROM public.event_stats_1_1b380f4869;


--
-- Name: event_stats_2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_stats_2 (
    event_id bytea NOT NULL,
    score2 bigint NOT NULL
);


--
-- Name: event_stats_by_pubkey; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_stats_by_pubkey AS
 SELECT event_id,
    author_pubkey,
    created_at,
    likes,
    replies,
    mentions,
    reposts,
    zaps,
    satszapped,
    score,
    score24h,
    rowid
   FROM public.event_stats_by_pubkey_1_4ecc48a026;


--
-- Name: event_tags; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_tags AS
 SELECT id,
    pubkey,
    kind,
    created_at,
    (jsonb_array_elements(tags) ->> 0) AS tag,
    (jsonb_array_elements(tags) ->> 1) AS arg1
   FROM public.event;


--
-- Name: event_thread_parents; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_thread_parents AS
 SELECT key,
    value,
    rowid
   FROM public.event_thread_parents_1_e17bf16c98;


--
-- Name: event_zapped; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_zapped AS
 SELECT event_id,
    zap_sender,
    rowid
   FROM public.event_zapped_1_7ebdbebf92;


--
-- Name: events; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.events AS
 SELECT id,
    pubkey,
    created_at,
    kind,
    tags,
    content,
    sig,
    imported_at
   FROM public.event;


--
-- Name: fetcher_relays; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fetcher_relays (
    relay_url character varying NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    source_event_id bytea
);


--
-- Name: filterlist; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.filterlist (
    target bytea NOT NULL,
    target_type public.filterlist_target NOT NULL,
    blocked boolean NOT NULL,
    grp public.filterlist_grp NOT NULL,
    added_at bigint,
    comment character varying
);


--
-- Name: filterlist_pubkey; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.filterlist_pubkey (
    pubkey bytea NOT NULL,
    blocked boolean NOT NULL,
    grp public.filterlist_grp NOT NULL
);


--
-- Name: id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: follow_lists; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.follow_lists (
    id bigint DEFAULT nextval('public.id_seq'::regclass) NOT NULL,
    pubkey bytea NOT NULL,
    identifier character varying NOT NULL,
    follow_pubkey bytea NOT NULL
);


--
-- Name: hashtags; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.hashtags AS
 SELECT hashtag,
    score,
    rowid
   FROM public.hashtags_1_1e5c72161a;


--
-- Name: human_override; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.human_override (
    pubkey bytea NOT NULL,
    is_human boolean,
    added_at timestamp without time zone DEFAULT now(),
    source character varying
);


--
-- Name: id_table; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.id_table (
    id bigint NOT NULL,
    table_name character varying NOT NULL,
    extra jsonb
);


--
-- Name: known_relays; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.known_relays (
    relay_url character varying NOT NULL,
    last_import_at timestamp without time zone NOT NULL
);


--
-- Name: lists; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lists (
    list character varying(200) NOT NULL,
    pubkey bytea NOT NULL,
    added_at integer NOT NULL
);


--
-- Name: live_event_participants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.live_event_participants (
    kind bigint NOT NULL,
    pubkey bytea NOT NULL,
    identifier character varying NOT NULL,
    participant_pubkey bytea NOT NULL,
    event_id bytea NOT NULL,
    created_at bigint NOT NULL
);


--
-- Name: logs_1_d241bdb71c; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.logs_1_d241bdb71c (
    t timestamp without time zone NOT NULL,
    module character varying NOT NULL,
    func character varying NOT NULL,
    type character varying NOT NULL,
    d jsonb NOT NULL
);


--
-- Name: media_1_16fa35f2dc; Type: TABLE; Schema: public; Owner: -
--

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
    rowid bigint DEFAULT 0,
    orig_sha256 bytea
);


--
-- Name: media; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.media AS
 SELECT url,
    media_url,
    size,
    animated,
    imported_at,
    download_duration,
    width,
    height,
    mimetype,
    category,
    category_confidence,
    duration,
    rowid,
    orig_sha256
   FROM public.media_1_16fa35f2dc;


--
-- Name: media_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.media_metadata (
    sha256 bytea NOT NULL,
    model character varying NOT NULL,
    md jsonb NOT NULL,
    t timestamp without time zone NOT NULL,
    sha256_ bytea
);


--
-- Name: media_storage; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.media_storage (
    media_url character varying NOT NULL,
    storage_provider character varying NOT NULL,
    added_at bigint NOT NULL,
    key character varying NOT NULL,
    h character varying NOT NULL,
    ext character varying NOT NULL,
    content_type character varying NOT NULL,
    size bigint NOT NULL,
    sha256 bytea,
    media_block_id uuid
);


--
-- Name: media_storage_priority; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.media_storage_priority (
    storage_provider character varying NOT NULL,
    priority integer NOT NULL
);


--
-- Name: membership_legend_customization; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.membership_legend_customization (
    pubkey bytea NOT NULL,
    style character varying NOT NULL,
    custom_badge boolean NOT NULL,
    avatar_glow boolean NOT NULL,
    in_leaderboard boolean,
    current_shoutout character varying,
    edited_shoutout character varying,
    donated_btc numeric DEFAULT 0,
    last_donation timestamp without time zone,
    legend_since timestamp without time zone,
    premium_since timestamp without time zone
);


--
-- Name: memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memberships (
    pubkey bytea NOT NULL,
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
    origin character varying,
    legend_since timestamp without time zone,
    premium_since timestamp without time zone
);


--
-- Name: meta_data; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.meta_data AS
 SELECT key,
    value,
    rowid
   FROM public.meta_data_1_323bc43167;


--
-- Name: mute_list; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.mute_list AS
 SELECT key,
    value,
    rowid
   FROM public.mute_list_1_f693a878b9;


--
-- Name: mute_list_2; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.mute_list_2 AS
 SELECT key,
    value,
    rowid
   FROM public.mute_list_2_1_949b3d746b;


--
-- Name: mute_lists; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.mute_lists AS
 SELECT key,
    value,
    rowid
   FROM public.mute_lists_1_d90e559628;


--
-- Name: muted_threads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.muted_threads (
    pubkey bytea NOT NULL,
    root_eid bytea NOT NULL,
    muted_at timestamp without time zone NOT NULL
);


--
-- Name: node_outputs_1_cfe6037c9f; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.node_outputs_1_cfe6037c9f (
    output character varying NOT NULL,
    def jsonb NOT NULL
);


--
-- Name: note_length; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.note_length AS
 SELECT eid,
    length
   FROM public.note_length_1_15d66ffae6;


--
-- Name: note_stats; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.note_stats AS
 SELECT eid,
    long_replies
   FROM public.note_stats_1_07d205f278;


--
-- Name: notification_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_types (
    type integer NOT NULL,
    name character varying NOT NULL
);


--
-- Name: og_zap_receipts; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.og_zap_receipts AS
 SELECT zap_receipt_id,
    created_at,
    sender,
    receiver,
    amount_sats,
    event_id,
    rowid
   FROM public.og_zap_receipts_1_dc85307383;


--
-- Name: parameterized_replaceable_list; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.parameterized_replaceable_list AS
 SELECT pubkey,
    identifier,
    created_at,
    event_id,
    rowid
   FROM public.parameterized_replaceable_list_1_d02d7ecc62;


--
-- Name: parametrized_replaceable_events; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.parametrized_replaceable_events AS
 SELECT pubkey,
    kind,
    identifier,
    event_id,
    created_at,
    rowid
   FROM public.parametrized_replaceable_events_1_cbe75c8d53;


--
-- Name: preview_1_44299731c7; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: preview; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.preview AS
 SELECT url,
    imported_at,
    download_duration,
    mimetype,
    category,
    category_confidence,
    md_title,
    md_description,
    md_image,
    icon_url,
    rowid
   FROM public.preview_1_44299731c7;


--
-- Name: pubkey_bookmarks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pubkey_bookmarks (
    pubkey bytea NOT NULL,
    ref_event_id bytea,
    ref_kind bytea,
    ref_pubkey bytea,
    ref_identifier bytea
);


--
-- Name: pubkey_content_zap_cnt; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_content_zap_cnt AS
 SELECT pubkey,
    cnt
   FROM public.pubkey_content_zap_cnt_1_236df2f369;


--
-- Name: pubkey_directmsgs; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_directmsgs AS
 SELECT receiver,
    sender,
    created_at,
    event_id,
    rowid
   FROM public.pubkey_directmsgs_1_c794110a2c;


--
-- Name: pubkey_directmsgs_cnt_1_efdf9742a6; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pubkey_directmsgs_cnt_1_efdf9742a6 (
    receiver bytea NOT NULL,
    sender bytea,
    cnt bigint NOT NULL,
    latest_at bigint NOT NULL,
    latest_event_id bytea NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: pubkey_directmsgs_cnt; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_directmsgs_cnt AS
 SELECT receiver,
    sender,
    cnt,
    latest_at,
    latest_event_id,
    rowid
   FROM public.pubkey_directmsgs_cnt_1_efdf9742a6;


--
-- Name: pubkey_events; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_events AS
 SELECT pubkey,
    event_id,
    created_at,
    is_reply,
    rowid
   FROM public.pubkey_events_1_1dcbfe1466;


--
-- Name: pubkey_followers; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_followers AS
 SELECT pubkey,
    follower_pubkey,
    follower_contact_list_event_id,
    rowid
   FROM public.pubkey_followers_1_d52305fb47;


--
-- Name: pubkey_followers_cnt; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_followers_cnt AS
 SELECT key,
    value,
    rowid
   FROM public.pubkey_followers_cnt_1_a6f7e200e7;


--
-- Name: pubkey_ids; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_ids AS
 SELECT key,
    value,
    rowid
   FROM public.pubkey_ids_1_54b55dd09c;


--
-- Name: pubkey_ln_address; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_ln_address AS
 SELECT pubkey,
    ln_address,
    rowid
   FROM public.pubkey_ln_address_1_d3649b2898;


--
-- Name: pubkey_media_cnt; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_media_cnt AS
 SELECT pubkey,
    cnt
   FROM public.pubkey_media_cnt_1_b5e2a488b1;


--
-- Name: pubkey_notification_cnts_1_d78f6fcade; Type: TABLE; Schema: public; Owner: -
--

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
    rowid bigint DEFAULT 0,
    type301 integer DEFAULT 0 NOT NULL,
    type302 integer DEFAULT 0 NOT NULL,
    type303 integer DEFAULT 0 NOT NULL,
    type401 integer DEFAULT 0 NOT NULL
);


--
-- Name: pubkey_notification_cnts; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_notification_cnts AS
 SELECT pubkey,
    type1,
    type2,
    type3,
    type4,
    type5,
    type6,
    type7,
    type8,
    type101,
    type102,
    type103,
    type104,
    type201,
    type202,
    type203,
    type204,
    rowid,
    type301,
    type302,
    type303,
    type401
   FROM public.pubkey_notification_cnts_1_d78f6fcade;


--
-- Name: pubkey_notifications; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_notifications AS
 SELECT pubkey,
    created_at,
    type,
    arg1,
    arg2,
    arg3,
    arg4,
    rowid
   FROM public.pubkey_notifications_1_e5459ab9dd;


--
-- Name: pubkey_trustrank; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pubkey_trustrank (
    pubkey bytea NOT NULL,
    rank double precision NOT NULL
);


--
-- Name: pubkey_zapped; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_zapped AS
 SELECT pubkey,
    zaps,
    satszapped,
    rowid
   FROM public.pubkey_zapped_1_17f1f622a9;


--
-- Name: reads; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.reads AS
 SELECT pubkey,
    identifier,
    published_at,
    latest_eid,
    latest_created_at,
    likes,
    zaps,
    satszapped,
    replies,
    reposts,
    topics,
    words,
    lang,
    lang_prob,
    image,
    summary
   FROM public.reads_12_68c6bbfccd;


--
-- Name: reads_11_2a4d2ce519; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: reads_versions; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.reads_versions AS
 SELECT pubkey,
    identifier,
    eid
   FROM public.reads_versions_12_b537d4df66;


--
-- Name: reads_versions_11_fb53a8e0b4; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reads_versions_11_fb53a8e0b4 (
    pubkey bytea NOT NULL,
    identifier character varying NOT NULL,
    eid bytea NOT NULL
);


--
-- Name: relay_list_metadata; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.relay_list_metadata AS
 SELECT pubkey,
    event_id,
    rowid
   FROM public.relay_list_metadata_1_801a17fc93;


--
-- Name: relay_url_map; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.relay_url_map (
    src character varying NOT NULL,
    dest character varying NOT NULL
);


--
-- Name: relays; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.relays (
    url text NOT NULL,
    times_referenced bigint NOT NULL
);


--
-- Name: replaceable_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.replaceable_events (
    pubkey bytea NOT NULL,
    kind bigint NOT NULL,
    event_id bytea NOT NULL
);


--
-- Name: scheduled_hooks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.scheduled_hooks (
    execute_at bigint NOT NULL,
    funcall text NOT NULL
);


--
-- Name: score_expiry; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.score_expiry (
    event_id bytea NOT NULL,
    author_pubkey bytea NOT NULL,
    change bigint NOT NULL,
    expire_at bigint NOT NULL
);


--
-- Name: stuff; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stuff (
    data text NOT NULL,
    created_at bigint NOT NULL
);


--
-- Name: test_pubkeys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.test_pubkeys (
    name character varying NOT NULL,
    pubkey bytea NOT NULL
);


--
-- Name: text_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.text_metadata (
    sha256 bytea NOT NULL,
    model character varying NOT NULL,
    md jsonb NOT NULL,
    t timestamp without time zone NOT NULL,
    text character varying,
    event_id bytea
);


--
-- Name: trusted_pubkey_followers_cnt; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trusted_pubkey_followers_cnt (
    t timestamp without time zone NOT NULL,
    pubkey bytea NOT NULL,
    cnt bigint NOT NULL
);


--
-- Name: trusted_users_trusted_followers; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.trusted_users_trusted_followers AS
 SELECT pf.pubkey,
    tr1.rank AS pubkey_rank,
    pf.follower_pubkey,
    tr2.rank AS follower_pubkey_rank
   FROM public.pubkey_followers pf,
    public.pubkey_trustrank tr1,
    public.pubkey_trustrank tr2
  WHERE ((pf.pubkey = tr1.pubkey) AND (pf.follower_pubkey = tr2.pubkey));


--
-- Name: user_search; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: vars; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vars (
    key character varying NOT NULL,
    value jsonb NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: verified_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.verified_users (
    name character varying(200) NOT NULL,
    pubkey bytea NOT NULL,
    default_name boolean NOT NULL,
    added_at timestamp without time zone
);

ALTER TABLE ONLY public.verified_users REPLICA IDENTITY FULL;


--
-- Name: video_thumbnails_1_107d5a46eb; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.video_thumbnails_1_107d5a46eb (
    video_url character varying NOT NULL,
    thumbnail_url character varying NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: video_thumbnails; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.video_thumbnails AS
 SELECT video_url,
    thumbnail_url,
    rowid
   FROM public.video_thumbnails_1_107d5a46eb;


--
-- Name: wsconnlog; Type: TABLE; Schema: public; Owner: -
--

CREATE UNLOGGED TABLE public.wsconnlog (
    t timestamp without time zone NOT NULL,
    run bigint NOT NULL,
    task bigint NOT NULL,
    tokio_task bigint NOT NULL,
    info jsonb NOT NULL,
    func character varying,
    conn bigint
);


--
-- Name: wsconnruns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wsconnruns (
    run bigint NOT NULL,
    tstart timestamp without time zone NOT NULL,
    servername character varying NOT NULL,
    port bigint NOT NULL
);


--
-- Name: wsconnruns_run_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.wsconnruns_run_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: wsconnruns_run_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.wsconnruns_run_seq OWNED BY public.wsconnruns.run;


--
-- Name: wsconnvars; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wsconnvars (
    name character varying NOT NULL,
    value jsonb NOT NULL
);


--
-- Name: zap_receipts; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.zap_receipts AS
 SELECT eid,
    created_at,
    target_eid,
    sender,
    receiver,
    satszapped,
    imported_at
   FROM public.zap_receipts_1_9fe40119b2;


--
-- Name: idx_seq; Type: SEQUENCE; Schema: studio; Owner: -
--

CREATE SEQUENCE studio.idx_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: a_tags_1_7d98c5333f i; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.a_tags_1_7d98c5333f ALTER COLUMN i SET DEFAULT nextval('public.a_tags_1_7d98c5333f_i_seq'::regclass);


--
-- Name: advsearch_5_d7da6f551e i; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.advsearch_5_d7da6f551e ALTER COLUMN i SET DEFAULT nextval('public.advsearch_5_d7da6f551e_i_seq'::regclass);


--
-- Name: basic_tags_6_62c3d17c2f i; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.basic_tags_6_62c3d17c2f ALTER COLUMN i SET DEFAULT nextval('public.basic_tags_6_62c3d17c2f_i_seq'::regclass);


--
-- Name: wsconnruns run; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wsconnruns ALTER COLUMN run SET DEFAULT nextval('public.wsconnruns_run_seq'::regclass);


--
-- Name: a_tags_1_7d98c5333f a_tags_1_7d98c5333f_eid_ref_kind_ref_pubkey_ref_identifier__key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.a_tags_1_7d98c5333f
    ADD CONSTRAINT a_tags_1_7d98c5333f_eid_ref_kind_ref_pubkey_ref_identifier__key UNIQUE (eid, ref_kind, ref_pubkey, ref_identifier, ref_arg4);


--
-- Name: a_tags_1_7d98c5333f a_tags_1_7d98c5333f_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.a_tags_1_7d98c5333f
    ADD CONSTRAINT a_tags_1_7d98c5333f_pkey PRIMARY KEY (i);


--
-- Name: advsearch_5_d7da6f551e advsearch_5_d7da6f551e_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.advsearch_5_d7da6f551e
    ADD CONSTRAINT advsearch_5_d7da6f551e_id_key UNIQUE (id);


--
-- Name: advsearch_5_d7da6f551e advsearch_5_d7da6f551e_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.advsearch_5_d7da6f551e
    ADD CONSTRAINT advsearch_5_d7da6f551e_pkey PRIMARY KEY (i);


--
-- Name: allow_list_1_f1da08e9c8 allow_list_1_f1da08e9c8_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.allow_list_1_f1da08e9c8
    ADD CONSTRAINT allow_list_1_f1da08e9c8_pkey PRIMARY KEY (key);


--
-- Name: basic_tags_6_62c3d17c2f basic_tags_6_62c3d17c2f_id_tag_arg1_arg3_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.basic_tags_6_62c3d17c2f
    ADD CONSTRAINT basic_tags_6_62c3d17c2f_id_tag_arg1_arg3_key UNIQUE (id, tag, arg1, arg3);


--
-- Name: basic_tags_6_62c3d17c2f basic_tags_6_62c3d17c2f_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.basic_tags_6_62c3d17c2f
    ADD CONSTRAINT basic_tags_6_62c3d17c2f_pkey PRIMARY KEY (i);


--
-- Name: bookmarks_1_43f5248b56 bookmarks_1_43f5248b56_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookmarks_1_43f5248b56
    ADD CONSTRAINT bookmarks_1_43f5248b56_pkey PRIMARY KEY (pubkey);


--
-- Name: cache cache_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cache
    ADD CONSTRAINT cache_pkey PRIMARY KEY (key);


--
-- Name: cmr_hashtags_2 cmr_hashtags_2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cmr_hashtags_2
    ADD CONSTRAINT cmr_hashtags_2_pkey PRIMARY KEY (user_pubkey, scope);


--
-- Name: cmr_hashtags cmr_hashtags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cmr_hashtags
    ADD CONSTRAINT cmr_hashtags_pkey PRIMARY KEY (user_pubkey, hashtag, scope);


--
-- Name: cmr_threads cmr_threads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cmr_threads
    ADD CONSTRAINT cmr_threads_pkey PRIMARY KEY (user_pubkey, event_id, scope);


--
-- Name: cmr_words_2 cmr_words_2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cmr_words_2
    ADD CONSTRAINT cmr_words_2_pkey PRIMARY KEY (user_pubkey, scope);


--
-- Name: cmr_words cmr_words_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cmr_words
    ADD CONSTRAINT cmr_words_pkey PRIMARY KEY (user_pubkey, word, scope);


--
-- Name: contact_lists_1_1abdf474bd contact_lists_1_1abdf474bd_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.contact_lists_1_1abdf474bd
    ADD CONSTRAINT contact_lists_1_1abdf474bd_pkey PRIMARY KEY (key);


--
-- Name: counter_by_bytea counter_by_bytea_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.counter_by_bytea
    ADD CONSTRAINT counter_by_bytea_pkey PRIMARY KEY (type, key);


--
-- Name: coverages_1_8656fc443b coverages_1_8656fc443b_name_t_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coverages_1_8656fc443b
    ADD CONSTRAINT coverages_1_8656fc443b_name_t_key UNIQUE (name, t);


--
-- Name: dag_1_4bd2aaff98 dag_1_4bd2aaff98_output_input_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dag_1_4bd2aaff98
    ADD CONSTRAINT dag_1_4bd2aaff98_output_input_key UNIQUE (output, input);


--
-- Name: daily_followers_cnt_increases daily_followers_cnt_increases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_followers_cnt_increases
    ADD CONSTRAINT daily_followers_cnt_increases_pkey PRIMARY KEY (pubkey);


--
-- Name: deleted_events_1_0249f47b16 deleted_events_1_0249f47b16_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deleted_events_1_0249f47b16
    ADD CONSTRAINT deleted_events_1_0249f47b16_pkey PRIMARY KEY (event_id);


--
-- Name: dvm_feeds dvm_feeds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dvm_feeds
    ADD CONSTRAINT dvm_feeds_pkey PRIMARY KEY (pubkey, identifier);


--
-- Name: event_created_at_1_7a51e16c5c event_created_at_1_7a51e16c5c_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_created_at_1_7a51e16c5c
    ADD CONSTRAINT event_created_at_1_7a51e16c5c_pkey PRIMARY KEY (event_id);


--
-- Name: event_media_1_30bf07e9cf event_media_1_30bf07e9cf_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_media_1_30bf07e9cf
    ADD CONSTRAINT event_media_1_30bf07e9cf_pkey PRIMARY KEY (event_id, url);


--
-- Name: event_mentions_1_0b730615c4 event_mentions_1_0b730615c4_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_mentions_1_0b730615c4
    ADD CONSTRAINT event_mentions_1_0b730615c4_pkey PRIMARY KEY (eid);


--
-- Name: event_mentions_1_6738bfddaf event_mentions_1_6738bfddaf_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_mentions_1_6738bfddaf
    ADD CONSTRAINT event_mentions_1_6738bfddaf_pkey PRIMARY KEY (eid, tag, argeid, argpubkey, argkind, argid);


--
-- Name: event event_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event
    ADD CONSTRAINT event_pkey PRIMARY KEY (id);


--
-- Name: event_pubkey_actions_1_d62afee35d event_pubkey_actions_1_d62afee35d_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_pubkey_actions_1_d62afee35d
    ADD CONSTRAINT event_pubkey_actions_1_d62afee35d_pkey PRIMARY KEY (event_id, pubkey);


--
-- Name: event_relay event_relay_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_relay
    ADD CONSTRAINT event_relay_pkey PRIMARY KEY (event_id);


--
-- Name: event_relays event_relays_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_relays
    ADD CONSTRAINT event_relays_pkey PRIMARY KEY (event_id, relay_url);


--
-- Name: event_sentiment_1_d3d7a00a54 event_sentiment_1_d3d7a00a54_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_sentiment_1_d3d7a00a54
    ADD CONSTRAINT event_sentiment_1_d3d7a00a54_pkey PRIMARY KEY (eid, model);


--
-- Name: event_stats_2 event_stats_2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_stats_2
    ADD CONSTRAINT event_stats_2_pkey PRIMARY KEY (event_id);


--
-- Name: event_thread_parents_1_e17bf16c98 event_thread_parents_1_e17bf16c98_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_thread_parents_1_e17bf16c98
    ADD CONSTRAINT event_thread_parents_1_e17bf16c98_pkey PRIMARY KEY (key);


--
-- Name: fetcher_relays fetcher_relays_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fetcher_relays
    ADD CONSTRAINT fetcher_relays_pk PRIMARY KEY (relay_url);


--
-- Name: filterlist filterlist_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filterlist
    ADD CONSTRAINT filterlist_pkey PRIMARY KEY (target, target_type, blocked, grp);


--
-- Name: follow_lists follow_lists_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.follow_lists
    ADD CONSTRAINT follow_lists_pkey PRIMARY KEY (pubkey, identifier, follow_pubkey);


--
-- Name: human_override human_override_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.human_override
    ADD CONSTRAINT human_override_pkey PRIMARY KEY (pubkey);


--
-- Name: id_table id_table_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.id_table
    ADD CONSTRAINT id_table_pkey PRIMARY KEY (id);


--
-- Name: known_relays known_relays_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.known_relays
    ADD CONSTRAINT known_relays_pkey PRIMARY KEY (relay_url);


--
-- Name: live_event_participants live_event_participants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.live_event_participants
    ADD CONSTRAINT live_event_participants_pkey PRIMARY KEY (kind, pubkey, identifier, participant_pubkey);


--
-- Name: media_metadata media_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.media_metadata
    ADD CONSTRAINT media_metadata_pkey PRIMARY KEY (sha256, model);


--
-- Name: media_storage media_storage_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.media_storage
    ADD CONSTRAINT media_storage_pk PRIMARY KEY (h, storage_provider);


--
-- Name: media_storage_priority media_storage_priority_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.media_storage_priority
    ADD CONSTRAINT media_storage_priority_pk PRIMARY KEY (storage_provider);


--
-- Name: membership_legend_customization membership_legend_customization_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.membership_legend_customization
    ADD CONSTRAINT membership_legend_customization_pk PRIMARY KEY (pubkey);


--
-- Name: memberships memberships_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_pk PRIMARY KEY (pubkey);


--
-- Name: meta_data_1_323bc43167 meta_data_1_323bc43167_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.meta_data_1_323bc43167
    ADD CONSTRAINT meta_data_1_323bc43167_pkey PRIMARY KEY (key);


--
-- Name: mute_list_1_f693a878b9 mute_list_1_f693a878b9_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mute_list_1_f693a878b9
    ADD CONSTRAINT mute_list_1_f693a878b9_pkey PRIMARY KEY (key);


--
-- Name: mute_list_2_1_949b3d746b mute_list_2_1_949b3d746b_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mute_list_2_1_949b3d746b
    ADD CONSTRAINT mute_list_2_1_949b3d746b_pkey PRIMARY KEY (key);


--
-- Name: mute_lists_1_d90e559628 mute_lists_1_d90e559628_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.mute_lists_1_d90e559628
    ADD CONSTRAINT mute_lists_1_d90e559628_pkey PRIMARY KEY (key);


--
-- Name: muted_threads muted_threads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.muted_threads
    ADD CONSTRAINT muted_threads_pkey PRIMARY KEY (pubkey, root_eid);


--
-- Name: node_outputs_1_cfe6037c9f node_outputs_1_cfe6037c9f_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.node_outputs_1_cfe6037c9f
    ADD CONSTRAINT node_outputs_1_cfe6037c9f_pkey PRIMARY KEY (output);


--
-- Name: note_length_1_15d66ffae6 note_length_1_15d66ffae6_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.note_length_1_15d66ffae6
    ADD CONSTRAINT note_length_1_15d66ffae6_pkey PRIMARY KEY (eid);


--
-- Name: note_stats_1_07d205f278 note_stats_1_07d205f278_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.note_stats_1_07d205f278
    ADD CONSTRAINT note_stats_1_07d205f278_pkey PRIMARY KEY (eid);


--
-- Name: notification_types notification_types_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_types
    ADD CONSTRAINT notification_types_pk PRIMARY KEY (type);


--
-- Name: pubkey_content_zap_cnt_1_236df2f369 pubkey_content_zap_cnt_1_236df2f369_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pubkey_content_zap_cnt_1_236df2f369
    ADD CONSTRAINT pubkey_content_zap_cnt_1_236df2f369_pkey PRIMARY KEY (pubkey);


--
-- Name: pubkey_followers_cnt_1_a6f7e200e7 pubkey_followers_cnt_1_a6f7e200e7_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pubkey_followers_cnt_1_a6f7e200e7
    ADD CONSTRAINT pubkey_followers_cnt_1_a6f7e200e7_pkey PRIMARY KEY (key);


--
-- Name: pubkey_ids_1_54b55dd09c pubkey_ids_1_54b55dd09c_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pubkey_ids_1_54b55dd09c
    ADD CONSTRAINT pubkey_ids_1_54b55dd09c_pkey PRIMARY KEY (key);


--
-- Name: pubkey_ln_address_1_d3649b2898 pubkey_ln_address_1_d3649b2898_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pubkey_ln_address_1_d3649b2898
    ADD CONSTRAINT pubkey_ln_address_1_d3649b2898_pkey PRIMARY KEY (pubkey);


--
-- Name: pubkey_media_cnt_1_b5e2a488b1 pubkey_media_cnt_1_b5e2a488b1_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pubkey_media_cnt_1_b5e2a488b1
    ADD CONSTRAINT pubkey_media_cnt_1_b5e2a488b1_pkey PRIMARY KEY (pubkey);


--
-- Name: pubkey_notification_cnts_1_d78f6fcade pubkey_notification_cnts_1_d78f6fcade_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pubkey_notification_cnts_1_d78f6fcade
    ADD CONSTRAINT pubkey_notification_cnts_1_d78f6fcade_pkey PRIMARY KEY (pubkey);


--
-- Name: pubkey_trustrank pubkey_trustrank_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pubkey_trustrank
    ADD CONSTRAINT pubkey_trustrank_pkey PRIMARY KEY (pubkey);


--
-- Name: pubkey_zapped_1_17f1f622a9 pubkey_zapped_1_17f1f622a9_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pubkey_zapped_1_17f1f622a9
    ADD CONSTRAINT pubkey_zapped_1_17f1f622a9_pkey PRIMARY KEY (pubkey);


--
-- Name: reads_11_2a4d2ce519 reads_11_2a4d2ce519_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reads_11_2a4d2ce519
    ADD CONSTRAINT reads_11_2a4d2ce519_pkey PRIMARY KEY (pubkey, identifier);


--
-- Name: reads_12_68c6bbfccd reads_12_68c6bbfccd_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reads_12_68c6bbfccd
    ADD CONSTRAINT reads_12_68c6bbfccd_pkey PRIMARY KEY (pubkey, identifier);


--
-- Name: reads_versions_11_fb53a8e0b4 reads_versions_11_fb53a8e0b4_pubkey_identifier_eid_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reads_versions_11_fb53a8e0b4
    ADD CONSTRAINT reads_versions_11_fb53a8e0b4_pubkey_identifier_eid_key UNIQUE (pubkey, identifier, eid);


--
-- Name: reads_versions_12_b537d4df66 reads_versions_12_b537d4df66_pubkey_identifier_eid_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reads_versions_12_b537d4df66
    ADD CONSTRAINT reads_versions_12_b537d4df66_pubkey_identifier_eid_key UNIQUE (pubkey, identifier, eid);


--
-- Name: relay_list_metadata_1_801a17fc93 relay_list_metadata_1_801a17fc93_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.relay_list_metadata_1_801a17fc93
    ADD CONSTRAINT relay_list_metadata_1_801a17fc93_pkey PRIMARY KEY (pubkey);


--
-- Name: relay_url_map relay_url_map_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.relay_url_map
    ADD CONSTRAINT relay_url_map_pkey PRIMARY KEY (src);


--
-- Name: relays relays_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.relays
    ADD CONSTRAINT relays_pkey PRIMARY KEY (url);


--
-- Name: replaceable_events replaceable_events_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.replaceable_events
    ADD CONSTRAINT replaceable_events_pk PRIMARY KEY (pubkey, kind);


--
-- Name: text_metadata text_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.text_metadata
    ADD CONSTRAINT text_metadata_pkey PRIMARY KEY (sha256, model);


--
-- Name: trusted_pubkey_followers_cnt trusted_pubkey_followers_cnt_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trusted_pubkey_followers_cnt
    ADD CONSTRAINT trusted_pubkey_followers_cnt_pkey PRIMARY KEY (t, pubkey);


--
-- Name: user_search user_search_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_search
    ADD CONSTRAINT user_search_pkey PRIMARY KEY (pubkey);


--
-- Name: vars vars_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vars
    ADD CONSTRAINT vars_pkey PRIMARY KEY (key);


--
-- Name: wsconnruns wsconnruns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wsconnruns
    ADD CONSTRAINT wsconnruns_pkey PRIMARY KEY (run);


--
-- Name: wsconnvars wsconnvars_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wsconnvars
    ADD CONSTRAINT wsconnvars_pkey PRIMARY KEY (name);


--
-- Name: zap_receipts_1_9fe40119b2 zap_receipts_1_9fe40119b2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.zap_receipts_1_9fe40119b2
    ADD CONSTRAINT zap_receipts_1_9fe40119b2_pkey PRIMARY KEY (eid);


--
-- Name: a_tags_1_7d98c5333f_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX a_tags_1_7d98c5333f_created_at_idx ON public.a_tags_1_7d98c5333f USING btree (created_at);


--
-- Name: a_tags_1_7d98c5333f_eid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX a_tags_1_7d98c5333f_eid_idx ON public.a_tags_1_7d98c5333f USING btree (eid);


--
-- Name: a_tags_1_7d98c5333f_imported_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX a_tags_1_7d98c5333f_imported_at_idx ON public.a_tags_1_7d98c5333f USING btree (imported_at);


--
-- Name: a_tags_1_7d98c5333f_ref_kind_ref_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX a_tags_1_7d98c5333f_ref_kind_ref_pubkey_idx ON public.a_tags_1_7d98c5333f USING btree (ref_kind, ref_pubkey);


--
-- Name: a_tags_1_7d98c5333f_ref_kind_ref_pubkey_ref_identifier_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX a_tags_1_7d98c5333f_ref_kind_ref_pubkey_ref_identifier_idx ON public.a_tags_1_7d98c5333f USING btree (ref_kind, ref_pubkey, ref_identifier);


--
-- Name: advsearch_5_d7da6f551e_content_tsv_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX advsearch_5_d7da6f551e_content_tsv_idx ON public.advsearch_5_d7da6f551e USING gin (content_tsv);


--
-- Name: advsearch_5_d7da6f551e_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX advsearch_5_d7da6f551e_created_at_idx ON public.advsearch_5_d7da6f551e USING btree (created_at);


--
-- Name: advsearch_5_d7da6f551e_filter_tsv_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX advsearch_5_d7da6f551e_filter_tsv_idx ON public.advsearch_5_d7da6f551e USING gin (filter_tsv);


--
-- Name: advsearch_5_d7da6f551e_hashtag_tsv_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX advsearch_5_d7da6f551e_hashtag_tsv_idx ON public.advsearch_5_d7da6f551e USING gin (hashtag_tsv);


--
-- Name: advsearch_5_d7da6f551e_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX advsearch_5_d7da6f551e_id_idx ON public.advsearch_5_d7da6f551e USING btree (id);


--
-- Name: advsearch_5_d7da6f551e_kind_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX advsearch_5_d7da6f551e_kind_idx ON public.advsearch_5_d7da6f551e USING btree (kind);


--
-- Name: advsearch_5_d7da6f551e_mention_tsv_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX advsearch_5_d7da6f551e_mention_tsv_idx ON public.advsearch_5_d7da6f551e USING gin (mention_tsv);


--
-- Name: advsearch_5_d7da6f551e_pubkey_created_at_desc_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX advsearch_5_d7da6f551e_pubkey_created_at_desc_idx ON public.advsearch_5_d7da6f551e USING btree (pubkey, created_at DESC);


--
-- Name: advsearch_5_d7da6f551e_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX advsearch_5_d7da6f551e_pubkey_idx ON public.advsearch_5_d7da6f551e USING btree (pubkey);


--
-- Name: advsearch_5_d7da6f551e_reply_tsv_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX advsearch_5_d7da6f551e_reply_tsv_idx ON public.advsearch_5_d7da6f551e USING gin (reply_tsv);


--
-- Name: advsearch_5_d7da6f551e_url_tsv_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX advsearch_5_d7da6f551e_url_tsv_idx ON public.advsearch_5_d7da6f551e USING gin (url_tsv);


--
-- Name: allow_list_1_f1da08e9c8_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX allow_list_1_f1da08e9c8_key_idx ON public.allow_list_1_f1da08e9c8 USING btree (key);


--
-- Name: allow_list_1_f1da08e9c8_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX allow_list_1_f1da08e9c8_rowid_idx ON public.allow_list_1_f1da08e9c8 USING btree (rowid);


--
-- Name: basic_tags_6_62c3d17c2f_arg1_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX basic_tags_6_62c3d17c2f_arg1_idx ON public.basic_tags_6_62c3d17c2f USING hash (arg1);


--
-- Name: basic_tags_6_62c3d17c2f_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX basic_tags_6_62c3d17c2f_created_at_idx ON public.basic_tags_6_62c3d17c2f USING btree (created_at);


--
-- Name: basic_tags_6_62c3d17c2f_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX basic_tags_6_62c3d17c2f_id_idx ON public.basic_tags_6_62c3d17c2f USING btree (id);


--
-- Name: basic_tags_6_62c3d17c2f_imported_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX basic_tags_6_62c3d17c2f_imported_at_idx ON public.basic_tags_6_62c3d17c2f USING btree (imported_at);


--
-- Name: basic_tags_6_62c3d17c2f_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX basic_tags_6_62c3d17c2f_pubkey_idx ON public.basic_tags_6_62c3d17c2f USING btree (pubkey);


--
-- Name: bookmarks_1_43f5248b56_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX bookmarks_1_43f5248b56_pubkey_idx ON public.bookmarks_1_43f5248b56 USING btree (pubkey);


--
-- Name: bookmarks_1_43f5248b56_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX bookmarks_1_43f5248b56_rowid_idx ON public.bookmarks_1_43f5248b56 USING btree (rowid);


--
-- Name: cmr_groups_user_pubkey_grp_scope_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cmr_groups_user_pubkey_grp_scope_idx ON public.cmr_groups USING btree (user_pubkey, grp, scope);


--
-- Name: cmr_hashtags_2_user_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cmr_hashtags_2_user_pubkey_idx ON public.cmr_hashtags_2 USING btree (user_pubkey);


--
-- Name: cmr_hashtags_user_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cmr_hashtags_user_pubkey_idx ON public.cmr_hashtags USING btree (user_pubkey);


--
-- Name: cmr_pubkeys_allowed_user_pubkey_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cmr_pubkeys_allowed_user_pubkey_pubkey_idx ON public.cmr_pubkeys_allowed USING btree (user_pubkey, pubkey);


--
-- Name: cmr_pubkeys_parent_user_pubkey_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cmr_pubkeys_parent_user_pubkey_pubkey_idx ON public.cmr_pubkeys_parent USING btree (user_pubkey, pubkey);


--
-- Name: cmr_pubkeys_scopes_user_pubkey_pubkey_scope_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cmr_pubkeys_scopes_user_pubkey_pubkey_scope_idx ON public.cmr_pubkeys_scopes USING btree (user_pubkey, pubkey, scope);


--
-- Name: cmr_threads_user_pubkey_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cmr_threads_user_pubkey_event_id_idx ON public.cmr_threads USING btree (user_pubkey, event_id);


--
-- Name: cmr_words_2_user_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cmr_words_2_user_pubkey_idx ON public.cmr_words_2 USING btree (user_pubkey);


--
-- Name: cmr_words_user_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cmr_words_user_pubkey_idx ON public.cmr_words USING btree (user_pubkey);


--
-- Name: contact_lists_1_1abdf474bd_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contact_lists_1_1abdf474bd_key_idx ON public.contact_lists_1_1abdf474bd USING btree (key);


--
-- Name: contact_lists_1_1abdf474bd_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX contact_lists_1_1abdf474bd_rowid_idx ON public.contact_lists_1_1abdf474bd USING btree (rowid);


--
-- Name: coverages_1_8656fc443b_name_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX coverages_1_8656fc443b_name_idx ON public.coverages_1_8656fc443b USING btree (name);


--
-- Name: dag_1_4bd2aaff98_input_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX dag_1_4bd2aaff98_input_idx ON public.dag_1_4bd2aaff98 USING btree (input);


--
-- Name: dag_1_4bd2aaff98_output_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX dag_1_4bd2aaff98_output_idx ON public.dag_1_4bd2aaff98 USING btree (output);


--
-- Name: deleted_events_1_0249f47b16_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX deleted_events_1_0249f47b16_event_id_idx ON public.deleted_events_1_0249f47b16 USING btree (event_id);


--
-- Name: deleted_events_1_0249f47b16_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX deleted_events_1_0249f47b16_rowid_idx ON public.deleted_events_1_0249f47b16 USING btree (rowid);


--
-- Name: event_attributes_1_3196ca546f_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_attributes_1_3196ca546f_event_id_idx ON public.event_attributes_1_3196ca546f USING btree (event_id);


--
-- Name: event_attributes_1_3196ca546f_key_value_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_attributes_1_3196ca546f_key_value_idx ON public.event_attributes_1_3196ca546f USING btree (key, value);


--
-- Name: event_attributes_1_3196ca546f_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_attributes_1_3196ca546f_rowid_idx ON public.event_attributes_1_3196ca546f USING btree (rowid);


--
-- Name: event_created_at_1_7a51e16c5c_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_created_at_1_7a51e16c5c_created_at_idx ON public.event_created_at_1_7a51e16c5c USING btree (created_at);


--
-- Name: event_created_at_1_7a51e16c5c_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_created_at_1_7a51e16c5c_rowid_idx ON public.event_created_at_1_7a51e16c5c USING btree (rowid);


--
-- Name: event_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_created_at_idx ON public.event USING btree (created_at);


--
-- Name: event_created_at_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_created_at_kind ON public.event USING btree (created_at, kind);


--
-- Name: event_hashtags_1_295f217c0e_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_hashtags_1_295f217c0e_created_at_idx ON public.event_hashtags_1_295f217c0e USING btree (created_at);


--
-- Name: event_hashtags_1_295f217c0e_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_hashtags_1_295f217c0e_event_id_idx ON public.event_hashtags_1_295f217c0e USING btree (event_id);


--
-- Name: event_hashtags_1_295f217c0e_hashtag_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_hashtags_1_295f217c0e_hashtag_idx ON public.event_hashtags_1_295f217c0e USING btree (hashtag);


--
-- Name: event_hashtags_1_295f217c0e_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_hashtags_1_295f217c0e_rowid_idx ON public.event_hashtags_1_295f217c0e USING btree (rowid);


--
-- Name: event_hooks_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_hooks_event_id_idx ON public.event_hooks USING btree (event_id);


--
-- Name: event_imported_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_imported_at ON public.event USING btree (imported_at);


--
-- Name: event_imported_at_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_imported_at_id_idx ON public.event USING btree (imported_at, id);


--
-- Name: event_imported_at_kind_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_imported_at_kind_idx ON public.event USING btree (imported_at, kind);


--
-- Name: event_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_kind ON public.event USING btree (kind);


--
-- Name: event_media_1_30bf07e9cf_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_media_1_30bf07e9cf_event_id_idx ON public.event_media_1_30bf07e9cf USING btree (event_id);


--
-- Name: event_media_1_30bf07e9cf_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_media_1_30bf07e9cf_rowid_idx ON public.event_media_1_30bf07e9cf USING btree (rowid);


--
-- Name: event_media_1_30bf07e9cf_url_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_media_1_30bf07e9cf_url_idx ON public.event_media_1_30bf07e9cf USING btree (url);


--
-- Name: event_mentions_1_a056fb6737_eid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_mentions_1_a056fb6737_eid_idx ON public.event_mentions_1_a056fb6737 USING btree (eid);


--
-- Name: event_mentions_1_a056fb6737_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX event_mentions_1_a056fb6737_unique ON public.event_mentions_1_a056fb6737 USING btree (eid, tag, argeid, argpubkey, argkind, argid) NULLS NOT DISTINCT;


--
-- Name: event_preview_1_310cef356e_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_preview_1_310cef356e_event_id_idx ON public.event_preview_1_310cef356e USING btree (event_id);


--
-- Name: event_preview_1_310cef356e_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_preview_1_310cef356e_rowid_idx ON public.event_preview_1_310cef356e USING btree (rowid);


--
-- Name: event_preview_1_310cef356e_url_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_preview_1_310cef356e_url_idx ON public.event_preview_1_310cef356e USING btree (url);


--
-- Name: event_pubkey; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_pubkey ON public.event USING btree (pubkey);


--
-- Name: event_pubkey_action_refs_1_f32e1ff589_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_pubkey_action_refs_1_f32e1ff589_event_id_idx ON public.event_pubkey_action_refs_1_f32e1ff589 USING btree (event_id);


--
-- Name: event_pubkey_action_refs_1_f32e1ff589_ref_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_pubkey_action_refs_1_f32e1ff589_ref_created_at_idx ON public.event_pubkey_action_refs_1_f32e1ff589 USING btree (ref_created_at);


--
-- Name: event_pubkey_action_refs_1_f32e1ff589_ref_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_pubkey_action_refs_1_f32e1ff589_ref_event_id_idx ON public.event_pubkey_action_refs_1_f32e1ff589 USING btree (ref_event_id);


--
-- Name: event_pubkey_action_refs_1_f32e1ff589_ref_event_id_ref_kind_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_pubkey_action_refs_1_f32e1ff589_ref_event_id_ref_kind_idx ON public.event_pubkey_action_refs_1_f32e1ff589 USING btree (ref_event_id, ref_kind);


--
-- Name: event_pubkey_action_refs_1_f32e1ff589_ref_event_id_ref_pubkey_i; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_pubkey_action_refs_1_f32e1ff589_ref_event_id_ref_pubkey_i ON public.event_pubkey_action_refs_1_f32e1ff589 USING btree (ref_event_id, ref_pubkey);


--
-- Name: event_pubkey_action_refs_1_f32e1ff589_ref_kind_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_pubkey_action_refs_1_f32e1ff589_ref_kind_idx ON public.event_pubkey_action_refs_1_f32e1ff589 USING btree (ref_kind);


--
-- Name: event_pubkey_action_refs_1_f32e1ff589_ref_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_pubkey_action_refs_1_f32e1ff589_ref_pubkey_idx ON public.event_pubkey_action_refs_1_f32e1ff589 USING btree (ref_pubkey);


--
-- Name: event_pubkey_action_refs_1_f32e1ff589_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_pubkey_action_refs_1_f32e1ff589_rowid_idx ON public.event_pubkey_action_refs_1_f32e1ff589 USING btree (rowid);


--
-- Name: event_pubkey_actions_1_d62afee35d_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_pubkey_actions_1_d62afee35d_created_at_idx ON public.event_pubkey_actions_1_d62afee35d USING btree (created_at);


--
-- Name: event_pubkey_actions_1_d62afee35d_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_pubkey_actions_1_d62afee35d_event_id_idx ON public.event_pubkey_actions_1_d62afee35d USING btree (event_id);


--
-- Name: event_pubkey_actions_1_d62afee35d_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_pubkey_actions_1_d62afee35d_pubkey_idx ON public.event_pubkey_actions_1_d62afee35d USING btree (pubkey);


--
-- Name: event_pubkey_actions_1_d62afee35d_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_pubkey_actions_1_d62afee35d_rowid_idx ON public.event_pubkey_actions_1_d62afee35d USING btree (rowid);


--
-- Name: event_pubkey_actions_1_d62afee35d_updated_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_pubkey_actions_1_d62afee35d_updated_at_idx ON public.event_pubkey_actions_1_d62afee35d USING btree (updated_at);


--
-- Name: event_relays_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_relays_event_id_idx ON public.event_relays USING btree (event_id);


--
-- Name: event_relays_imported_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_relays_imported_at_idx ON public.event_relays USING btree (imported_at);


--
-- Name: event_replies_1_9d033b5bb3_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_replies_1_9d033b5bb3_event_id_idx ON public.event_replies_1_9d033b5bb3 USING btree (event_id);


--
-- Name: event_replies_1_9d033b5bb3_reply_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_replies_1_9d033b5bb3_reply_created_at_idx ON public.event_replies_1_9d033b5bb3 USING btree (reply_created_at);


--
-- Name: event_replies_1_9d033b5bb3_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_replies_1_9d033b5bb3_rowid_idx ON public.event_replies_1_9d033b5bb3 USING btree (rowid);


--
-- Name: event_sentiment_1_d3d7a00a54_topsentiment_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_sentiment_1_d3d7a00a54_topsentiment_idx ON public.event_sentiment_1_d3d7a00a54 USING btree (topsentiment);


--
-- Name: event_stats_1_1b380f4869_author_pubkey_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_author_pubkey_created_at_idx ON public.event_stats_1_1b380f4869 USING btree (author_pubkey, created_at);


--
-- Name: event_stats_1_1b380f4869_author_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_author_pubkey_idx ON public.event_stats_1_1b380f4869 USING btree (author_pubkey);


--
-- Name: event_stats_1_1b380f4869_author_pubkey_satszapped_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_author_pubkey_satszapped_idx ON public.event_stats_1_1b380f4869 USING btree (author_pubkey, satszapped);


--
-- Name: event_stats_1_1b380f4869_author_pubkey_score24h_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_author_pubkey_score24h_idx ON public.event_stats_1_1b380f4869 USING btree (author_pubkey, score24h);


--
-- Name: event_stats_1_1b380f4869_author_pubkey_score_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_author_pubkey_score_idx ON public.event_stats_1_1b380f4869 USING btree (author_pubkey, score);


--
-- Name: event_stats_1_1b380f4869_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_created_at_idx ON public.event_stats_1_1b380f4869 USING btree (created_at);


--
-- Name: event_stats_1_1b380f4869_created_at_satszapped_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_created_at_satszapped_idx ON public.event_stats_1_1b380f4869 USING btree (created_at, satszapped);


--
-- Name: event_stats_1_1b380f4869_created_at_score24h_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_created_at_score24h_idx ON public.event_stats_1_1b380f4869 USING btree (created_at, score24h);


--
-- Name: event_stats_1_1b380f4869_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_event_id_idx ON public.event_stats_1_1b380f4869 USING btree (event_id);


--
-- Name: event_stats_1_1b380f4869_likes_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_likes_idx ON public.event_stats_1_1b380f4869 USING btree (likes);


--
-- Name: event_stats_1_1b380f4869_mentions_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_mentions_idx ON public.event_stats_1_1b380f4869 USING btree (mentions);


--
-- Name: event_stats_1_1b380f4869_replies_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_replies_idx ON public.event_stats_1_1b380f4869 USING btree (replies);


--
-- Name: event_stats_1_1b380f4869_reposts_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_reposts_idx ON public.event_stats_1_1b380f4869 USING btree (reposts);


--
-- Name: event_stats_1_1b380f4869_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_rowid_idx ON public.event_stats_1_1b380f4869 USING btree (rowid);


--
-- Name: event_stats_1_1b380f4869_satszapped_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_satszapped_idx ON public.event_stats_1_1b380f4869 USING btree (satszapped);


--
-- Name: event_stats_1_1b380f4869_score24h_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_score24h_idx ON public.event_stats_1_1b380f4869 USING btree (score24h);


--
-- Name: event_stats_1_1b380f4869_score_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_score_created_at_idx ON public.event_stats_1_1b380f4869 USING btree (score DESC, created_at);


--
-- Name: event_stats_1_1b380f4869_score_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_score_idx ON public.event_stats_1_1b380f4869 USING btree (score);


--
-- Name: event_stats_1_1b380f4869_zaps_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_zaps_idx ON public.event_stats_1_1b380f4869 USING btree (zaps);


--
-- Name: event_stats_by_pubkey_1_4ecc48a026_author_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_by_pubkey_1_4ecc48a026_author_pubkey_idx ON public.event_stats_by_pubkey_1_4ecc48a026 USING btree (author_pubkey);


--
-- Name: event_stats_by_pubkey_1_4ecc48a026_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_by_pubkey_1_4ecc48a026_created_at_idx ON public.event_stats_by_pubkey_1_4ecc48a026 USING btree (created_at);


--
-- Name: event_stats_by_pubkey_1_4ecc48a026_created_at_satszapped_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_by_pubkey_1_4ecc48a026_created_at_satszapped_idx ON public.event_stats_by_pubkey_1_4ecc48a026 USING btree (created_at, satszapped);


--
-- Name: event_stats_by_pubkey_1_4ecc48a026_created_at_score24h_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_by_pubkey_1_4ecc48a026_created_at_score24h_idx ON public.event_stats_by_pubkey_1_4ecc48a026 USING btree (created_at, score24h);


--
-- Name: event_stats_by_pubkey_1_4ecc48a026_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_by_pubkey_1_4ecc48a026_event_id_idx ON public.event_stats_by_pubkey_1_4ecc48a026 USING btree (event_id);


--
-- Name: event_stats_by_pubkey_1_4ecc48a026_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_by_pubkey_1_4ecc48a026_rowid_idx ON public.event_stats_by_pubkey_1_4ecc48a026 USING btree (rowid);


--
-- Name: event_stats_by_pubkey_1_4ecc48a026_satszapped_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_by_pubkey_1_4ecc48a026_satszapped_idx ON public.event_stats_by_pubkey_1_4ecc48a026 USING btree (satszapped);


--
-- Name: event_stats_by_pubkey_1_4ecc48a026_score24h_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_by_pubkey_1_4ecc48a026_score24h_idx ON public.event_stats_by_pubkey_1_4ecc48a026 USING btree (score24h);


--
-- Name: event_stats_by_pubkey_1_4ecc48a026_score_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_by_pubkey_1_4ecc48a026_score_idx ON public.event_stats_by_pubkey_1_4ecc48a026 USING btree (score);


--
-- Name: event_thread_parents_1_e17bf16c98_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_thread_parents_1_e17bf16c98_key_idx ON public.event_thread_parents_1_e17bf16c98 USING btree (key);


--
-- Name: event_thread_parents_1_e17bf16c98_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_thread_parents_1_e17bf16c98_rowid_idx ON public.event_thread_parents_1_e17bf16c98 USING btree (rowid);


--
-- Name: event_zapped_1_7ebdbebf92_event_id_zap_sender_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_zapped_1_7ebdbebf92_event_id_zap_sender_idx ON public.event_zapped_1_7ebdbebf92 USING btree (event_id, zap_sender);


--
-- Name: event_zapped_1_7ebdbebf92_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_zapped_1_7ebdbebf92_rowid_idx ON public.event_zapped_1_7ebdbebf92 USING btree (rowid);


--
-- Name: fetcher_relays_updated_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fetcher_relays_updated_at_index ON public.fetcher_relays USING btree (updated_at);


--
-- Name: filterlist_pubkey_pubkey_blocked_grp_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX filterlist_pubkey_pubkey_blocked_grp_idx ON public.filterlist_pubkey USING btree (pubkey, blocked, grp);


--
-- Name: follow_lists_pubkey_identifier_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX follow_lists_pubkey_identifier_idx ON public.follow_lists USING btree (pubkey, identifier);


--
-- Name: hashtags_1_1e5c72161a_hashtag_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX hashtags_1_1e5c72161a_hashtag_idx ON public.hashtags_1_1e5c72161a USING btree (hashtag);


--
-- Name: hashtags_1_1e5c72161a_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX hashtags_1_1e5c72161a_rowid_idx ON public.hashtags_1_1e5c72161a USING btree (rowid);


--
-- Name: hashtags_1_1e5c72161a_score_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX hashtags_1_1e5c72161a_score_idx ON public.hashtags_1_1e5c72161a USING btree (score);


--
-- Name: human_override_pubkey; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX human_override_pubkey ON public.human_override USING btree (pubkey);


--
-- Name: lists_added_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lists_added_at ON public.lists USING btree (added_at DESC);


--
-- Name: lists_list; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lists_list ON public.lists USING btree (list);


--
-- Name: lists_pubkey; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lists_pubkey ON public.lists USING btree (pubkey);


--
-- Name: live_event_participants_kind_participant_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX live_event_participants_kind_participant_pubkey_idx ON public.live_event_participants USING btree (kind, participant_pubkey);


--
-- Name: live_event_participants_kind_pubkey_identifier_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX live_event_participants_kind_pubkey_identifier_idx ON public.live_event_participants USING btree (kind, pubkey, identifier);


--
-- Name: logs_1_d241bdb71c_eid; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX logs_1_d241bdb71c_eid ON public.logs_1_d241bdb71c USING btree (((d ->> 'eid'::text)));


--
-- Name: logs_1_d241bdb71c_func_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX logs_1_d241bdb71c_func_idx ON public.logs_1_d241bdb71c USING btree (func);


--
-- Name: logs_1_d241bdb71c_module_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX logs_1_d241bdb71c_module_idx ON public.logs_1_d241bdb71c USING btree (module);


--
-- Name: logs_1_d241bdb71c_t_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX logs_1_d241bdb71c_t_idx ON public.logs_1_d241bdb71c USING btree (t);


--
-- Name: logs_1_d241bdb71c_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX logs_1_d241bdb71c_type_idx ON public.logs_1_d241bdb71c USING btree (type);


--
-- Name: media_1_16fa35f2dc_category_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_1_16fa35f2dc_category_idx ON public.media_1_16fa35f2dc USING btree (category);


--
-- Name: media_1_16fa35f2dc_imported_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_1_16fa35f2dc_imported_at_idx ON public.media_1_16fa35f2dc USING btree (imported_at);


--
-- Name: media_1_16fa35f2dc_media_url_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_1_16fa35f2dc_media_url_idx ON public.media_1_16fa35f2dc USING btree (media_url);


--
-- Name: media_1_16fa35f2dc_orig_sha256_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_1_16fa35f2dc_orig_sha256_idx ON public.media_1_16fa35f2dc USING btree (orig_sha256);


--
-- Name: media_1_16fa35f2dc_orig_sha256_size_animated_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_1_16fa35f2dc_orig_sha256_size_animated_idx ON public.media_1_16fa35f2dc USING btree (orig_sha256, size, animated);


--
-- Name: media_1_16fa35f2dc_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_1_16fa35f2dc_rowid_idx ON public.media_1_16fa35f2dc USING btree (rowid);


--
-- Name: media_1_16fa35f2dc_size_animated_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_1_16fa35f2dc_size_animated_idx ON public.media_1_16fa35f2dc USING btree (size, animated);


--
-- Name: media_1_16fa35f2dc_url_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_1_16fa35f2dc_url_idx ON public.media_1_16fa35f2dc USING btree (url);


--
-- Name: media_1_16fa35f2dc_url_size_animated_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_1_16fa35f2dc_url_size_animated_idx ON public.media_1_16fa35f2dc USING btree (url, size, animated);


--
-- Name: media_storage_added_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_storage_added_at_idx ON public.media_storage USING btree (added_at);


--
-- Name: media_storage_h_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_storage_h_idx ON public.media_storage USING btree (h);


--
-- Name: media_storage_key_sha256_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_storage_key_sha256_idx ON public.media_storage USING btree ((((key)::jsonb ->> 'sha256'::text)));


--
-- Name: media_storage_media_block_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_storage_media_block_id_idx ON public.media_storage USING btree (media_block_id);


--
-- Name: media_storage_sha256_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_storage_sha256_idx ON public.media_storage USING btree (sha256);


--
-- Name: memberships_pubkey; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memberships_pubkey ON public.memberships USING btree (pubkey);


--
-- Name: meta_data_1_323bc43167_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meta_data_1_323bc43167_key_idx ON public.meta_data_1_323bc43167 USING btree (key);


--
-- Name: meta_data_1_323bc43167_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX meta_data_1_323bc43167_rowid_idx ON public.meta_data_1_323bc43167 USING btree (rowid);


--
-- Name: mute_list_1_f693a878b9_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX mute_list_1_f693a878b9_key_idx ON public.mute_list_1_f693a878b9 USING btree (key);


--
-- Name: mute_list_1_f693a878b9_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX mute_list_1_f693a878b9_rowid_idx ON public.mute_list_1_f693a878b9 USING btree (rowid);


--
-- Name: mute_list_2_1_949b3d746b_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX mute_list_2_1_949b3d746b_key_idx ON public.mute_list_2_1_949b3d746b USING btree (key);


--
-- Name: mute_list_2_1_949b3d746b_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX mute_list_2_1_949b3d746b_rowid_idx ON public.mute_list_2_1_949b3d746b USING btree (rowid);


--
-- Name: mute_lists_1_d90e559628_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX mute_lists_1_d90e559628_key_idx ON public.mute_lists_1_d90e559628 USING btree (key);


--
-- Name: mute_lists_1_d90e559628_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX mute_lists_1_d90e559628_rowid_idx ON public.mute_lists_1_d90e559628 USING btree (rowid);


--
-- Name: og_zap_receipts_1_dc85307383_amount_sats_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX og_zap_receipts_1_dc85307383_amount_sats_idx ON public.og_zap_receipts_1_dc85307383 USING btree (amount_sats);


--
-- Name: og_zap_receipts_1_dc85307383_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX og_zap_receipts_1_dc85307383_created_at_idx ON public.og_zap_receipts_1_dc85307383 USING btree (created_at);


--
-- Name: og_zap_receipts_1_dc85307383_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX og_zap_receipts_1_dc85307383_event_id_idx ON public.og_zap_receipts_1_dc85307383 USING btree (event_id);


--
-- Name: og_zap_receipts_1_dc85307383_receiver_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX og_zap_receipts_1_dc85307383_receiver_idx ON public.og_zap_receipts_1_dc85307383 USING btree (receiver);


--
-- Name: og_zap_receipts_1_dc85307383_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX og_zap_receipts_1_dc85307383_rowid_idx ON public.og_zap_receipts_1_dc85307383 USING btree (rowid);


--
-- Name: og_zap_receipts_1_dc85307383_sender_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX og_zap_receipts_1_dc85307383_sender_idx ON public.og_zap_receipts_1_dc85307383 USING btree (sender);


--
-- Name: parameterized_replaceable_list_1_d02d7ecc62_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX parameterized_replaceable_list_1_d02d7ecc62_created_at_idx ON public.parameterized_replaceable_list_1_d02d7ecc62 USING btree (created_at);


--
-- Name: parameterized_replaceable_list_1_d02d7ecc62_identifier_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX parameterized_replaceable_list_1_d02d7ecc62_identifier_idx ON public.parameterized_replaceable_list_1_d02d7ecc62 USING btree (identifier);


--
-- Name: parameterized_replaceable_list_1_d02d7ecc62_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX parameterized_replaceable_list_1_d02d7ecc62_pubkey_idx ON public.parameterized_replaceable_list_1_d02d7ecc62 USING btree (pubkey);


--
-- Name: parameterized_replaceable_list_1_d02d7ecc62_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX parameterized_replaceable_list_1_d02d7ecc62_rowid_idx ON public.parameterized_replaceable_list_1_d02d7ecc62 USING btree (rowid);


--
-- Name: parametrized_replaceable_events_1_cbe75c8d53_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX parametrized_replaceable_events_1_cbe75c8d53_created_at_idx ON public.parametrized_replaceable_events_1_cbe75c8d53 USING btree (created_at);


--
-- Name: parametrized_replaceable_events_1_cbe75c8d53_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX parametrized_replaceable_events_1_cbe75c8d53_event_id_idx ON public.parametrized_replaceable_events_1_cbe75c8d53 USING btree (event_id);


--
-- Name: parametrized_replaceable_events_1_cbe75c8d53_identifier_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX parametrized_replaceable_events_1_cbe75c8d53_identifier_idx ON public.parametrized_replaceable_events_1_cbe75c8d53 USING btree (identifier);


--
-- Name: parametrized_replaceable_events_1_cbe75c8d53_kind_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX parametrized_replaceable_events_1_cbe75c8d53_kind_idx ON public.parametrized_replaceable_events_1_cbe75c8d53 USING btree (kind);


--
-- Name: parametrized_replaceable_events_1_cbe75c8d53_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX parametrized_replaceable_events_1_cbe75c8d53_pubkey_idx ON public.parametrized_replaceable_events_1_cbe75c8d53 USING btree (pubkey);


--
-- Name: parametrized_replaceable_events_1_cbe75c8d53_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX parametrized_replaceable_events_1_cbe75c8d53_rowid_idx ON public.parametrized_replaceable_events_1_cbe75c8d53 USING btree (rowid);


--
-- Name: preview_1_44299731c7_category_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX preview_1_44299731c7_category_idx ON public.preview_1_44299731c7 USING btree (category);


--
-- Name: preview_1_44299731c7_imported_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX preview_1_44299731c7_imported_at_idx ON public.preview_1_44299731c7 USING btree (imported_at);


--
-- Name: preview_1_44299731c7_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX preview_1_44299731c7_rowid_idx ON public.preview_1_44299731c7 USING btree (rowid);


--
-- Name: preview_1_44299731c7_url_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX preview_1_44299731c7_url_idx ON public.preview_1_44299731c7 USING btree (url);


--
-- Name: pubkey_bookmarks_pubkey_ref_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_bookmarks_pubkey_ref_event_id ON public.pubkey_bookmarks USING btree (pubkey, ref_event_id);


--
-- Name: pubkey_bookmarks_ref_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_bookmarks_ref_event_id ON public.pubkey_bookmarks USING btree (ref_event_id);


--
-- Name: pubkey_content_zap_cnt_1_236df2f369_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_content_zap_cnt_1_236df2f369_pubkey_idx ON public.pubkey_content_zap_cnt_1_236df2f369 USING btree (pubkey);


--
-- Name: pubkey_directmsgs_1_c794110a2c_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_directmsgs_1_c794110a2c_created_at_idx ON public.pubkey_directmsgs_1_c794110a2c USING btree (created_at);


--
-- Name: pubkey_directmsgs_1_c794110a2c_receiver_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_directmsgs_1_c794110a2c_receiver_event_id_idx ON public.pubkey_directmsgs_1_c794110a2c USING btree (receiver, event_id);


--
-- Name: pubkey_directmsgs_1_c794110a2c_receiver_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_directmsgs_1_c794110a2c_receiver_idx ON public.pubkey_directmsgs_1_c794110a2c USING btree (receiver);


--
-- Name: pubkey_directmsgs_1_c794110a2c_receiver_sender_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_directmsgs_1_c794110a2c_receiver_sender_idx ON public.pubkey_directmsgs_1_c794110a2c USING btree (receiver, sender);


--
-- Name: pubkey_directmsgs_1_c794110a2c_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_directmsgs_1_c794110a2c_rowid_idx ON public.pubkey_directmsgs_1_c794110a2c USING btree (rowid);


--
-- Name: pubkey_directmsgs_1_c794110a2c_sender_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_directmsgs_1_c794110a2c_sender_idx ON public.pubkey_directmsgs_1_c794110a2c USING btree (sender);


--
-- Name: pubkey_directmsgs_cnt_1_efdf9742a6_receiver_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_directmsgs_cnt_1_efdf9742a6_receiver_idx ON public.pubkey_directmsgs_cnt_1_efdf9742a6 USING btree (receiver);


--
-- Name: pubkey_directmsgs_cnt_1_efdf9742a6_receiver_sender_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_directmsgs_cnt_1_efdf9742a6_receiver_sender_idx ON public.pubkey_directmsgs_cnt_1_efdf9742a6 USING btree (receiver, sender);


--
-- Name: pubkey_directmsgs_cnt_1_efdf9742a6_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_directmsgs_cnt_1_efdf9742a6_rowid_idx ON public.pubkey_directmsgs_cnt_1_efdf9742a6 USING btree (rowid);


--
-- Name: pubkey_directmsgs_cnt_1_efdf9742a6_sender_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_directmsgs_cnt_1_efdf9742a6_sender_idx ON public.pubkey_directmsgs_cnt_1_efdf9742a6 USING btree (sender);


--
-- Name: pubkey_events_1_1dcbfe1466_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_events_1_1dcbfe1466_created_at_idx ON public.pubkey_events_1_1dcbfe1466 USING btree (created_at);


--
-- Name: pubkey_events_1_1dcbfe1466_created_at_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_events_1_1dcbfe1466_created_at_pubkey_idx ON public.pubkey_events_1_1dcbfe1466 USING btree (created_at DESC, pubkey);


--
-- Name: pubkey_events_1_1dcbfe1466_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_events_1_1dcbfe1466_event_id_idx ON public.pubkey_events_1_1dcbfe1466 USING btree (event_id);


--
-- Name: pubkey_events_1_1dcbfe1466_pubkey_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_events_1_1dcbfe1466_pubkey_created_at_idx ON public.pubkey_events_1_1dcbfe1466 USING btree (pubkey, created_at);


--
-- Name: pubkey_events_1_1dcbfe1466_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_events_1_1dcbfe1466_pubkey_idx ON public.pubkey_events_1_1dcbfe1466 USING btree (pubkey);


--
-- Name: pubkey_events_1_1dcbfe1466_pubkey_is_reply_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_events_1_1dcbfe1466_pubkey_is_reply_idx ON public.pubkey_events_1_1dcbfe1466 USING btree (pubkey, is_reply);


--
-- Name: pubkey_events_1_1dcbfe1466_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_events_1_1dcbfe1466_rowid_idx ON public.pubkey_events_1_1dcbfe1466 USING btree (rowid);


--
-- Name: pubkey_followers_1_d52305fb47_follower_contact_list_event_id_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_followers_1_d52305fb47_follower_contact_list_event_id_id ON public.pubkey_followers_1_d52305fb47 USING btree (follower_contact_list_event_id);


--
-- Name: pubkey_followers_1_d52305fb47_follower_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_followers_1_d52305fb47_follower_pubkey_idx ON public.pubkey_followers_1_d52305fb47 USING btree (follower_pubkey);


--
-- Name: pubkey_followers_1_d52305fb47_follower_pubkey_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_followers_1_d52305fb47_follower_pubkey_pubkey_idx ON public.pubkey_followers_1_d52305fb47 USING btree (follower_pubkey, pubkey);


--
-- Name: pubkey_followers_1_d52305fb47_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_followers_1_d52305fb47_pubkey_idx ON public.pubkey_followers_1_d52305fb47 USING btree (pubkey);


--
-- Name: pubkey_followers_1_d52305fb47_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_followers_1_d52305fb47_rowid_idx ON public.pubkey_followers_1_d52305fb47 USING btree (rowid);


--
-- Name: pubkey_followers_cnt_1_a6f7e200e7_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_followers_cnt_1_a6f7e200e7_key_idx ON public.pubkey_followers_cnt_1_a6f7e200e7 USING btree (key);


--
-- Name: pubkey_followers_cnt_1_a6f7e200e7_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_followers_cnt_1_a6f7e200e7_rowid_idx ON public.pubkey_followers_cnt_1_a6f7e200e7 USING btree (rowid);


--
-- Name: pubkey_followers_cnt_1_a6f7e200e7_value_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_followers_cnt_1_a6f7e200e7_value_idx ON public.pubkey_followers_cnt_1_a6f7e200e7 USING btree (value);


--
-- Name: pubkey_ids_1_54b55dd09c_key_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_ids_1_54b55dd09c_key_idx ON public.pubkey_ids_1_54b55dd09c USING btree (key);


--
-- Name: pubkey_ids_1_54b55dd09c_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_ids_1_54b55dd09c_rowid_idx ON public.pubkey_ids_1_54b55dd09c USING btree (rowid);


--
-- Name: pubkey_ln_address_1_d3649b2898_ln_address_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_ln_address_1_d3649b2898_ln_address_idx ON public.pubkey_ln_address_1_d3649b2898 USING btree (ln_address);


--
-- Name: pubkey_ln_address_1_d3649b2898_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_ln_address_1_d3649b2898_pubkey_idx ON public.pubkey_ln_address_1_d3649b2898 USING btree (pubkey);


--
-- Name: pubkey_ln_address_1_d3649b2898_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_ln_address_1_d3649b2898_rowid_idx ON public.pubkey_ln_address_1_d3649b2898 USING btree (rowid);


--
-- Name: pubkey_media_cnt_1_b5e2a488b1_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_media_cnt_1_b5e2a488b1_pubkey_idx ON public.pubkey_media_cnt_1_b5e2a488b1 USING btree (pubkey);


--
-- Name: pubkey_notification_cnts_1_d78f6fcade_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_notification_cnts_1_d78f6fcade_pubkey_idx ON public.pubkey_notification_cnts_1_d78f6fcade USING btree (pubkey);


--
-- Name: pubkey_notification_cnts_1_d78f6fcade_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_notification_cnts_1_d78f6fcade_rowid_idx ON public.pubkey_notification_cnts_1_d78f6fcade USING btree (rowid);


--
-- Name: pubkey_notifications_1_e5459ab9dd_arg1_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_notifications_1_e5459ab9dd_arg1_idx ON public.pubkey_notifications_1_e5459ab9dd USING btree (arg1);


--
-- Name: pubkey_notifications_1_e5459ab9dd_arg2_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_notifications_1_e5459ab9dd_arg2_idx ON public.pubkey_notifications_1_e5459ab9dd USING btree (arg2);


--
-- Name: pubkey_notifications_1_e5459ab9dd_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_notifications_1_e5459ab9dd_created_at_idx ON public.pubkey_notifications_1_e5459ab9dd USING btree (created_at);


--
-- Name: pubkey_notifications_1_e5459ab9dd_pubkey_arg1_idx_; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_notifications_1_e5459ab9dd_pubkey_arg1_idx_ ON public.pubkey_notifications_1_e5459ab9dd USING btree (pubkey, arg1) WHERE ((type <> 1) AND (type <> 2));


--
-- Name: pubkey_notifications_1_e5459ab9dd_pubkey_arg2_idx_; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_notifications_1_e5459ab9dd_pubkey_arg2_idx_ ON public.pubkey_notifications_1_e5459ab9dd USING btree (pubkey, arg2) WHERE ((type <> 1) AND (type <> 2));


--
-- Name: pubkey_notifications_1_e5459ab9dd_pubkey_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_notifications_1_e5459ab9dd_pubkey_created_at_idx ON public.pubkey_notifications_1_e5459ab9dd USING btree (pubkey, created_at);


--
-- Name: pubkey_notifications_1_e5459ab9dd_pubkey_created_at_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_notifications_1_e5459ab9dd_pubkey_created_at_type_idx ON public.pubkey_notifications_1_e5459ab9dd USING btree (pubkey, created_at, type);


--
-- Name: pubkey_notifications_1_e5459ab9dd_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_notifications_1_e5459ab9dd_pubkey_idx ON public.pubkey_notifications_1_e5459ab9dd USING btree (pubkey);


--
-- Name: pubkey_notifications_1_e5459ab9dd_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_notifications_1_e5459ab9dd_rowid_idx ON public.pubkey_notifications_1_e5459ab9dd USING btree (rowid);


--
-- Name: pubkey_notifications_1_e5459ab9dd_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_notifications_1_e5459ab9dd_type_idx ON public.pubkey_notifications_1_e5459ab9dd USING btree (type);


--
-- Name: pubkey_zapped_1_17f1f622a9_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_zapped_1_17f1f622a9_pubkey_idx ON public.pubkey_zapped_1_17f1f622a9 USING btree (pubkey);


--
-- Name: pubkey_zapped_1_17f1f622a9_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_zapped_1_17f1f622a9_rowid_idx ON public.pubkey_zapped_1_17f1f622a9 USING btree (rowid);


--
-- Name: pubkey_zapped_1_17f1f622a9_satszapped_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_zapped_1_17f1f622a9_satszapped_idx ON public.pubkey_zapped_1_17f1f622a9 USING btree (satszapped);


--
-- Name: pubkey_zapped_1_17f1f622a9_zaps_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_zapped_1_17f1f622a9_zaps_idx ON public.pubkey_zapped_1_17f1f622a9 USING btree (zaps);


--
-- Name: reads_11_2a4d2ce519_identifier_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reads_11_2a4d2ce519_identifier_idx ON public.reads_11_2a4d2ce519 USING btree (identifier);


--
-- Name: reads_11_2a4d2ce519_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reads_11_2a4d2ce519_pubkey_idx ON public.reads_11_2a4d2ce519 USING btree (pubkey);


--
-- Name: reads_11_2a4d2ce519_published_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reads_11_2a4d2ce519_published_at_idx ON public.reads_11_2a4d2ce519 USING btree (published_at);


--
-- Name: reads_11_2a4d2ce519_topics_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reads_11_2a4d2ce519_topics_idx ON public.reads_11_2a4d2ce519 USING gin (topics);


--
-- Name: reads_12_68c6bbfccd_identifier_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reads_12_68c6bbfccd_identifier_idx ON public.reads_12_68c6bbfccd USING btree (identifier);


--
-- Name: reads_12_68c6bbfccd_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reads_12_68c6bbfccd_pubkey_idx ON public.reads_12_68c6bbfccd USING btree (pubkey);


--
-- Name: reads_12_68c6bbfccd_published_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reads_12_68c6bbfccd_published_at_idx ON public.reads_12_68c6bbfccd USING btree (published_at);


--
-- Name: reads_12_68c6bbfccd_topics_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reads_12_68c6bbfccd_topics_idx ON public.reads_12_68c6bbfccd USING gin (topics);


--
-- Name: reads_latest_eid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reads_latest_eid_idx ON public.reads_12_68c6bbfccd USING btree (latest_eid);


--
-- Name: reads_versions_11_fb53a8e0b4_eid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reads_versions_11_fb53a8e0b4_eid_idx ON public.reads_versions_11_fb53a8e0b4 USING hash (eid);


--
-- Name: reads_versions_11_fb53a8e0b4_identifier_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reads_versions_11_fb53a8e0b4_identifier_idx ON public.reads_versions_11_fb53a8e0b4 USING btree (identifier);


--
-- Name: reads_versions_11_fb53a8e0b4_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reads_versions_11_fb53a8e0b4_pubkey_idx ON public.reads_versions_11_fb53a8e0b4 USING btree (pubkey);


--
-- Name: reads_versions_12_b537d4df66_eid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reads_versions_12_b537d4df66_eid_idx ON public.reads_versions_12_b537d4df66 USING hash (eid);


--
-- Name: reads_versions_12_b537d4df66_identifier_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reads_versions_12_b537d4df66_identifier_idx ON public.reads_versions_12_b537d4df66 USING btree (identifier);


--
-- Name: reads_versions_12_b537d4df66_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reads_versions_12_b537d4df66_pubkey_idx ON public.reads_versions_12_b537d4df66 USING btree (pubkey);


--
-- Name: relay_list_metadata_1_801a17fc93_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX relay_list_metadata_1_801a17fc93_pubkey_idx ON public.relay_list_metadata_1_801a17fc93 USING btree (pubkey);


--
-- Name: relay_list_metadata_1_801a17fc93_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX relay_list_metadata_1_801a17fc93_rowid_idx ON public.relay_list_metadata_1_801a17fc93 USING btree (rowid);


--
-- Name: relays_times_referenced_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX relays_times_referenced_idx ON public.relays USING btree (times_referenced DESC);


--
-- Name: scheduled_hooks_execute_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX scheduled_hooks_execute_at_idx ON public.scheduled_hooks USING btree (execute_at);


--
-- Name: score_expiry_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX score_expiry_event_id_idx ON public.score_expiry USING btree (event_id);


--
-- Name: score_expiry_expire_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX score_expiry_expire_at_idx ON public.score_expiry USING btree (expire_at);


--
-- Name: stuff_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX stuff_created_at ON public.stuff USING btree (created_at DESC);


--
-- Name: text_metadata_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX text_metadata_event_id_idx ON public.text_metadata USING btree (event_id);


--
-- Name: user_search_display_name_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_search_display_name_idx ON public.user_search USING gin (display_name);


--
-- Name: user_search_displayname_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_search_displayname_idx ON public.user_search USING gin (displayname);


--
-- Name: user_search_lud16_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_search_lud16_idx ON public.user_search USING gin (lud16);


--
-- Name: user_search_name_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_search_name_idx ON public.user_search USING gin (name);


--
-- Name: user_search_nip05_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_search_nip05_idx ON public.user_search USING gin (nip05);


--
-- Name: user_search_username_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_search_username_idx ON public.user_search USING gin (username);


--
-- Name: verified_users_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX verified_users_name ON public.verified_users USING btree (name);


--
-- Name: verified_users_pubkey; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX verified_users_pubkey ON public.verified_users USING btree (pubkey);


--
-- Name: video_thumbnails_1_107d5a46eb_rowid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX video_thumbnails_1_107d5a46eb_rowid_idx ON public.video_thumbnails_1_107d5a46eb USING btree (rowid);


--
-- Name: video_thumbnails_1_107d5a46eb_thumbnail_url_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX video_thumbnails_1_107d5a46eb_thumbnail_url_idx ON public.video_thumbnails_1_107d5a46eb USING btree (thumbnail_url);


--
-- Name: video_thumbnails_1_107d5a46eb_video_url_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX video_thumbnails_1_107d5a46eb_video_url_idx ON public.video_thumbnails_1_107d5a46eb USING btree (video_url);


--
-- Name: wsconnlog_t_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX wsconnlog_t_idx ON public.wsconnlog USING btree (t);


--
-- Name: zap_receipts_1_9fe40119b2_imported_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX zap_receipts_1_9fe40119b2_imported_at_idx ON public.zap_receipts_1_9fe40119b2 USING btree (imported_at);


--
-- Name: zap_receipts_1_9fe40119b2_receiver_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX zap_receipts_1_9fe40119b2_receiver_idx ON public.zap_receipts_1_9fe40119b2 USING btree (receiver);


--
-- Name: zap_receipts_1_9fe40119b2_sender_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX zap_receipts_1_9fe40119b2_sender_idx ON public.zap_receipts_1_9fe40119b2 USING btree (sender);


--
-- Name: zap_receipts_1_9fe40119b2_target_eid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX zap_receipts_1_9fe40119b2_target_eid_idx ON public.zap_receipts_1_9fe40119b2 USING btree (target_eid);


--
-- Name: cache update_cache_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_cache_updated_at BEFORE UPDATE ON public.cache FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


--
-- PostgreSQL database dump complete
--

