-- reads_interactions: who reacted to, replied to or reposted (kind 1/6/7 `e` tag) which version of
-- a long-form article (an eid of reads_versions, which holds every reads.latest_eid; the article's
-- event row itself can be gone, purged while reads still points at it).
-- The reads feed (`scope:myfollowsinteractions` over kind 30023, api advsearch.ml) asked basic_tags (787 M rows) for every article whether a follow had
-- interacted with it; a viewer following few accounts walks the whole article history (~340 k)
-- and on cold pages ran into the 9 s search budget with an empty feed. Only ~0.04 % of the kind
-- 1/6/7 `e` tags point at an article, so this table is small (~100 k rows) and the feed tests
-- membership in the follows' rows of it first; the basic_tags check stays as the verifier, so a
-- stale row (deleted tag) changes nothing and only a missing row could.
-- Kept complete by the code that writes the rows (no triggers):
--   * the basic_tags inserts (importer dag_index.ml, jobs dag.ml basic_tags_node)
--     record the new kind 1/6/7 `e` tags whose target is a stored article version;
--   * the reads node (jobs dag.ml), storing an article version, picks up the tags that
--     reached it earlier.
-- Existing data: `call reads_interactions_backfill()` lists the article versions stored so far
-- and works through them in committed batches (3.5 min for 1.18 M versions on the stage host), then
-- sets reads_interactions_state.ready; the API uses the table only once ready.
-- Start it once per host after the importer and jobs run the code above, e.g.
--   systemd-run --user --unit=reads-interactions-backfill psql ... -c 'call reads_interactions_backfill()'
-- Idempotent.
create table if not exists reads_interactions (
  pubkey bytea not null,
  eid bytea not null,
  primary key (pubkey, eid)
);
create table if not exists reads_interactions_state (
  id int primary key default 1 check (id = 1),
  listed boolean not null default false, -- reads_interactions_todo holds the articles to backfill
  ready boolean not null default false   -- the backfill is done: the table is complete
);
insert into reads_interactions_state (id) values (1) on conflict do nothing;
create table if not exists reads_interactions_todo (id bytea primary key);

create or replace procedure reads_interactions_backfill(a_batch int default 2000)
  language plpgsql
as $procedure$
DECLARE
    n int;
BEGIN
    IF (SELECT ready FROM reads_interactions_state) THEN
        RETURN;
    END IF;
    -- the article versions stored so far (the code above covers everything stored after the start); a
    -- restarted backfill continues with what is left
    IF NOT (SELECT listed FROM reads_interactions_state) THEN
        INSERT INTO reads_interactions_todo (id) SELECT eid FROM reads_versions_12_b537d4df66 ON CONFLICT DO NOTHING;
        UPDATE reads_interactions_state SET listed = true;
        COMMIT;
    END IF;
    LOOP
        WITH b AS (
            DELETE FROM reads_interactions_todo
            WHERE id IN (SELECT id FROM reads_interactions_todo LIMIT a_batch)
            RETURNING id
        ), ins AS (
            INSERT INTO reads_interactions (pubkey, eid)
            SELECT DISTINCT bt.pubkey, bt.arg1 FROM b, basic_tags_6_62c3d17c2f bt
            WHERE bt.arg1 = b.id AND bt.tag = 'e' AND bt.kind IN (1, 6, 7)
            ON CONFLICT DO NOTHING
        )
        SELECT count(*) INTO n FROM b;
        COMMIT;
        EXIT WHEN n = 0;
    END LOOP;
    UPDATE reads_interactions_state SET ready = true;
    COMMIT;
END
$procedure$;
