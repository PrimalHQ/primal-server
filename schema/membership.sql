-- Baseline schema of the membership DB, 2026-10-14: pg_dump --schema-only --no-owner --no-privileges
-- --no-subscriptions --no-publications -n public, with the extensions it uses first.
-- Only the objects primal-server's code uses (plus stand-ins for two views); the rest of the
-- membership DB is not part of this repository. See README.md in this directory.

--
-- PostgreSQL database dump
--


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: filterlist_grp; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.filterlist_grp AS ENUM (
    'spam',
    'nsfw',
    'csam',
    'impersonation',
    'in_app_purchase',
    'trending'
);


--
-- Name: filterlist_target; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.filterlist_target AS ENUM (
    'pubkey',
    'event'
);


--
-- Name: membership_media_management_stats(bytea); Type: FUNCTION; Schema: public; Owner: -
--

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
		select distinct mu.sha256, split_part(mimetype, '/', 1) as upload_type, size
		from media_uploads mu
		where mu.pubkey = a_pubkey and mu.media_block_id is null
	) a) b
group by upload_type
order by size desc;

$$;


--
-- Name: app_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_settings (
    key bytea NOT NULL,
    value text,
    accessed_at bigint DEFAULT 0,
    created_at bigint,
    event_id bytea
);


--
-- Name: app_settings_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_settings_log (
    pubkey bytea NOT NULL,
    event json NOT NULL,
    accessed_at bigint NOT NULL
);


--
-- Name: app_subsettings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_subsettings (
    pubkey bytea NOT NULL,
    subkey character varying NOT NULL,
    updated_at bigint NOT NULL,
    settings jsonb NOT NULL
);


--
-- Name: dvm_usage; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dvm_usage (
    job_request_id bytea NOT NULL,
    created_at bigint NOT NULL,
    pubkey bytea NOT NULL,
    feed_id character varying NOT NULL
);


--
-- Name: event_rebroadcasting; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: filterlist; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.filterlist (
    target bytea NOT NULL,
    target_type public.filterlist_target NOT NULL,
    blocked boolean NOT NULL,
    grp public.filterlist_grp NOT NULL,
    added_at bigint,
    comment character varying
);


--
-- Name: human_override; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.human_override (
    pubkey bytea NOT NULL,
    is_human boolean,
    added_at timestamp without time zone DEFAULT now(),
    source character varying
);


--
-- Name: membership_legend_customization; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.membership_legend_customization (
    pubkey bytea NOT NULL,
    style character varying NOT NULL,
    custom_badge boolean NOT NULL,
    avatar_glow boolean NOT NULL,
    in_leaderboard boolean,
    current_shoutout character varying,
    edited_shoutout character varying,
    donated_btc numeric DEFAULT 0,
    last_donation timestamp without time zone,
    legend_since timestamp without time zone,
    premium_since timestamp without time zone
);


--
-- Name: memberships; Type: TABLE; Schema: public; Owner: -
--

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
    origin character varying,
    legend_since timestamp without time zone,
    premium_since timestamp without time zone,
    grace_period interval DEFAULT '1 mon'::interval NOT NULL
);

ALTER TABLE ONLY public.memberships REPLICA IDENTITY FULL;


--
-- Name: verified_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.verified_users (
    name character varying(200) NOT NULL,
    pubkey bytea NOT NULL,
    default_name boolean NOT NULL,
    added_at timestamp without time zone
);

ALTER TABLE ONLY public.verified_users REPLICA IDENTITY FULL;


--
-- Name: lists; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lists (
    list character varying(200) NOT NULL,
    pubkey bytea NOT NULL,
    added_at integer NOT NULL
);

ALTER TABLE ONLY public.lists REPLICA IDENTITY FULL;


--
-- Name: media_block; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.media_block (
    id uuid NOT NULL,
    t timestamp without time zone NOT NULL,
    d jsonb NOT NULL
);


--
-- Name: media_uploads; Type: TABLE; Schema: public; Owner: -
--

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
    moderation_category character varying,
    media_block_id uuid
);

ALTER TABLE ONLY public.media_uploads REPLICA IDENTITY FULL;


--
-- Name: media_uploads_media_block_csam; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.media_uploads_media_block_csam AS
 SELECT mu.sha256,
    mb.id,
    (mb.d ->> 'reason'::text) AS reason
   FROM public.media_uploads mu,
    public.media_block mb
  WHERE ((mu.media_block_id = mb.id) AND ((mb.d ->> 'reason'::text) ~~ 'csam%'::text));


--
-- Name: membership_tiers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.membership_tiers (
    tier character varying(300) NOT NULL,
    max_storage bigint
);


--
-- Name: monitoring_notification_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.monitoring_notification_tokens (
    platform character varying NOT NULL,
    token character varying NOT NULL,
    service_pubkey bytea NOT NULL,
    relays jsonb NOT NULL,
    added_at timestamp with time zone,
    environment character varying,
    event_from_user jsonb,
    client_pubkeys bytea[] DEFAULT '{}'::bytea[] NOT NULL,
    scope character varying DEFAULT 'nip46'::character varying NOT NULL
);


