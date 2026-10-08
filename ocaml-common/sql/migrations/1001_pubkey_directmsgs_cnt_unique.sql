-- pubkey_directmsgs_cnt: one row per (receiver, sender), NULL sender = the receiver's total.
-- The importer's former select-then-insert upkeep raced between worker domains and left duplicate
-- rows (7,490 on the stage host by 2026-10-06); their multi-row updates deadlocked and stalled every worker
-- on one hot receiver during a backfill. Merge duplicates (sum of counts, newest latest_at and its
-- event id), then the unique index the importer's upsert (ON CONFLICT (receiver, sender)) infers.
-- Idempotent: nothing to merge and the index already present are both no-ops.
-- Rows are addressed by ctid: the table's rowid column is NOT unique on every host (the media host had
-- millions of rows sharing a rowid; a rowid-keyed delete there removed 3.65 M rows on 2026-10-08).
do $$
begin
  if not exists (select 1 from pg_indexes where indexname = 'pubkey_directmsgs_cnt_1_efdf9742a6_receiver_sender_uniq') then
    create temp table dm_merged as
      select receiver, sender, sum(cnt) as cnt, max(latest_at) as latest_at,
             (array_agg(latest_event_id order by latest_at desc nulls last))[1] as latest_event_id,
             array_agg(ctid) as ctids
      from pubkey_directmsgs_cnt_1_efdf9742a6
      group by 1, 2 having count(*) > 1;
    delete from pubkey_directmsgs_cnt_1_efdf9742a6 t using dm_merged m where t.ctid = any (m.ctids);
    insert into pubkey_directmsgs_cnt_1_efdf9742a6 (receiver, sender, cnt, latest_at, latest_event_id)
      select receiver, sender, cnt, latest_at, latest_event_id from dm_merged;
    create unique index pubkey_directmsgs_cnt_1_efdf9742a6_receiver_sender_uniq
      on pubkey_directmsgs_cnt_1_efdf9742a6 (receiver, sender) nulls not distinct;
  end if;
end $$;
