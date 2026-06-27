-- Importer base-table schema, translated from the Julia init_queries
-- (primal-server/src/psql2.jl mkevents, src/cache_storage.jl CacheStorage struct, and the
-- ext/dyn tables). In Julia the `!`-prefixed DDL is post-processed blob->bytea, int->int8.
--
-- This file serves two purposes:
--   1. it defines the local reference DB used by the PGOCaml [%pgsql] ppx for compile-time
--      schema checking (sql/refdb-setup.sh), and
--   2. the importer ensures these tables exist at startup (mirroring Julia's
--      "create table if not exists").
--
-- Secondary indexes are omitted here (irrelevant to type-checking / correctness); primary
-- keys are kept because several queries use ON CONFLICT against them.

-- events (psql2.jl mkevents)
create table if not exists events (
  id          bytea primary key not null,
  pubkey      bytea not null,
  created_at  int8  not null,
  kind        int8  not null,
  tags        jsonb not null,
  content     text  not null,
  sig         bytea not null,
  imported_at int8  not null
);

create table if not exists event_created_at (
  event_id   bytea not null primary key,
  created_at int8  not null
);

-- pubkey_events: append-only index (no primary key)
create table if not exists pubkey_events (
  pubkey     bytea not null,
  event_id   bytea not null,
  created_at int8  not null,
  is_reply   int8  not null
);

-- DBSet(PubKeyId) -> (key bytea pk, value boolean). Value columns are declared NOT NULL
-- here (they are always set) so [%pgsql] infers clean non-option OCaml types.
create table if not exists pubkey_ids (
  key   bytea primary key not null,
  value boolean not null
);

create table if not exists pubkey_followers (
  pubkey                         bytea not null,
  follower_pubkey                bytea not null,
  follower_contact_list_event_id bytea not null
);

-- DBDict(PubKeyId, Int)
create table if not exists pubkey_followers_cnt (
  key   bytea primary key not null,
  value int8 not null
);

-- DBDict(_, EventId/PubKeyId) -> (key bytea pk, value bytea)
create table if not exists contact_lists        (key bytea primary key not null, value bytea not null);
create table if not exists meta_data            (key bytea primary key not null, value bytea not null);
create table if not exists event_thread_parents (key bytea primary key not null, value bytea not null);
create table if not exists mute_list            (key bytea primary key not null, value bytea not null);
create table if not exists mute_list_2          (key bytea primary key not null, value bytea not null);
create table if not exists mute_lists           (key bytea primary key not null, value bytea not null);
create table if not exists allow_list           (key bytea primary key not null, value bytea not null);

create table if not exists deleted_events (
  event_id          bytea primary key not null,
  deletion_event_id bytea not null
);

create table if not exists event_stats (
  event_id      bytea not null primary key,
  author_pubkey bytea not null,
  created_at    int8  not null,
  likes         int8  not null,
  replies       int8  not null,
  mentions      int8  not null,
  reposts       int8  not null,
  zaps          int8  not null,
  satszapped    int8  not null,
  score         int8  not null,
  score24h      int8  not null
);

create table if not exists event_replies (
  event_id         bytea not null,
  reply_event_id   bytea not null,
  reply_created_at int8  not null
);

create table if not exists event_hooks (
  event_id bytea not null,
  funcall  text  not null
);

create table if not exists scheduled_hooks (
  execute_at int8 not null,
  funcall    text not null
);

create table if not exists event_pubkey_actions (
  event_id   bytea not null,
  pubkey     bytea not null,
  created_at int8  not null,
  updated_at int8  not null,
  replied    int8  not null,
  liked      int8  not null,
  reposted   int8  not null,
  zapped     int8  not null,
  primary key (event_id, pubkey)
);

create table if not exists event_pubkey_action_refs (
  event_id       bytea not null,
  ref_event_id   bytea not null,
  ref_pubkey     bytea not null,
  ref_created_at int8  not null,
  ref_kind       int8  not null
);

