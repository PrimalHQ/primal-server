-- parametrized_replaceable_events: the importer deletes the previous version of a kind-3xxxx event
-- by (pubkey, kind, identifier) on every replacement (cache_storage.ml store_parametrized_replaceable_event).
-- Julia created single-column indexes only, so each delete bitmap-ands pubkey and identifier over a
-- 27 M-row table: six postgres backends at 80 % CPU and a backfill crawling at ~150 events/s on the
-- stage host (2026-10-08). Applied there concurrently in 56 s (2.9 GB). Idempotent.
create index concurrently if not exists parametrized_replaceable_events_1_cbe75c8d53_pubkey_kind_identi
  on parametrized_replaceable_events_1_cbe75c8d53 (pubkey, kind, identifier);