--
-- Name: monitoring_request_queue; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.monitoring_request_queue (
    service_pubkey bytea NOT NULL,
    event_id bytea NOT NULL,
    event jsonb NOT NULL,
    inserted_at timestamp with time zone DEFAULT now() NOT NULL,
    scope character varying DEFAULT 'nip46'::character varying NOT NULL
);


--
-- Name: muted_threads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.muted_threads (
    pubkey bytea NOT NULL,
    root_eid bytea NOT NULL,
    muted_at timestamp without time zone NOT NULL
);


--
-- Name: notification_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_settings (
    pubkey bytea NOT NULL,
    type character varying(100) NOT NULL,
    enabled boolean NOT NULL
);


--
-- Name: notification_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_tokens (
    platform character varying NOT NULL,
    token character varying NOT NULL,
    pubkey bytea NOT NULL,
    added_at timestamp without time zone,
    environment character varying,
    event_from_user jsonb
);


--
-- Name: pubkey_notifications_seen; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pubkey_notifications_seen (
    pubkey bytea NOT NULL,
    seen_until bigint
);


--
-- Name: reported; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reported (
    pubkey bytea NOT NULL,
    type bigint NOT NULL,
    id bytea NOT NULL,
    created_at bigint NOT NULL
);


--
-- Name: short_urls; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.short_urls (
    idx bigint NOT NULL,
    url text NOT NULL,
    path text NOT NULL,
    ext text NOT NULL,
    media_block_id uuid
);


--
-- Name: short_urls_idx_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.short_urls_idx_seq
    START WITH 1100000
    INCREMENT BY 1
    MINVALUE 1100000
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_last_online_time; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_last_online_time (
    pubkey bytea NOT NULL,
    online_at bigint NOT NULL
);


--
-- Name: app_settings app_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_settings
    ADD CONSTRAINT app_settings_pkey PRIMARY KEY (key);


--
-- Name: app_subsettings app_subsettings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_subsettings
    ADD CONSTRAINT app_subsettings_pkey PRIMARY KEY (pubkey, subkey);


--
-- Name: dvm_usage dvm_usage_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dvm_usage
    ADD CONSTRAINT dvm_usage_pkey PRIMARY KEY (job_request_id);


--
-- Name: filterlist filterlist_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filterlist
    ADD CONSTRAINT filterlist_pkey PRIMARY KEY (target, target_type, blocked, grp);


--
-- Name: human_override human_override_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.human_override
    ADD CONSTRAINT human_override_pkey PRIMARY KEY (pubkey);


--
-- Name: media_block media_block_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.media_block
    ADD CONSTRAINT media_block_pkey PRIMARY KEY (id);


--
-- Name: membership_legend_customization membership_legend_customization_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.membership_legend_customization
    ADD CONSTRAINT membership_legend_customization_pk PRIMARY KEY (pubkey);


--
-- Name: memberships memberships_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_pk PRIMARY KEY (pubkey);


--
-- Name: monitoring_notification_tokens monitoring_notification_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.monitoring_notification_tokens
    ADD CONSTRAINT monitoring_notification_tokens_pkey PRIMARY KEY (platform, service_pubkey, scope);


--
-- Name: muted_threads muted_threads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.muted_threads
    ADD CONSTRAINT muted_threads_pkey PRIMARY KEY (pubkey, root_eid);


--
-- Name: monitoring_request_queue nip46_request_queue_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.monitoring_request_queue
    ADD CONSTRAINT nip46_request_queue_pkey PRIMARY KEY (service_pubkey, event_id);


--
-- Name: notification_tokens notification_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_tokens
    ADD CONSTRAINT notification_tokens_pkey PRIMARY KEY (platform, token, pubkey);


--
-- Name: pubkey_notifications_seen pubkey_notifications_seen_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pubkey_notifications_seen
    ADD CONSTRAINT pubkey_notifications_seen_pkey PRIMARY KEY (pubkey);


--
-- Name: reported reported_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reported
    ADD CONSTRAINT reported_pkey PRIMARY KEY (pubkey, type, id);


--
-- Name: user_last_online_time user_last_online_time_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_last_online_time
    ADD CONSTRAINT user_last_online_time_pkey PRIMARY KEY (pubkey);


--
-- Name: app_settings_accessed_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_settings_accessed_at ON public.app_settings USING btree (accessed_at DESC);


--
-- Name: app_settings_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_settings_accessed_at_idx ON public.app_settings USING btree (accessed_at DESC);


--
-- Name: app_settings_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_settings_key ON public.app_settings USING btree (key);


--
-- Name: app_settings_log_accessed_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_settings_log_accessed_at_idx ON public.app_settings_log USING btree (accessed_at DESC);


