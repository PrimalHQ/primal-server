-- get_media_url and count_jsonb_keys were created without a volatility, so they are VOLATILE.
-- A volatile set-returning SQL function is never inlined: event_media_response (run for every
-- kind 0/1/6 event that enrich_feed_events and user_infos return) called get_media_url once per
-- media URL through the SQL-function executor, which plans its four-way join anew on every call
-- (1.9 ms planning for 2.2 ms of execution). STABLE lets the planner inline it into
-- event_media_response's cached plan: user_infos over a 1676-follow contact list went from 0.97 s
-- to 0.45 s of media lookups on the stage host, same rows. get_media_url only reads; count_jsonb_keys
-- depends on its argument alone. Idempotent.
alter function get_media_url(character varying) stable;
alter function count_jsonb_keys(jsonb) immutable;
