-- SQL functions of the retired Julia API that nothing calls any more (the OCaml API answers these
-- verbs itself) and that read tables migration 1003 drops: enrich_feed_events_ (event_relay),
-- user_profile, user_profile_followed_by and user_blossom_relays (replaceable_events). Every
-- overload. Idempotent.
do $$
declare f regprocedure;
begin
  for f in
    select p.oid::regprocedure from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('enrich_feed_events_', 'user_profile', 'user_profile_followed_by', 'user_blossom_relays')
  loop
    execute 'drop function ' || f::text;
  end loop;
end $$;