--
-- Name: app_settings_log_app_day_pubkey; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_settings_log_app_day_pubkey ON public.app_settings_log USING btree (((((event -> 'tags'::text) -> 0) ->> 1)), accessed_at, pubkey);
ALTER INDEX public.app_settings_log_app_day_pubkey ALTER COLUMN 1 SET STATISTICS 1000;


--
-- Name: app_settings_log_day_pubkey; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_settings_log_day_pubkey ON public.app_settings_log USING btree (accessed_at, pubkey);


--
-- Name: app_settings_log_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX app_settings_log_pubkey_idx ON public.app_settings_log USING btree (pubkey);


--
-- Name: human_override_pubkey; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX human_override_pubkey ON public.human_override USING btree (pubkey);


--
-- Name: idx_monitoring_request_queue_inserted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_monitoring_request_queue_inserted_at ON public.monitoring_request_queue USING btree (inserted_at);


--
-- Name: idx_monitoring_request_queue_service_pubkey; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_monitoring_request_queue_service_pubkey ON public.monitoring_request_queue USING btree (service_pubkey);


--
-- Name: lists_added_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lists_added_at ON public.lists USING btree (added_at DESC);


--
-- Name: lists_list; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lists_list ON public.lists USING btree (list);


--
-- Name: lists_pubkey; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lists_pubkey ON public.lists USING btree (pubkey);


--
-- Name: media_uploads_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_uploads_created_at ON public.media_uploads USING btree (created_at DESC);


--
-- Name: media_uploads_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_uploads_created_at_idx ON public.media_uploads USING btree (created_at DESC);


--
-- Name: media_uploads_media_block_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_uploads_media_block_id_idx ON public.media_uploads USING btree (media_block_id);


--
-- Name: media_uploads_path; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_uploads_path ON public.media_uploads USING btree (path);


--
-- Name: media_uploads_path_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_uploads_path_idx ON public.media_uploads USING btree (path);


--
-- Name: media_uploads_pubkey; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_uploads_pubkey ON public.media_uploads USING btree (pubkey);


--
-- Name: media_uploads_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_uploads_pubkey_idx ON public.media_uploads USING btree (pubkey);


--
-- Name: media_uploads_sha256; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_uploads_sha256 ON public.media_uploads USING btree (sha256);


--
-- Name: media_uploads_sha256_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_uploads_sha256_idx ON public.media_uploads USING btree (sha256);


--
-- Name: membership_tiers_tier; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX membership_tiers_tier ON public.membership_tiers USING btree (tier);


--
-- Name: memberships_pubkey; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memberships_pubkey ON public.memberships USING btree (pubkey);


--
-- Name: notification_settings_pubkey; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notification_settings_pubkey ON public.notification_settings USING btree (pubkey);


--
-- Name: notification_settings_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX notification_settings_pubkey_idx ON public.notification_settings USING btree (pubkey);


--
-- Name: pubkey_notifications_seen_pubkey; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_notifications_seen_pubkey ON public.pubkey_notifications_seen USING btree (pubkey);


--
-- Name: pubkey_notifications_seen_seen_until; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_notifications_seen_seen_until ON public.pubkey_notifications_seen USING btree (seen_until DESC);


--
-- Name: pubkey_notifications_seen_seen_until_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_notifications_seen_seen_until_idx ON public.pubkey_notifications_seen USING btree (seen_until DESC);


--
-- Name: reported_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reported_created_at ON public.reported USING btree (created_at DESC);


--
-- Name: reported_pubkey; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reported_pubkey ON public.reported USING btree (pubkey);


--
-- Name: short_urls_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX short_urls_idx ON public.short_urls USING btree (idx);


--
-- Name: short_urls_media_block_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX short_urls_media_block_id_idx ON public.short_urls USING btree (media_block_id);


--
-- Name: short_urls_path; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX short_urls_path ON public.short_urls USING btree (path);


--
-- Name: short_urls_url; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX short_urls_url ON public.short_urls USING btree (url);


--
-- Name: verified_users_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX verified_users_name ON public.verified_users USING btree (name);


--
-- Name: verified_users_pubkey; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX verified_users_pubkey ON public.verified_users USING btree (pubkey);



--
-- Stand-ins for the views legend_users and premium_users, with the columns primal-server reads.
-- The real definitions (membership-private.sql in the private repo) derive them from payment records.
--

CREATE VIEW public.legend_users AS
 SELECT ms.pubkey,
    ms.legend_since,
    mlc.last_donation,
    mlc.donated_btc,
    vu.name
   FROM public.memberships ms,
    public.membership_legend_customization mlc,
    public.verified_users vu
  WHERE ((ms.pubkey = mlc.pubkey) AND ((ms.tier)::text = 'legend'::text) AND (ms.pubkey = vu.pubkey) AND vu.default_name);


CREATE VIEW public.premium_users AS
 SELECT ms.pubkey,
    ms.premium_since,
    vu.name
   FROM public.memberships ms,
    public.verified_users vu
  WHERE (((ms.tier)::text = 'premium'::text) AND (ms.pubkey = vu.pubkey) AND vu.default_name);

--
-- PostgreSQL database dump complete
--