create table if not exists parameterized_replaceable_list (
  pubkey     bytea not null,
  identifier text  not null,
  created_at int8  not null,
  event_id   bytea not null
);

create table if not exists pubkey_directmsgs (
  receiver   bytea not null,
  sender     bytea not null,
  created_at int8  not null,
  event_id   bytea not null
);

create table if not exists pubkey_directmsgs_cnt (
  receiver        bytea not null,
  sender          bytea,
  cnt             int8  not null,
  latest_at       int8  not null,
  latest_event_id bytea not null
);

-- og_zap_receipts: sender/receiver/event_id are nullable in Julia
create table if not exists og_zap_receipts (
  zap_receipt_id bytea not null,
  created_at     int8  not null,
  sender         bytea,
  receiver       bytea,
  amount_sats    int8  not null,
  event_id       bytea
);

create table if not exists pubkey_zapped (
  pubkey     bytea not null primary key,
  zaps       int8  not null,
  satszapped int8  not null
);

create table if not exists score_expiry (
  event_id      bytea not null,
  author_pubkey bytea not null,
  change        int8  not null,
  expire_at     int8  not null
);

create table if not exists relays (
  url              text not null primary key,
  times_referenced int8 not null
);

create table if not exists pubkey_notifications (
  pubkey     bytea not null,
  created_at int8  not null,
  type       int8  not null,
  arg1       bytea not null,
  arg2       bytea,
  arg3       text,
  arg4       text
);

-- ext / dyn tables (definitions from the live base tables in primal1)
create table if not exists event_relays (
  event_id    bytea   not null,
  relay_url   varchar not null,
  imported_at int8    not null,
  primary key (event_id, relay_url)
);

create table if not exists replaceable_events (
  pubkey   bytea not null,
  kind     int8  not null,
  event_id bytea not null,
  primary key (pubkey, kind)
);

create table if not exists parametrized_replaceable_events (
  pubkey     bytea   not null,
  kind       int8    not null,
  identifier varchar not null,
  event_id   bytea   not null,
  created_at int8    not null
);

create table if not exists spam_note_content_hash (
  content_sha256 bytea not null primary key,
  added_at       int8  not null
);

-- ext_text_note hashtag indexing (cache_storage.jl event_hashtags / hashtags)
create table if not exists event_hashtags (
  event_id   bytea not null,
  hashtag    text  not null,
  created_at int8  not null
);

create table if not exists hashtags (
  hashtag text not null primary key,
  score   int8 not null
);

-- update_pubkey_ln_address (cache_storage.jl pubkey_ln_address dyn table)
create table if not exists pubkey_ln_address (
  pubkey     bytea not null primary key,
  ln_address text  not null
);

-- pubkey_trustrank is populated by the separate Julia TrustRankMaker; the importer only
-- reads it (is_trusted_user). Columns per cache_storage_ext.jl: pubkey + rank.
create table if not exists pubkey_trustrank (
  pubkey bytea  not null primary key,
  rank   float8 not null
);

-- filterlist lives in the membership DB at runtime, but is loaded here so [%pgsql] can
-- type-check the spam-marking query against it.
do $$ begin
  if not exists (select 1 from pg_type where typname = 'filterlist_target') then
    create type filterlist_target as enum ('pubkey', 'event');
  end if;
  if not exists (select 1 from pg_type where typname = 'filterlist_grp') then
    create type filterlist_grp as enum
      ('spam', 'nsfw', 'csam', 'impersonation', 'in_app_purchase', 'trending');
  end if;
end $$;

create table if not exists filterlist (
  target      bytea             not null,
  target_type filterlist_target not null,
  blocked     bool              not null,
  grp         filterlist_grp    not null,
  added_at    int8,
  comment     varchar,
  primary key (target, target_type, blocked, grp)
);

-- human_override lives in the membership DB at runtime; ext_is_human reads is_human.
create table if not exists human_override (
  pubkey     bytea not null primary key,
  is_human   bool  not null,
  updated_at timestamp not null default now(),
  source     text
);
