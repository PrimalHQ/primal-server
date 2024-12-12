


DROP INDEX public.verified_users_pubkey;
DROP INDEX public.verified_users_name;
DROP INDEX public.short_urls_url;
DROP INDEX public.short_urls_path;
DROP INDEX public.short_urls_idx;
DROP INDEX public.reserved_names_name;
DROP INDEX public.reported_pubkey;
DROP INDEX public.reported_created_at;
DROP INDEX public.pubkey_registered_key;
DROP INDEX public.pubkey_notifications_seen_seen_until_idx;
DROP INDEX public.pubkey_notifications_seen_seen_until;
DROP INDEX public.pubkey_notifications_seen_pubkey;
DROP INDEX public.notification_settings_pubkey_idx;
DROP INDEX public.notification_settings_pubkey;
DROP INDEX public.memberships_pubkey;
DROP INDEX public.membership_tiers_tier;
DROP INDEX public.membership_products_product_id;
DROP INDEX public.media_uploads_sha256_idx;
DROP INDEX public.media_uploads_sha256;
DROP INDEX public.media_uploads_pubkey_idx;
DROP INDEX public.media_uploads_pubkey;
DROP INDEX public.media_uploads_path_idx;
DROP INDEX public.media_uploads_path;
DROP INDEX public.media_uploads_created_at_idx;
DROP INDEX public.media_uploads_created_at;
DROP INDEX public.lists_pubkey;
DROP INDEX public.lists_list;
DROP INDEX public.lists_added_at;
DROP INDEX public.inappropriate_names_name;
DROP INDEX public.human_override_pubkey;
DROP INDEX public.categorized_uploads_sha256;
DROP INDEX public.categorized_uploads_added_at;
DROP INDEX public.app_settings_log_pubkey_idx;
DROP INDEX public.app_settings_log_pubkey;
DROP INDEX public.app_settings_log_accessed_at_idx;
DROP INDEX public.app_settings_log_accessed_at;
DROP INDEX public.app_settings_key;
DROP INDEX public.app_settings_event_id_key;
DROP INDEX public.app_settings_event_id_created_at_idx;
DROP INDEX public.app_settings_event_id_created_at;
DROP INDEX public.app_settings_event_id_accessed_at_idx;
DROP INDEX public.app_settings_event_id_accessed_at;
DROP INDEX public.app_settings_accessed_at_idx;
DROP INDEX public.app_settings_accessed_at;
DROP INDEX public.advsearch_log_user_pubkey_t_idx;
DROP INDEX public.advsearch_log_t_idx;
ALTER TABLE ONLY public.vars DROP CONSTRAINT vars_pk;
ALTER TABLE ONLY public.user_last_online_time DROP CONSTRAINT user_last_online_time_pkey;
ALTER TABLE ONLY public.reported DROP CONSTRAINT reported_pkey;
ALTER TABLE ONLY public.pubkey_registered DROP CONSTRAINT pubkey_registered_pkey;
ALTER TABLE ONLY public.pubkey_notifications_seen DROP CONSTRAINT pubkey_notifications_seen_pkey;
ALTER TABLE ONLY public.memberships DROP CONSTRAINT memberships_pk;
ALTER TABLE ONLY public.membership_legend_customization DROP CONSTRAINT membership_legend_customization_pk;
ALTER TABLE ONLY public.inappropriate_names DROP CONSTRAINT inappropriate_names_pkey1;
ALTER TABLE ONLY public.reserved_names DROP CONSTRAINT inappropriate_names_pkey;
ALTER TABLE ONLY public.human_override DROP CONSTRAINT human_override_pkey;
ALTER TABLE ONLY public.filterlist DROP CONSTRAINT filterlist_pkey;
ALTER TABLE ONLY public.dvm_usage DROP CONSTRAINT dvm_usage_pkey;
ALTER TABLE ONLY public.app_subsettings DROP CONSTRAINT app_subsettings_pkey;
ALTER TABLE ONLY public.app_settings DROP CONSTRAINT app_settings_pkey;
ALTER TABLE ONLY public.app_settings_event_id DROP CONSTRAINT app_settings_event_id_pkey;
DROP TABLE public.verified_users;
DROP TABLE public.vars;
DROP TABLE public.user_last_online_time;
DROP TABLE public.short_urls;
DROP TABLE public.reserved_names;
DROP TABLE public.reported;
DROP TABLE public.purged_images;
DROP TABLE public.pubkey_registered;
DROP TABLE public.pubkey_notifications_seen;
DROP TABLE public.notification_settings;
DROP TABLE public.memberships;
DROP TABLE public.membership_tiers;
DROP TABLE public.membership_products;
DROP TABLE public.membership_legend_customization;
DROP TABLE public.media_uploads;
DROP TABLE public.lists;
DROP TABLE public.inappropriate_names;
DROP TABLE public.human_override;
DROP TABLE public.filterlist;
DROP TABLE public.event_rebroadcasting;
DROP TABLE public.dvm_usage;
DROP TABLE public.categorized_uploads;
DROP TABLE public.app_subsettings;
DROP TABLE public.app_settings_log;
DROP TABLE public.app_settings_event_id;
DROP TABLE public.app_settings;
DROP TABLE public.advsearch_log;
DROP FUNCTION public.membership_media_management_stats(a_pubkey bytea);
DROP FUNCTION public.c_membership_media_management();
DROP TYPE public.filterlist_target;
DROP TYPE public.filterlist_grp;
DROP SCHEMA public;

