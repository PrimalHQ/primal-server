create schema if not exists cache;

create sequence if not exists cache.id_seq as int8;

-- select nextval('cache.id_seq');

create table if not exists cache.refs (
    id int8 not null default nextval('cache.id_seq'),
    created_at timestamp not null default now(),
    ref jsonb not null, -- {"table": "note_stats", "key": {"eid": "...", ...}}
    extra jsonb,
    primary key (ref)
);

create table if not exists cache.id_table (
    id int8 not null,
    table_name varchar not null,
    extra jsonb,
    created_at timestamp not null default now(),
    primary key (id)
);

create table if not exists cache.edges (
    id int8 not null default nextval('cache.id_seq'),
    created_at timestamp not null default now(),
    input_id int8 not null,
    output_id int8 not null,
    etype int8,
    extra jsonb,
    primary key (id)
);

create table if not exists cache.edgetypes (
    id int8 not null default nextval('cache.id_seq'),
    created_at timestamp not null default now(),
    name varchar not null,
    extra jsonb,
    primary key (name)
);

------------------------------------------------

create table if not exists cache.follow_lists (
    id int8 not null default nextval('cache.id_seq'),
    pubkey bytea not null,
    identifier varchar not null,
    follow_pubkey bytea not null,
    primary key (pubkey, identifier, follow_pubkey)
);

create index if not exists follow_lists_pubkey_identifier_idx on cache.follow_lists (pubkey, identifier);

