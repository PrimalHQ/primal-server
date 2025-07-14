create table if not exists vars (
    key varchar not null,
    value jsonb not null,
    updated_at timestamp not null,

    primary key (key)
);
-- insert into vars values ('import_latest_created_at', '0', now()) on conflict do nothing;

-------------------------------------

create sequence if not exists id_seq as int8;

create table if not exists refs (
    id int8 not null default nextval('id_seq'),
    -- created_at timestamp not null default now(),
    ref jsonb not null, -- {"table": "note_stats", "key": {"eid": "...", ...}}
    extra jsonb,
    primary key (ref)
);

create table if not exists id_table (
    id int8 not null,
    table_name varchar not null,
    extra jsonb,
    -- created_at timestamp not null default now(),
    primary key (id)
);

create table if not exists edges (
    id int8 not null default nextval('id_seq'),
    -- created_at timestamp not null default now(),
    input_id int8 not null,
    output_id int8 not null,
    etype int8,
    extra jsonb,
    primary key (id)
);

create table if not exists edgetypes (
    id int8 not null default nextval('id_seq'),
    -- created_at timestamp not null default now(),
    name varchar not null,
    extra jsonb,
    primary key (name)
);

------------------------------------------------

create table if not exists follow_lists (
    id int8 not null default nextval('id_seq'),
    pubkey bytea not null,
    identifier varchar not null,
    follow_pubkey bytea not null,
    primary key (pubkey, identifier, follow_pubkey)
);

create index if not exists follow_lists_pubkey_identifier_idx on follow_lists (pubkey, identifier);