CREATE SCHEMA public;



COMMENT ON SCHEMA public IS 'standard public schema';



CREATE TYPE public.filterlist_grp AS ENUM (
    'spam',
    'nsfw',
    'csam'
);



CREATE TYPE public.filterlist_target AS ENUM (
    'pubkey',
    'event'
);



CREATE FUNCTION public.c_membership_media_management() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000163$$;



CREATE FUNCTION public.membership_media_management_stats(a_pubkey bytea) RETURNS TABLE(upload_type text, cnt bigint, size bigint)
    LANGUAGE sql
    AS $$
select
	upload_type,
	count(1) as cnt,
	sum(size) as size
from (
	select
		(case
			when upload_type in ('video', 'image') then upload_type
			else 'other'
		end) as upload_type,
		size
	from (
		select split_part(mimetype, '/', 1) as upload_type, size
		from media_uploads mu
		where mu.pubkey = a_pubkey
	) a) b
group by upload_type
order by size desc;

$$;





CREATE TABLE public.advsearch_log (
    t timestamp without time zone NOT NULL,
    user_pubkey bytea NOT NULL,
    d jsonb NOT NULL
);



CREATE TABLE public.app_settings (
    key bytea NOT NULL,
    value text,
    accessed_at bigint DEFAULT 0,
    created_at bigint,
    event_id bytea
);



CREATE TABLE public.app_settings_event_id (
    key bytea NOT NULL,
    value bytea,
    created_at bigint,
    accessed_at bigint
);



CREATE TABLE public.app_settings_log (
    pubkey bytea NOT NULL,
    event json NOT NULL,
    accessed_at bigint NOT NULL
);



CREATE TABLE public.app_subsettings (
    pubkey bytea NOT NULL,
    subkey character varying NOT NULL,
    updated_at bigint NOT NULL,
    settings jsonb NOT NULL
);



CREATE TABLE public.categorized_uploads (
    type character varying NOT NULL,
    added_at integer NOT NULL,
    sha256 bytea,
    url character varying,
    pubkey bytea,
    event_id bytea,
    extra json
);



CREATE TABLE public.dvm_usage (
    job_request_id bytea NOT NULL,
    created_at bigint NOT NULL,
    pubkey bytea NOT NULL,
    feed_id character varying NOT NULL
);



CREATE TABLE public.event_rebroadcasting (
    pubkey bytea NOT NULL,
    started_at timestamp without time zone,
    finished_at timestamp without time zone,
    event_created_at bigint,
    event_idx bigint,
    event_count bigint,
    target_relays jsonb,
    status character varying,
    kinds jsonb,
    exception character varying,
    failed_batches bigint,
    batchhash bytea,
    last_batch_status character varying,
    event_idx_intermediate bigint
);



CREATE TABLE public.filterlist (
    target bytea NOT NULL,
    target_type public.filterlist_target NOT NULL,
    blocked boolean NOT NULL,
    grp public.filterlist_grp NOT NULL,
    added_at bigint,
    comment character varying
);



CREATE TABLE public.human_override (
    pubkey bytea NOT NULL,
    is_human boolean,
    added_at timestamp without time zone DEFAULT now(),
    source character varying
);



CREATE TABLE public.inappropriate_names (
    name character varying(200) NOT NULL
);



CREATE TABLE public.lists (
    list character varying(200) NOT NULL,
    pubkey bytea NOT NULL,
    added_at integer NOT NULL
);



CREATE TABLE public.media_uploads (
    pubkey bytea NOT NULL,
    type character varying(50) NOT NULL,
    key jsonb NOT NULL,
    created_at bigint NOT NULL,
    path text NOT NULL,
    size bigint NOT NULL,
    mimetype character varying(200) NOT NULL,
    category character varying(100) NOT NULL,
    category_confidence real NOT NULL,
    width bigint NOT NULL,
    height bigint NOT NULL,
    duration real NOT NULL,
    sha256 bytea,
    moderation_category character varying
);



