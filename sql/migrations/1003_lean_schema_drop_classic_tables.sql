-- lock_timeout: 30s
-- The lean cache schema is the only one (2026-11): the importer, API and jobs have no classic write
-- or read paths left (their "lean" config objects are gone). The tables only those paths used were
-- emptied when each host switched (the plain names became views over event, basic_tags,
-- event_replies and pubkey_stats), and are dropped here:
--   - copies of event columns: event_created_at, pubkey_ids, hashtags (and their plain-name views);
--   - the pointer tables: meta_data, contact_lists, mute_list, mute_list_2, mute_lists, allow_list,
--     bookmarks, relay_list_metadata, replaceable_events, parametrized_replaceable_events,
--     parameterized_replaceable_list, reads_versions (their plain-name views stay);
--   - event_pubkey_actions(_refs), event_thread_parents, note_length, pubkey_ln_address, the per-pubkey
--     counters (followers, zapped, media, content zaps: pubkey_stats), og_zap_receipts (zap_receipts);
--   - event_relay (frozen since the OCaml cutover), the cmr_* tables the _2 tables replaced,
--     scheduled_hooks (only the hashtag score expiry used it), lean_event_stats_dups (a leftover).
-- A cache DB that predates the lean schema cannot be converted by a migration (its rows would have to
-- be rebuilt): this file refuses to run there. Create a new cache DB from schema/cache.sql instead
-- (schema/README.md); the importer fills it again.
-- Idempotent (if exists); each drop takes its table's lock briefly (nothing uses them).

do $$
begin
  if to_regclass('public.event') is not null and to_regclass('public.pubkey_stats') is null then
    raise exception 'this cache DB predates the lean schema (no pubkey_stats table): create a new one from schema/cache.sql (schema/README.md)';
  end if;
end $$;

-- the plain-name views over the emptied copies
drop view if exists public.hashtags, public.pubkey_ids, public.event_created_at;

drop table if exists
  public.event_created_at_1_7a51e16c5c,
  public.pubkey_ids_1_54b55dd09c,
  public.hashtags_1_1e5c72161a,
  public.event_relay,
  public.cmr_pubkeys_parent,
  public.cmr_words,
  public.cmr_hashtags,
  public.event_pubkey_actions_1_d62afee35d,
  public.event_pubkey_action_refs_1_f32e1ff589,
  public.meta_data_1_323bc43167,
  public.contact_lists_1_1abdf474bd,
  public.mute_list_1_f693a878b9,
  public.mute_list_2_1_949b3d746b,
  public.mute_lists_1_d90e559628,
  public.allow_list_1_f1da08e9c8,
  public.bookmarks_1_43f5248b56,
  public.relay_list_metadata_1_801a17fc93,
  public.parametrized_replaceable_events_1_cbe75c8d53,
  public.parameterized_replaceable_list_1_d02d7ecc62,
  public.reads_versions_12_b537d4df66,
  public.replaceable_events,
  public.event_thread_parents_1_e17bf16c98,
  public.pubkey_followers_cnt_1_a6f7e200e7,
  public.pubkey_zapped_1_17f1f622a9,
  public.pubkey_media_cnt_1_b5e2a488b1,
  public.pubkey_content_zap_cnt_1_236df2f369,
  public.note_length_1_15d66ffae6,
  public.pubkey_ln_address_1_d3649b2898,
  public.og_zap_receipts_1_dc85307383,
  public.scheduled_hooks,
  public.lean_event_stats_dups;
