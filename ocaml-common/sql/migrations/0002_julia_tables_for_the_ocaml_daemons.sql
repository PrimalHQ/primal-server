-- lock_timeout: 30s
-- Tables and columns the OCaml daemons use that Julia created on the stage host only (DDL dumped from
-- it on 2026-10-08, the day the media host got them by hand): follow_lists, refs, zap_receipt_invoices,
-- live_event_pubkey_filterlist, live_event_notification_created, edges, muted_threads,
-- notification_types (+ its 16 reference rows), event_relays, the id_seq sequence behind the id
-- columns, and type501/type601 on pubkey_notification_cnts_1_d78f6fcade (LIVE_EVENT_HAPPENING /
-- REPLY_TO_REPLY counters) with the pubkey_notification_cnts view recreated over them. Idempotent.
create sequence if not exists public.id_seq;

create table if not exists public.edges (
    id bigint DEFAULT nextval('public.id_seq'::regclass) NOT NULL,
    input_id bigint NOT NULL,
    output_id bigint NOT NULL,
    etype bigint,
    extra jsonb
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'edges_pkey') then
    alter table only public.edges add constraint edges_pkey PRIMARY KEY (id);
  end if;
end $$;
create table if not exists public.event_relays (
    event_id bytea NOT NULL,
    relay_url character varying NOT NULL,
    imported_at bigint NOT NULL
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'event_relays_pkey') then
    alter table only public.event_relays add constraint event_relays_pkey PRIMARY KEY (event_id, relay_url);
  end if;
end $$;
create index if not exists event_relays_event_id_idx on public.event_relays USING btree (event_id);
create index if not exists event_relays_imported_at_idx on public.event_relays USING btree (imported_at);
create table if not exists public.follow_lists (
    id bigint DEFAULT nextval('public.id_seq'::regclass) NOT NULL,
    pubkey bytea NOT NULL,
    identifier character varying NOT NULL,
    follow_pubkey bytea NOT NULL
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'follow_lists_pkey') then
    alter table only public.follow_lists add constraint follow_lists_pkey PRIMARY KEY (pubkey, identifier, follow_pubkey);
  end if;
end $$;
create index if not exists follow_lists_pubkey_identifier_idx on public.follow_lists USING btree (pubkey, identifier);
create table if not exists public.live_event_notification_created (
    kind bigint NOT NULL,
    pubkey bytea NOT NULL,
    identifier character varying NOT NULL,
    follower_pubkey bytea NOT NULL,
    created_at bigint NOT NULL
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'live_event_notification_created_pkey') then
    alter table only public.live_event_notification_created add constraint live_event_notification_created_pkey PRIMARY KEY (kind, pubkey, identifier, follower_pubkey);
  end if;
end $$;
create table if not exists public.live_event_pubkey_filterlist (
    user_pubkey bytea NOT NULL,
    blocked_pubkey bytea NOT NULL,
    event_id bytea NOT NULL,
    created_at bigint NOT NULL
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'live_event_pubkey_filterlist_pkey') then
    alter table only public.live_event_pubkey_filterlist add constraint live_event_pubkey_filterlist_pkey PRIMARY KEY (user_pubkey, blocked_pubkey);
  end if;
end $$;
create table if not exists public.muted_threads (
    pubkey bytea NOT NULL,
    root_eid bytea NOT NULL,
    muted_at timestamp without time zone NOT NULL
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'muted_threads_pkey') then
    alter table only public.muted_threads add constraint muted_threads_pkey PRIMARY KEY (pubkey, root_eid);
  end if;
end $$;
create table if not exists public.notification_types (
    type integer NOT NULL,
    name character varying NOT NULL
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'notification_types_pk') then
    alter table only public.notification_types add constraint notification_types_pk PRIMARY KEY (type);
  end if;
end $$;
create table if not exists public.refs (
    id bigint DEFAULT nextval('public.id_seq'::regclass) NOT NULL,
    ref jsonb NOT NULL,
    extra jsonb
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'refs_pkey') then
    alter table only public.refs add constraint refs_pkey PRIMARY KEY (ref);
  end if;
end $$;
create table if not exists public.zap_receipt_invoices (
    zap_receipt_eid bytea NOT NULL,
    invoice character varying NOT NULL
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'zap_receipt_invoices_pkey') then
    alter table only public.zap_receipt_invoices add constraint zap_receipt_invoices_pkey PRIMARY KEY (zap_receipt_eid, invoice);
  end if;
end $$;
create index if not exists zap_receipt_invoices_invoice_idx on public.zap_receipt_invoices USING btree (invoice);
alter table public.pubkey_notification_cnts_1_d78f6fcade
  add column if not exists type501 integer not null default 0,
  add column if not exists type601 integer not null default 0;
create or replace view public.pubkey_notification_cnts as
  select pubkey, type1, type2, type3, type4, type5, type6, type7, type8, type101, type102, type103, type104,
         type201, type202, type203, type204, rowid, type301, type302, type303, type401, type501, type601
  from public.pubkey_notification_cnts_1_d78f6fcade;

insert into public.notification_types (type, name) values
  (1, 'NEW_USER_FOLLOWED_YOU'),
  (2, 'USER_UNFOLLOWED_YOU'),
  (3, 'YOUR_POST_WAS_ZAPPED'),
  (4, 'YOUR_POST_WAS_LIKED'),
  (5, 'YOUR_POST_WAS_REPOSTED'),
  (6, 'YOUR_POST_WAS_REPLIED_TO'),
  (7, 'YOU_WERE_MENTIONED_IN_POST'),
  (8, 'YOUR_POST_WAS_MENTIONED_IN_POST'),
  (101, 'POST_YOU_WERE_MENTIONED_IN_WAS_ZAPPED'),
  (102, 'POST_YOU_WERE_MENTIONED_IN_WAS_LIKED'),
  (103, 'POST_YOU_WERE_MENTIONED_IN_WAS_REPOSTED'),
  (104, 'POST_YOU_WERE_MENTIONED_IN_WAS_REPLIED_TO'),
  (201, 'POST_YOUR_POST_WAS_MENTIONED_IN_WAS_ZAPPED'),
  (202, 'POST_YOUR_POST_WAS_MENTIONED_IN_WAS_LIKED'),
  (203, 'POST_YOUR_POST_WAS_MENTIONED_IN_WAS_REPOSTED'),
  (204, 'POST_YOUR_POST_WAS_MENTIONED_IN_WAS_REPLIED_TO')
on conflict (type) do nothing;