CREATE TABLE public.membership_legend_customization (
    pubkey bytea NOT NULL,
    style character varying NOT NULL,
    custom_badge boolean NOT NULL,
    avatar_glow boolean NOT NULL
);



CREATE TABLE public.membership_products (
    product_id character varying(100) NOT NULL,
    tier character varying(300) NOT NULL,
    months integer NOT NULL,
    label character varying NOT NULL,
    android_product_id character varying,
    ios_product_id character varying,
    web_product_id character varying,
    short_product_id character varying
);



CREATE TABLE public.membership_tiers (
    tier character varying(300) NOT NULL,
    max_storage bigint
);



CREATE TABLE public.memberships (
    pubkey bytea NOT NULL,
    tier character varying(300),
    valid_until timestamp without time zone,
    name character varying(500),
    used_storage bigint,
    cohort_1 character varying,
    cohort_2 character varying,
    recurring boolean,
    created_at timestamp without time zone,
    platform_id character varying,
    class_id character varying,
    origin character varying
);

ALTER TABLE ONLY public.memberships REPLICA IDENTITY FULL;



CREATE TABLE public.notification_settings (
    pubkey bytea NOT NULL,
    type character varying(100) NOT NULL,
    enabled boolean NOT NULL
);



CREATE TABLE public.pubkey_notifications_seen (
    pubkey bytea NOT NULL,
    seen_until bigint
);



CREATE TABLE public.pubkey_registered (
    key bytea NOT NULL,
    value bigint
);



CREATE TABLE public.purged_images (
    url character varying NOT NULL,
    key jsonb,
    page_url character varying,
    purged_at timestamp without time zone NOT NULL,
    purged_by bytea NOT NULL,
    comment character varying,
    status boolean NOT NULL
);



CREATE TABLE public.reported (
    pubkey bytea NOT NULL,
    type bigint NOT NULL,
    id bytea NOT NULL,
    created_at bigint NOT NULL
);



CREATE TABLE public.reserved_names (
    name character varying(200) NOT NULL
);



CREATE TABLE public.short_urls (
    idx bigint NOT NULL,
    url text NOT NULL,
    path text NOT NULL,
    ext text NOT NULL
);



CREATE TABLE public.user_last_online_time (
    pubkey bytea NOT NULL,
    online_at bigint NOT NULL
);



CREATE TABLE public.vars (
    name character varying NOT NULL,
    value jsonb
);



CREATE TABLE public.verified_users (
    name character varying(200) NOT NULL,
    pubkey bytea NOT NULL,
    default_name boolean NOT NULL,
    added_at timestamp without time zone
);

ALTER TABLE ONLY public.verified_users REPLICA IDENTITY FULL;



ALTER TABLE ONLY public.app_settings_event_id
    ADD CONSTRAINT app_settings_event_id_pkey PRIMARY KEY (key);



ALTER TABLE ONLY public.app_settings
    ADD CONSTRAINT app_settings_pkey PRIMARY KEY (key);



ALTER TABLE ONLY public.app_subsettings
    ADD CONSTRAINT app_subsettings_pkey PRIMARY KEY (pubkey, subkey);



ALTER TABLE ONLY public.dvm_usage
    ADD CONSTRAINT dvm_usage_pkey PRIMARY KEY (job_request_id);



ALTER TABLE ONLY public.filterlist
    ADD CONSTRAINT filterlist_pkey PRIMARY KEY (target, target_type, blocked, grp);



ALTER TABLE ONLY public.human_override
    ADD CONSTRAINT human_override_pkey PRIMARY KEY (pubkey);



ALTER TABLE ONLY public.reserved_names
    ADD CONSTRAINT inappropriate_names_pkey PRIMARY KEY (name);



ALTER TABLE ONLY public.inappropriate_names
    ADD CONSTRAINT inappropriate_names_pkey1 PRIMARY KEY (name);



ALTER TABLE ONLY public.membership_legend_customization
    ADD CONSTRAINT membership_legend_customization_pk PRIMARY KEY (pubkey);



ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_pk PRIMARY KEY (pubkey);



ALTER TABLE ONLY public.pubkey_notifications_seen
    ADD CONSTRAINT pubkey_notifications_seen_pkey PRIMARY KEY (pubkey);



ALTER TABLE ONLY public.pubkey_registered
    ADD CONSTRAINT pubkey_registered_pkey PRIMARY KEY (key);



ALTER TABLE ONLY public.reported
    ADD CONSTRAINT reported_pkey PRIMARY KEY (pubkey, type, id);



ALTER TABLE ONLY public.user_last_online_time
    ADD CONSTRAINT user_last_online_time_pkey PRIMARY KEY (pubkey);



