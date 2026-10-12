-- reads: partial covering index for the reads feed (nostr-reads-feed: advanced search
-- `kind:30023 scope:myfollowsinteractions minwords:100 features:summary`, ocaml-api advsearch.ml).
-- The feed walks reads by published_at desc and tests each read's scope; only the reads with
-- words >= 100, a summary and an image qualify (55 % of the table), and the scope test needs only
-- latest_eid and pubkey, so this index answers the walk without heap visits. With the scope tested
-- on the reads columns (advsearch.ml), a reads-feed request on the stage host went from 1.6-9 s to
-- 0.3-0.9 s. 35 MB on the stage host (623 k reads), built concurrently in under a second; none of
-- the columns the importer updates often (likes, zaps, ...) are in it, so their updates stay HOT.
-- A build that failed half-way leaves an invalid index, which `if not exists` would keep: drop it
-- first. Idempotent.
select exists (select 1 from pg_class c join pg_index i on i.indexrelid = c.oid
               where c.relname = 'reads_12_68c6bbfccd_feed_published_at_idx' and not i.indisvalid) as invalid_leftover
\gset
\if :invalid_leftover
drop index concurrently reads_12_68c6bbfccd_feed_published_at_idx;
\endif
create index concurrently if not exists reads_12_68c6bbfccd_feed_published_at_idx
  on reads_12_68c6bbfccd (published_at) include (latest_eid, pubkey)
  where words >= 100 and summary <> '' and image <> '';