ALTER TABLE ONLY public.vars
    ADD CONSTRAINT vars_pk PRIMARY KEY (name);



CREATE INDEX advsearch_log_t_idx ON public.advsearch_log USING btree (t);



CREATE INDEX advsearch_log_user_pubkey_t_idx ON public.advsearch_log USING btree (user_pubkey, t);



CREATE INDEX app_settings_accessed_at ON public.app_settings USING btree (accessed_at DESC);



CREATE INDEX app_settings_accessed_at_idx ON public.app_settings USING btree (accessed_at DESC);



CREATE INDEX app_settings_event_id_accessed_at ON public.app_settings_event_id USING btree (accessed_at DESC);



CREATE INDEX app_settings_event_id_accessed_at_idx ON public.app_settings_event_id USING btree (accessed_at DESC);



CREATE INDEX app_settings_event_id_created_at ON public.app_settings_event_id USING btree (created_at DESC);



CREATE INDEX app_settings_event_id_created_at_idx ON public.app_settings_event_id USING btree (created_at DESC);



CREATE INDEX app_settings_event_id_key ON public.app_settings_event_id USING btree (key);



CREATE INDEX app_settings_key ON public.app_settings USING btree (key);



CREATE INDEX app_settings_log_accessed_at ON public.app_settings_log USING btree (accessed_at DESC);



CREATE INDEX app_settings_log_accessed_at_idx ON public.app_settings_log USING btree (accessed_at DESC);



CREATE INDEX app_settings_log_pubkey ON public.app_settings_log USING btree (pubkey);



CREATE INDEX app_settings_log_pubkey_idx ON public.app_settings_log USING btree (pubkey);



CREATE INDEX categorized_uploads_added_at ON public.categorized_uploads USING btree (added_at DESC);



CREATE INDEX categorized_uploads_sha256 ON public.categorized_uploads USING btree (sha256);



CREATE INDEX human_override_pubkey ON public.human_override USING btree (pubkey);



CREATE INDEX inappropriate_names_name ON public.reserved_names USING btree (name);



CREATE INDEX lists_added_at ON public.lists USING btree (added_at DESC);



CREATE INDEX lists_list ON public.lists USING btree (list);



CREATE INDEX lists_pubkey ON public.lists USING btree (pubkey);



CREATE INDEX media_uploads_created_at ON public.media_uploads USING btree (created_at DESC);



CREATE INDEX media_uploads_created_at_idx ON public.media_uploads USING btree (created_at DESC);



CREATE INDEX media_uploads_path ON public.media_uploads USING btree (path);



CREATE INDEX media_uploads_path_idx ON public.media_uploads USING btree (path);



CREATE INDEX media_uploads_pubkey ON public.media_uploads USING btree (pubkey);



CREATE INDEX media_uploads_pubkey_idx ON public.media_uploads USING btree (pubkey);



CREATE INDEX media_uploads_sha256 ON public.media_uploads USING btree (sha256);



CREATE INDEX media_uploads_sha256_idx ON public.media_uploads USING btree (sha256);



CREATE INDEX membership_products_product_id ON public.membership_products USING btree (product_id);



CREATE INDEX membership_tiers_tier ON public.membership_tiers USING btree (tier);



CREATE INDEX memberships_pubkey ON public.memberships USING btree (pubkey);



CREATE INDEX notification_settings_pubkey ON public.notification_settings USING btree (pubkey);



CREATE INDEX notification_settings_pubkey_idx ON public.notification_settings USING btree (pubkey);



CREATE INDEX pubkey_notifications_seen_pubkey ON public.pubkey_notifications_seen USING btree (pubkey);



CREATE INDEX pubkey_notifications_seen_seen_until ON public.pubkey_notifications_seen USING btree (seen_until DESC);



CREATE INDEX pubkey_notifications_seen_seen_until_idx ON public.pubkey_notifications_seen USING btree (seen_until DESC);



CREATE INDEX pubkey_registered_key ON public.pubkey_registered USING btree (key);



CREATE INDEX reported_created_at ON public.reported USING btree (created_at DESC);



CREATE INDEX reported_pubkey ON public.reported USING btree (pubkey);



CREATE INDEX reserved_names_name ON public.reserved_names USING btree (name);



CREATE INDEX short_urls_idx ON public.short_urls USING btree (idx);



CREATE INDEX short_urls_path ON public.short_urls USING btree (path);



CREATE INDEX short_urls_url ON public.short_urls USING btree (url);



CREATE INDEX verified_users_name ON public.verified_users USING btree (name);



CREATE INDEX verified_users_pubkey ON public.verified_users USING btree (pubkey);



