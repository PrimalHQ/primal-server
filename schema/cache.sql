-- Baseline schema of the cache DB (primal1): the lean cache schema of the production cache host,
-- 2026-11-18, with migrations 1003 and 2008 applied: pg_dump --schema-only --no-owner --no-privileges
-- --no-subscriptions --no-publications -n public, with the extensions it uses first.
-- See README.md in this directory.

CREATE EXTENSION IF NOT EXISTS amcheck WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS dblink WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS hstore WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

--
-- PostgreSQL database dump
--

-- Dumped from database version 16.4
-- Dumped by pg_dump version 16.4

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
-- Name: cmr_grp; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.cmr_grp AS ENUM (
    'primal_spam',
    'primal_nsfw'
);


--
-- Name: cmr_scope; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.cmr_scope AS ENUM (
    'content',
    'trending'
);


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
-- Name: media_size; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.media_size AS ENUM (
    'original',
    'small',
    'medium',
    'large'
);


--
-- Name: post; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.post AS (
	event_id bytea,
	created_at bigint
);


--
-- Name: response_messages_for_post_res; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.response_messages_for_post_res AS (
	e jsonb,
	is_referenced_event boolean
);


--
-- Name: c_collection_order(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_collection_order() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000161$$;


--
-- Name: c_event_actions_count(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_event_actions_count() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000115$$;


--
-- Name: c_event_relays(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_event_relays() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000141$$;


--
-- Name: c_event_stats(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_event_stats() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000100$$;


--
-- Name: c_link_metadata(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_link_metadata() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000128$$;


--
-- Name: c_live_event_stats(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_live_event_stats() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000176$$;


--
-- Name: c_long_form_metadata(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_long_form_metadata() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000144$$;


--
-- Name: c_media_hls_urls(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_media_hls_urls() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000178$$;


--
-- Name: c_media_metadata(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_media_metadata() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000119$$;


--
-- Name: c_membership_cohorts(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_membership_cohorts() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000169$$;


--
-- Name: c_membership_legend_customization(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_membership_legend_customization() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000168$$;


--
-- Name: c_poll_stats(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_poll_stats() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000179$$;


--
-- Name: c_range(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_range() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000113$$;


--
-- Name: c_referenced_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_referenced_event() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000107$$;


--
-- Name: c_studio_home_graph(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_studio_home_graph() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000902$$;


--
-- Name: c_studio_home_top_articles(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_studio_home_top_articles() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000904$$;


--
-- Name: c_studio_home_top_notes(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_studio_home_top_notes() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000903$$;


--
-- Name: c_studio_home_totals(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_studio_home_totals() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000901$$;


--
-- Name: c_user_follower_counts(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_user_follower_counts() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000133$$;


--
-- Name: c_user_primal_names(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_user_primal_names() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000158$$;


--
-- Name: c_user_scores(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_user_scores() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000108$$;


--
-- Name: c_zap_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.c_zap_event() RETURNS integer
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$SELECT 10000129$$;


--
-- Name: contact_list(bytea, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.contact_list(a_pubkey bytea, a_extended_response boolean DEFAULT true) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  eid bytea;
  e jsonb;
  followed_pubkeys bytea[];
BEGIN
  SELECT value INTO eid FROM contact_lists WHERE key = a_pubkey LIMIT 1;
  IF eid IS NOT NULL THEN
    e := get_event_jsonb(eid);
    IF e IS NOT NULL THEN
      RETURN NEXT e;
      IF a_extended_response THEN
        -- Extract p-tag pubkeys from the contact list event
        SELECT array_agg(decode(t->>1, 'hex'))
        INTO followed_pubkeys
        FROM jsonb_array_elements(e->'tags') t
        WHERE t->>0 = 'p' AND length(t->>1) = 64;

        IF followed_pubkeys IS NOT NULL THEN
          RETURN QUERY SELECT * FROM user_infos(followed_pubkeys);
        END IF;
      END IF;
    END IF;
  END IF;
END
$$;


--
-- Name: content_moderation_filtering(jsonb, public.cmr_scope, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.content_moderation_filtering(a_results jsonb, a_scope public.cmr_scope, a_user_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
SELECT e 
FROM jsonb_array_elements(a_results) r(e) 
WHERE (e->>'pubkey' IS NULL OR NOT is_pubkey_hidden(a_user_pubkey, a_scope, DECODE(e->>'pubkey', 'hex'))) AND
      (e->>'id' IS NULL OR NOT EXISTS (
        SELECT 1 FROM cmr_pubkeys_scopes cmr, basic_tags bt
        WHERE bt.id = DECODE(e->>'id', 'hex') AND bt.tag = 'p' AND bt.arg1 = cmr.pubkey 
          AND cmr.user_pubkey = a_user_pubkey and cmr.scope = a_scope
        LIMIT 1))
$$;


--
-- Name: count_jsonb_keys(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.count_jsonb_keys(j jsonb) RETURNS bigint
    LANGUAGE sql IMMUTABLE
    AS $$ SELECT count(*) from (SELECT jsonb_object_keys(j)) v $$;


--
-- Name: creator_paid_tiers(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.creator_paid_tiers(a_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  e jsonb;
  eid bytea;
  tag jsonb;
  e2 jsonb;
BEGIN
  SELECT get_event_jsonb(ev.id) INTO e
  FROM event ev
  WHERE ev.kind = 17000 AND ev.pubkey = a_pubkey
  ORDER BY ev.created_at DESC LIMIT 1;

  IF e IS NOT NULL THEN
    RETURN NEXT e;
    FOR tag IN SELECT jsonb_array_elements(e->'tags') LOOP
      IF tag->>0 = 'e' AND jsonb_array_length(tag) >= 2 THEN
        eid := decode(tag->>1, 'hex');
        e2 := get_event_jsonb(eid);
        IF e2 IS NOT NULL THEN
          RETURN NEXT e2;
        END IF;
      END IF;
    END LOOP;
  END IF;
END
$$;


--
-- Name: enrich_feed_events(public.post[], bytea, boolean, character varying, boolean, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.enrich_feed_events(a_posts public.post[], a_user_pubkey bytea, a_apply_humaness_check boolean, a_order_by character varying DEFAULT 'created_at'::character varying, presort boolean DEFAULT true, a_author_exempt bytea DEFAULT NULL::bytea) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
	t RECORD;
	p RECORD;
	r RECORD;
	max_created_at int8 := null;
	min_created_at int8 := null;
    user_scores jsonb := '{}';
    pubkeys bytea[] := '{}';
    identifier varchar;
    a_posts_sorted post[];
    elements jsonb := '{}';
    poll_seen bytea[] := '{}';
    enriched text[] := '{}';
BEGIN
    IF presort THEN
        a_posts_sorted := ARRAY (SELECT (event_id, created_at)::post FROM UNNEST(a_posts) p GROUP BY event_id, created_at ORDER BY created_at DESC);
    ELSE
        a_posts_sorted := a_posts;
    END IF;
    BEGIN
        SELECT COALESCE(jsonb_agg(ENCODE(event_id, 'hex')), '[]'::jsonb) INTO elements FROM UNNEST(a_posts_sorted) p;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE '% %', SQLERRM, SQLSTATE;
    END;

	FOREACH p IN ARRAY a_posts_sorted LOOP
		max_created_at := GREATEST(max_created_at, p.created_at);
		min_created_at := LEAST(min_created_at, p.created_at);
        FOR t IN SELECT * FROM response_messages_for_post(p.event_id, a_user_pubkey, false, 3, a_author_exempt) LOOP
            DECLARE
                e jsonb := t.e;
                e_id bytea := DECODE(e->>'id', 'hex');
                e_kind int8 := e->>'kind';
                e_pubkey bytea := DECODE(e->>'pubkey', 'hex');
                read_eid bytea;
            BEGIN
                -- once per event (and per referenced/top-level role): every repeat returns the same rows
                IF (e->>'id') || t.is_referenced_event::text = ANY(enriched) THEN
                    CONTINUE;
                END IF;
                enriched := array_append(enriched, (e->>'id') || t.is_referenced_event::text);

                IF e_pubkey IS NOT NULL THEN
                    pubkeys := array_append(pubkeys, e_pubkey);
                END IF;

                IF a_apply_humaness_check AND NOT t.is_referenced_event AND e_kind != 0 AND NOT user_is_human(e_pubkey, a_user_pubkey) THEN
                    CONTINUE;
                END IF;

                IF e_kind = 6 AND (
                    EXISTS (SELECT 1 FROM basic_tags WHERE id = e_id AND tag = 'p' AND is_pubkey_hidden(a_user_pubkey, 'content', arg1))
                    OR
                    EXISTS (SELECT 1 FROM basic_tags WHERE id = e_id AND tag = 'e' AND (event_is_deleted(arg1) OR is_event_hidden(a_user_pubkey, 'content', arg1)))
                ) THEN
                    CONTINUE;
                END IF;

                IF t.is_referenced_event THEN
                    RETURN NEXT jsonb_build_object(
                            'pubkey', e->>'pubkey',
                            'kind', c_REFERENCED_EVENT(),
                            'content', e::text);
                ELSE
                    RETURN NEXT e;
                END IF;

                IF (e_kind = 1068 OR e_kind = 6969) AND NOT (e_id = ANY(poll_seen)) THEN
                    poll_seen := array_append(poll_seen, e_id);
                    RETURN QUERY SELECT * FROM poll_stats(e_id);
                END IF;

                RETURN QUERY SELECT * FROM event_zaps(e_id, a_user_pubkey);

                FOR identifier IN SELECT pre.identifier FROM parametrized_replaceable_events pre WHERE event_id = e_id LOOP
                    RETURN QUERY SELECT * FROM event_zaps(e_pubkey, identifier, a_user_pubkey);
                END LOOP;

                IF    e_kind != 30023 THEN
                    RETURN QUERY SELECT * FROM event_stats(e_id);
                    -- lazy counter rows: a note-kind event without a row has all zeros (the row
                    -- event_stats() would have printed for the importer's zero row)
                    IF NOT FOUND AND e_kind IN (1, 1068, 6969, 20, 34235, 34236, 1111) THEN
                        RETURN NEXT jsonb_build_object('kind', c_EVENT_STATS(), 'content', row_to_json(z)::text)
                            FROM (SELECT ENCODE(e_id, 'hex') as event_id, 0::int8 AS likes, 0::int8 AS replies, 0::int8 AS mentions,
                                         0::int8 AS reposts, 0::int8 AS zaps, 0::int8 AS satszapped, 0::int8 AS score, 0::int8 AS score24h,
                                         0 as bookmarks) z;
                    END IF;
                ELSIF e_kind =  30023 THEN RETURN QUERY SELECT * FROM event_stats_for_long_form_content(e_id);
                END IF;

                RETURN QUERY SELECT * FROM event_action_cnt(e_id, a_user_pubkey);

                -- (event_relay hints: not read)

                IF e_kind = 0 OR e_kind = 1 OR e_kind = 6 THEN
                    RETURN QUERY SELECT * FROM event_media_response(e_id);
                    RETURN QUERY SELECT * FROM event_preview_response(e_id);
                END IF;
                IF e_kind = 30023 THEN
                    FOR read_eid IN
                        SELECT rv.eid
                        FROM reads rs, reads_versions rv
                        WHERE rs.latest_eid = e_id AND rs.pubkey = rv.pubkey AND rs.identifier = rv.identifier
                    LOOP
                        RETURN QUERY SELECT * FROM event_media_response(read_eid);
                        RETURN QUERY SELECT * FROM event_preview_response(read_eid);
                    END LOOP;
                END IF;

                IF e_kind = 30023 THEN
                    DECLARE
                        words int8;
                    BEGIN
                        SELECT rs.words INTO words FROM reads_versions rv, reads rs
                        WHERE rv.eid = e_id AND rv.pubkey = rs.pubkey AND rv.identifier = rs.identifier;
                        IF words IS NOT null THEN
                            RETURN NEXT jsonb_build_object(
                                'kind', c_LONG_FORM_METADATA(),
                                'content', jsonb_build_object(
                                    'event_id', e->>'id',
                                    'words', words)::text);
                        END IF;
                    END;
                END IF;

                IF e_kind = 0 THEN
                    -- lazy counter rows: the author of a metadata event is a known pubkey, 0 without a row
                    user_scores := jsonb_set(user_scores, array[e->>'pubkey'::text],
                        to_jsonb(COALESCE((SELECT value FROM pubkey_followers_cnt WHERE key = e_pubkey LIMIT 1), 0)));
                    RETURN QUERY SELECT * FROM user_live_events(30311, e_pubkey);
                END IF;

                IF e_kind = 9735 AND t.is_referenced_event THEN
                    RETURN QUERY SELECT * FROM event_zap_by_zap_receipt_id(e_id, a_user_pubkey);
                END IF;
            END;
        END LOOP;
	END LOOP;

    IF count_jsonb_keys(user_scores) > 0 THEN
        RETURN NEXT jsonb_build_object('kind', c_USER_SCORES(), 'content', user_scores::text);
    END IF;

    IF pubkeys != '{}' THEN
        RETURN QUERY SELECT * FROM primal_verified_names(pubkeys);
        RETURN QUERY SELECT * FROM user_blossom_servers(pubkeys);
    END IF;

	RETURN NEXT jsonb_build_object(
		'kind', c_RANGE(),
		'content', json_build_object(
			'since', min_created_at,
			'until', max_created_at,
			'order_by', a_order_by,
            'elements', elements)::text);
END;
$$;


--
-- Name: event_action_cnt(bytea, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.event_action_cnt(a_event_id bytea, a_user_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
	SELECT jsonb_build_object('kind', c_EVENT_ACTIONS_COUNT(), 'content', row_to_json(a)::text)
	FROM (
		SELECT
            ENCODE(a_event_id, 'hex') AS event_id,
            COALESCE(epa.replied::int4::bool, false) AS replied,
            COALESCE(epa.liked::int4::bool, false) AS liked,
            COALESCE(epa.reposted::int4::bool, false) AS reposted,
            COALESCE(epa.zapped::int4::bool, false) AS zapped,
            pv.option_id AS voted_for_option
        FROM (SELECT 1) one
        LEFT JOIN LATERAL (
            SELECT true AS found, replied, liked, reposted, zapped FROM event_pubkey_actions
            WHERE event_id = a_event_id AND pubkey = a_user_pubkey LIMIT 1) epa ON true
        LEFT JOIN LATERAL (
            SELECT true AS found, option_id FROM poll_user_votes
            WHERE poll_id = a_event_id AND pubkey = a_user_pubkey LIMIT 1) pv ON true
        WHERE epa.found OR pv.found
	) a
$$;


--
-- Name: event_d_tag(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.event_d_tag(tags jsonb) RETURNS character varying
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$
  select t->>1 from jsonb_array_elements(case jsonb_typeof(tags) when 'array' then tags else '[]'::jsonb end) with ordinality x(t, n)
  where case when jsonb_typeof(t) = 'array' then t->>0 = 'd' and t->>1 is not null else false end
  order by n limit 1
$$;


--
-- Name: event_has_excessive_mentions(bytea, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.event_has_excessive_mentions(a_event_id bytea, max_mentions integer DEFAULT 50) RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$
SELECT EXISTS (
    SELECT 1 FROM events e
    WHERE e.id = a_event_id
    AND (SELECT count(*) FROM jsonb_array_elements(e.tags) t WHERE t->>0 = 'p') > max_mentions
)
$$;


--
-- Name: event_is_deleted(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.event_is_deleted(a_event_id bytea) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
SELECT EXISTS (SELECT 1 FROM deleted_events WHERE event_id = a_event_id)
$$;


--
-- Name: event_lud16(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.event_lud16(content text) RETURNS character varying
    LANGUAGE plpgsql IMMUTABLE
    AS $$
begin
  return nullif(case when jsonb_typeof(content::jsonb -> 'lud16') = 'string' then content::jsonb ->> 'lud16' end, '');
exception when others then
  return null;
end $$;


--
-- Name: event_media_response(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.event_media_response(a_event_id bytea) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$	
DECLARE
    res jsonb := '{}';
    resources jsonb := '[]';
    root_mt varchar;
    thumbnails jsonb := '{}';
    r_url varchar;
    r_thumbnail_url varchar;
    r record;
BEGIN
    FOR r_url IN SELECT em.url FROM event_media em WHERE event_id = a_event_id LOOP
        DECLARE
            variants jsonb := '[]';
        BEGIN
            FOR r IN SELECT * FROM get_media_url(r_url) LOOP
                variants := variants || jsonb_build_array(jsonb_build_object(
                        's', SUBSTR(r.size, 1, 1),
                        'a', r.animated,
                        'w', r.width,
                        'h', r.height,
                        'mt', r.mimetype,
                        'dur', r.duration,
                        'media_url', r.media_url));
                root_mt := r.mimetype;
            END LOOP;
            resources := resources || jsonb_build_array(jsonb_build_object(
                    'url', r_url,
                    'variants', variants,
                    'mt', root_mt));
            FOR r_thumbnail_url IN 
                SELECT mu.media_url FROM video_thumbnails vt, get_media_url(vt.thumbnail_url) mu WHERE vt.video_url = r_url LOOP
                thumbnails := jsonb_set(thumbnails, array[r_url], to_jsonb(r_thumbnail_url));
            END LOOP;
        END;
    END LOOP;

    IF jsonb_array_length(resources) > 0 THEN
        res := jsonb_set(res, array['resources'], resources);
    END IF;
    IF count_jsonb_keys(thumbnails) > 0 THEN
        res := jsonb_set(res, array['thumbnails'], thumbnails);
    END IF;

    IF count_jsonb_keys(res) > 0 THEN
        res := jsonb_set(res, array['event_id'], to_jsonb(ENCODE(a_event_id, 'hex')));
        RETURN NEXT jsonb_build_object(
            'kind', c_MEDIA_METADATA(),
            'content', res::text);
    END IF;

    DECLARE
        res jsonb := jsonb_build_object('event_id', ENCODE(a_event_id, 'hex'));
        cnt int8 := 0;
    BEGIN
        -- res[r.url] = [{"provider": r.provider, "hls_url": r.hls_url}, ...]
        FOR r IN SELECT url, provider, hls_url FROM event_hls_media WHERE event_id = a_event_id LOOP
            cnt := cnt + 1;
            IF res ? r.url THEN
                res := jsonb_set(
                    res,
                    array[r.url],
                    (res -> r.url) || jsonb_build_array(jsonb_build_object(
                        'provider', r.provider,
                        'hls_url', r.hls_url))
                );
            ELSE
                res := jsonb_set(
                    res,
                    array[r.url],
                    jsonb_build_array(jsonb_build_object(
                        'provider', r.provider,
                        'hls_url', r.hls_url))
                );
            END IF;
        END LOOP;
        IF cnt > 0 THEN
            RETURN NEXT jsonb_build_object(
                'kind', c_MEDIA_HLS_URLS(),
                'content', res::text
            );
        END IF;
    END;
END $$;


--
-- Name: event_preview_response(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.event_preview_response(a_event_id bytea) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$	
DECLARE
    resources jsonb := '[]';
    r record;
    r_url varchar;
BEGIN
    FOR r_url IN SELECT ep.url FROM event_preview ep WHERE event_id = a_event_id LOOP
        FOR r IN SELECT mimetype, md_title, md_description, md_image, icon_url FROM preview where url = r_url LOOP
            resources := resources || jsonb_build_array(jsonb_build_object(
                    'url', r_url, 
                    'mimetype', r.mimetype, 
                    'md_title', r.md_title, 
                    'md_description', r.md_description, 
                    'md_image', r.md_image, 
                    'icon_url', r.icon_url));
        END LOOP;
    END LOOP;

    IF jsonb_array_length(resources) > 0 THEN
        RETURN NEXT jsonb_build_object(
            'kind', c_LINK_METADATA(),
            'content', jsonb_build_object(
                'resources', resources,
                'event_id', ENCODE(a_event_id, 'hex'))::text);
    END IF;
END $$;


--
-- Name: event_stats(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.event_stats(a_event_id bytea) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
	SELECT jsonb_build_object('kind', c_EVENT_STATS(), 'content', row_to_json(a)::text)
	FROM (
		SELECT ENCODE(a_event_id, 'hex') as event_id, likes, replies, mentions, reposts, zaps, satszapped, score, score24h, 0 as bookmarks
		FROM event_stats WHERE event_id = a_event_id
		LIMIT 1
	) a
$$;


--
-- Name: event_stats_for_long_form_content(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.event_stats_for_long_form_content(a_event_id bytea) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
	SELECT jsonb_build_object('kind', c_EVENT_STATS(), 'content', row_to_json(a)::text)
	FROM (
        SELECT ENCODE(a_event_id, 'hex') as event_id, likes, replies, 0 AS mentions, reposts, zaps, satszapped, 0 AS score, 0 AS score24h, 0 as bookmarks
        FROM reads WHERE latest_eid = a_event_id LIMIT 1
	) a
$$;


--
-- Name: event_zap_by_zap_receipt_id(bytea, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.event_zap_by_zap_receipt_id(a_zap_receipt_id bytea, a_user_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$	
DECLARE
    r record;
BEGIN
    FOR r IN 
        SELECT zap_receipt_id, created_at, event_id, sender, receiver, amount_sats FROM og_zap_receipts 
        WHERE zap_receipt_id = a_zap_receipt_id
    LOOP
        RETURN QUERY SELECT * FROM zap_response(r, a_user_pubkey);
    END LOOP;
END $$;


--
-- Name: event_zaps(bytea, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.event_zaps(a_event_id bytea, a_user_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$	
DECLARE
    r record;
BEGIN
    FOR r IN 
        SELECT zap_receipt_id, created_at, event_id, sender, receiver, amount_sats FROM og_zap_receipts 
        WHERE event_id = a_event_id
        ORDER BY amount_sats DESC LIMIT 5
    LOOP
        RETURN QUERY SELECT * FROM zap_response(r, a_user_pubkey);
    END LOOP;
END $$;


--
-- Name: event_zaps(bytea, character varying, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.event_zaps(a_pubkey bytea, a_identifier character varying, a_user_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$	
DECLARE
    r record;
    pk bytea;
BEGIN
    FOR r IN 
        SELECT
            zr.eid        AS zap_receipt_id,
            zr.created_at AS created_at,
            zr.target_eid AS event_id,
            zr.sender     AS sender,
            zr.receiver   AS receiver,
            zr.satszapped AS amount_sats 
        FROM
            reads_versions rv,
            zap_receipts zr
        WHERE 
            rv.pubkey = a_pubkey AND 
            rv.identifier = a_identifier AND 
            rv.eid = zr.target_eid
        ORDER BY amount_sats DESC LIMIT 5
    LOOP
        RETURN QUERY SELECT * FROM zap_response(r, a_user_pubkey);
    END LOOP;
END $$;


--
-- Name: event_zaps_by_satszapped(bytea, bigint, bigint, bigint, bigint, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.event_zaps_by_satszapped(a_event_id bytea, a_limit bigint DEFAULT 20, a_since bigint DEFAULT 0, a_until bigint DEFAULT (EXTRACT(epoch FROM now()))::bigint, a_offset bigint DEFAULT 0, a_user_pubkey bytea DEFAULT NULL::bytea) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  r record;
  e jsonb;
  pubkeys bytea[] := '{}';
BEGIN
  FOR r IN
    SELECT zr.zap_receipt_id, zr.sender, zr.receiver, zr.event_id AS zapped_event_id
    FROM og_zap_receipts zr
    WHERE zr.event_id = a_event_id
      AND zr.created_at >= a_since AND zr.created_at <= a_until
    ORDER BY zr.amount_sats DESC
    LIMIT a_limit OFFSET a_offset
  LOOP
    e := get_event_jsonb(r.zap_receipt_id);
    IF e IS NOT NULL THEN
      RETURN NEXT e;
      pubkeys := pubkeys || r.sender;
      pubkeys := pubkeys || r.receiver;
    END IF;
  END LOOP;
  IF array_length(pubkeys, 1) > 0 THEN
    RETURN QUERY SELECT * FROM user_infos(pubkeys);
  END IF;
END
$$;


--
-- Name: explore_legend_counts(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.explore_legend_counts(a_pubkey bytea) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT jsonb_build_object(
    'your_follows', (SELECT count(*) FROM pubkey_followers WHERE follower_pubkey = a_pubkey),
    'your_inner_network', (
      SELECT count(DISTINCT pk) FROM (
        SELECT pubkey AS pk FROM pubkey_followers WHERE follower_pubkey = a_pubkey
        UNION
        SELECT follower_pubkey AS pk FROM pubkey_followers WHERE pubkey = a_pubkey LIMIT 10000
      ) t
    ),
    'your_outer_network', (
      SELECT count(DISTINCT pk2) FROM (
        SELECT pf2.pubkey AS pk2
        FROM pubkey_followers pf1
        JOIN pubkey_followers pf2 ON pf2.follower_pubkey = pf1.pubkey
        WHERE pf1.follower_pubkey = a_pubkey
      ) t
    ),
    'all_users', (SELECT count(*) FROM pubkey_followers_cnt)
  )
$$;


--
-- Name: extract_bolt11(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.extract_bolt11(tags jsonb) RETURNS text
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN (
        SELECT tag.value ->> 1
        FROM jsonb_array_elements(tags) AS tag(value)
        WHERE tag.value ->> 0 = 'bolt11'
        LIMIT 1
    );
END;
$$;


--
-- Name: extract_bolt11_tag(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.extract_bolt11_tag(tags jsonb) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$
select elem ->> 1
from jsonb_array_elements(tags) as elem
where elem ->> 0 = 'bolt11'
limit 1
$$;


--
-- Name: feed_user_authored(bytea, bigint, bigint, bigint, bigint, bigint, bytea, boolean, bigint[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.feed_user_authored(a_pubkey bytea, a_since bigint, a_until bigint, a_include_replies bigint, a_limit bigint, a_offset bigint, a_user_pubkey bytea, a_apply_humaness_check boolean, a_kinds bigint[] DEFAULT '{1}'::bigint[]) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM filterlist WHERE grp in ('csam', 'impersonation') AND target_type = 'pubkey' AND target = a_pubkey AND blocked LIMIT 1) THEN
        RETURN;
    END IF;

    -- profile feed: exempt the profile owner from spam-softban hiding (threaded explicitly via
    -- a_author_exempt) so non-followers still see their authored posts.
    RETURN QUERY SELECT * FROM enrich_feed_events(
        ARRAY (
            select (pe.event_id, pe.created_at)::post
            from
                pubkey_events pe
            where
                pe.pubkey = a_pubkey and pe.created_at >= a_since and pe.created_at <= a_until and
                pe.is_reply = a_include_replies and
                pe.kind = ANY(a_kinds) and
                not exists (select 1 from deleted_events de where de.event_id = pe.event_id)
            order by pe.created_at desc limit a_limit offset a_offset
        ),
        a_user_pubkey, a_apply_humaness_check, a_author_exempt => a_pubkey);
END
$$;


--
-- Name: feed_user_follows(bytea, bigint, bigint, bigint, bigint, bigint, bytea, boolean, bigint[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.feed_user_follows(a_pubkey bytea, a_since bigint, a_until bigint, a_include_replies bigint, a_limit bigint, a_offset bigint, a_user_pubkey bytea, a_apply_humaness_check boolean, a_kinds bigint[] DEFAULT '{1}'::bigint[]) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
SELECT * FROM enrich_feed_events(
    ARRAY (
        SELECT r
        FROM user_follows_posts_progressive(
            a_pubkey,
            a_since,
            a_until,
            a_include_replies,
            a_limit,
            a_offset,
            a_kinds) r),
    a_user_pubkey, a_apply_humaness_check)
$$;


--
-- Name: fetch_results_for_user_follows_posts(bytea, bigint, bigint, bigint, integer, integer, bigint, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fetch_results_for_user_follows_posts(a_pubkey bytea, a_include_replies bigint, p_since bigint, p_until bigint, p_limit integer, p_offset integer, p_dt bigint DEFAULT (1 * 3600), p_timeout numeric DEFAULT 7.0) RETURNS SETOF public.post
    LANGUAGE plpgsql
    AS $$
DECLARE
    dt_start bigint := p_dt;
    t_start  timestamp := clock_timestamp();
    t_end    timestamp := t_start + (p_timeout || ' seconds')::interval;
    t        bigint := p_until;
    done     boolean := false;
    current_timeout int;
    r        post;
    rs       post[] := ARRAY[]::post[];
    ids      bytea[] := ARRAY[]::bytea[];
    i        bigint;
BEGIN
    PERFORM set_config('statement_timeout', trunc(p_timeout * 1000)::text, true);
    WHILE (
        (array_length(rs, 1) is null OR array_length(rs, 1) < (p_limit + p_offset))
        AND p_since <= t
        AND clock_timestamp() < t_end
        AND NOT done
        )
        LOOP
            current_timeout := trunc(extract(epoch FROM (t_end - clock_timestamp())) * 1000);
            RAISE NOTICE 'current_timeout: %', current_timeout;
            IF current_timeout < 0 THEN
                RAISE NOTICE 'exit0';
                EXIT;
            END IF;

            BEGIN
                RAISE NOTICE 't: % .. % [ % h ]', t - p_dt, t, p_dt/3600;
                i := 0;
                FOR r IN SELECT pe.event_id, pe.created_at
                         FROM pubkey_events pe, pubkey_followers pf
                         WHERE
                             pf.follower_pubkey = a_pubkey AND
                             pf.pubkey = pe.pubkey AND
                             pe.created_at >= t - p_dt AND
                             pe.created_at <= t AND
                             (
                                 pe.is_reply = 0 OR
                                 pe.is_reply = a_include_replies
                             )
                           AND referenced_event_is_note(pe.event_id)
                         ORDER BY pe.created_at DESC LIMIT p_limit
                    LOOP
                        IF array_length(rs, 1) is not null AND array_length(rs, 1) >= (p_limit + p_offset)
                            OR clock_timestamp() >= t_end
                            OR done THEN
                            RAISE NOTICE 'exit1';
                            EXIT;
                        END IF;

                        IF NOT (r.event_id = ANY(ids)) THEN
                            ids := array_append(ids, r.event_id);
                            rs  := array_append(rs, r);
                            i   := i + 1;
                            RETURN NEXT r;
                            -- (If you need to signal early termination, you might set done := true here.)
                        END IF;
                    END LOOP;
            EXCEPTION WHEN query_canceled THEN
                RAISE NOTICE 'exit2';
                EXIT;
            END;

            IF i > 0 THEN
                t := rs[array_length(rs, 1)].created_at;
                p_dt := dt_start;
            ELSE
                t := t - p_dt;
                p_dt := p_dt * 4;
            END IF;
        END LOOP;

--     RETURN QUERY SELECT * from unnest(rs) OFFSET p_offset;
END;
$$;


--
-- Name: follow_lists(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.follow_lists(a_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  eid bytea;
  e jsonb;
BEGIN
  SELECT value INTO eid FROM contact_lists WHERE key = a_pubkey LIMIT 1;
  IF eid IS NOT NULL THEN
    e := get_event_jsonb(eid);
    IF e IS NOT NULL THEN
      RETURN NEXT e;
    END IF;
  END IF;
END
$$;


--
-- Name: get_bookmarks(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_bookmarks(a_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
SELECT get_event_jsonb(event_id) FROM bookmarks WHERE pubkey = a_pubkey;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: event; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event (
    id bytea NOT NULL,
    pubkey bytea NOT NULL,
    created_at bigint NOT NULL,
    kind bigint NOT NULL,
    tags jsonb NOT NULL,
    content text NOT NULL,
    sig bytea NOT NULL,
    imported_at bigint NOT NULL
)
WITH (autovacuum_vacuum_scale_factor='0.01', autovacuum_vacuum_insert_scale_factor='0.01', toast.autovacuum_vacuum_scale_factor='0.01', toast.autovacuum_vacuum_insert_scale_factor='0.01');
ALTER TABLE ONLY public.event ALTER COLUMN pubkey SET (n_distinct=-0.091);
ALTER TABLE ONLY public.event ALTER COLUMN tags SET COMPRESSION lz4;
ALTER TABLE ONLY public.event ALTER COLUMN content SET COMPRESSION lz4;


--
-- Name: get_event(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_event(a_event_id bytea) RETURNS public.event
    LANGUAGE sql STABLE
    AS $$
SELECT
	*
FROM
	events
WHERE
	events.id = a_event_id
LIMIT
	1
$$;


--
-- Name: get_event_jsonb(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_event_jsonb(a_event_id bytea) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
SELECT
	jsonb_build_object(
		'id', ENCODE(id, 'hex'), 
		'pubkey', ENCODE(pubkey, 'hex'),
		'created_at', created_at,
		'kind', kind, 
		'tags', tags, 
		'content', content::text,
		'sig', ENCODE(sig, 'hex'))
FROM
	events
WHERE
	events.id = a_event_id
LIMIT
	1
$$;


--
-- Name: get_events(bytea[], bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_events(a_event_ids bytea[], a_user_pubkey bytea DEFAULT NULL::bytea) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  eid bytea;
  e jsonb;
BEGIN
  FOREACH eid IN ARRAY a_event_ids LOOP
    e := get_event_jsonb(eid);
    IF e IS NOT NULL THEN
      RETURN NEXT e;
    END IF;
  END LOOP;
END
$$;


--
-- Name: get_media_metadata_for_url(character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_media_metadata_for_url(a_url character varying) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT jsonb_build_object(
    'url', a_url,
    'mt', mu.mimetype,
    'variants', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        's', left(mu2.size, 1),
        'a', CASE WHEN mu2.animated = 1 THEN 1 ELSE 0 END,
        'w', mu2.width,
        'h', mu2.height,
        'mt', mu2.mimetype,
        'dur', coalesce(mu2.duration, 0),
        'media_url', mu2.media_url
      ))
      FROM get_media_url(a_url) mu2
    ), '[]'::jsonb)
  )
  FROM get_media_url(a_url) mu
  LIMIT 1
$$;


--
-- Name: get_media_url(character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_media_url(a_url character varying) RETURNS TABLE(size character varying, animated bigint, width bigint, height bigint, mimetype character varying, duration double precision, media_url character varying)
    LANGUAGE sql STABLE
    AS $$
select distinct on (m.animated, m.media_url)
   sz.oldsize, m.animated, m.width, m.height, m.mimetype, m.duration, 
   case when (ms.media_url is not null and msp.storage_provider is not null) then ms.media_url
   else m.media_url
   end as media_url
from (values ('small', 'medium'), ('medium', 'large'), ('large', 'large'), ('original', 'original')) sz(oldsize, newsize),
     media m
       left join media_storage ms on ms.h = split_part(split_part(m.media_url, '/', -1), '.', 1)
       left join media_storage_priority msp on ms.storage_provider = msp.storage_provider
where m.url = a_url and m.size = sz.newsize and ms.media_block_id is null
  and not (m.mimetype like 'video/%' and m.animated = 0)
order by m.animated desc, m.media_url, msp.priority
$$;


--
-- Name: get_mutelists(bytea[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_mutelists(a_pubkeys bytea[]) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  pk bytea;
BEGIN
  FOREACH pk IN ARRAY a_pubkeys LOOP
    RETURN QUERY SELECT * FROM response_messages_for_list(ARRAY['mute_lists'], pk, true);
  END LOOP;
END
$$;


--
-- Name: get_user_relays(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_relays(a_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  eid bytea;
  e jsonb;
  relay_tags jsonb := '[]'::jsonb;
  content_json jsonb;
  url text;
  dd jsonb;
  k text;
  v boolean;
BEGIN
  -- Try relay_list_metadata first (kind 10002)
  SELECT event_id INTO eid FROM relay_list_metadata WHERE pubkey = a_pubkey LIMIT 1;
  IF eid IS NOT NULL THEN
    e := get_event_jsonb(eid);
    IF e IS NOT NULL THEN
      SELECT coalesce(jsonb_agg(t), '[]'::jsonb) INTO relay_tags
      FROM jsonb_array_elements(e->'tags') t
      WHERE t->>0 = 'r';
    END IF;
  END IF;

  -- Fallback to contact_lists content JSON
  IF relay_tags = '[]'::jsonb THEN
    SELECT value INTO eid FROM contact_lists WHERE key = a_pubkey LIMIT 1;
    IF eid IS NOT NULL THEN
      e := get_event_jsonb(eid);
      IF e IS NOT NULL AND e->>'content' IS NOT NULL AND e->>'content' != '' THEN
        BEGIN
          content_json := (e->>'content')::jsonb;
          SELECT coalesce(jsonb_agg(jsonb_build_array('r', kv.key, prop.key) ORDER BY kv.key, prop.key), '[]'::jsonb)
          INTO relay_tags
          FROM jsonb_each(content_json) kv,
               jsonb_each(kv.value) prop
          WHERE prop.value = 'true'::jsonb AND kv.key != '';
        EXCEPTION WHEN OTHERS THEN
          relay_tags := '[]'::jsonb;
        END;
      END IF;
    END IF;
  END IF;

  RETURN NEXT jsonb_build_object(
    'kind', 10000139,
    'pubkey', encode(a_pubkey, 'hex'),
    'tags', relay_tags
  );
END
$$;


--
-- Name: get_user_relays_2(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_relays_2(a_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT * FROM get_user_relays(a_pubkey)
$$;


--
-- Name: get_zap_receipt_satszapped(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_zap_receipt_satszapped(a_eid bytea) RETURNS bigint
    LANGUAGE sql STABLE
    AS $$
SELECT parse_bolt11_amount_sats(extract_bolt11(es.tags)) FROM events es WHERE es.id = a_eid
$$;


--
-- Name: humaness_threshold_trustrank(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.humaness_threshold_trustrank() RETURNS real
    LANGUAGE sql STABLE
    AS $$select rank from pubkey_trustrank order by rank desc limit 1 offset 50000$$;


--
-- Name: is_event_hidden(bytea, public.cmr_scope, bytea, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_event_hidden(a_user_pubkey bytea, a_scope public.cmr_scope, a_event_id bytea, a_author_exempt bytea DEFAULT NULL::bytea) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
SELECT a_user_pubkey IS NOT NULL AND EXISTS (
    SELECT 1
    FROM public.event e
    WHERE e.id = a_event_id AND (
        public.is_pubkey_hidden(a_user_pubkey, a_scope, e.pubkey, a_author_exempt)

        OR EXISTS (SELECT 1 FROM zap_receipts zr WHERE zr.eid = a_event_id AND public.is_pubkey_hidden(a_user_pubkey, a_scope, zr.sender))

        -- Check for muted words in content
        OR EXISTS (
            SELECT 1
            FROM public.cmr_words_2 w, advsearch s
            WHERE w.user_pubkey = a_user_pubkey
              AND w.scope = a_scope
              AND s.id = a_event_id
              AND s.content_tsv @@ w.words
        )

        -- Check for muted hashtags
        OR EXISTS (
            SELECT 1
            FROM public.cmr_hashtags_2 h, advsearch s
            WHERE h.user_pubkey = a_user_pubkey
              AND h.scope = a_scope
              AND s.id = a_event_id
              AND s.hashtag_tsv @@ h.hashtags
        )

        -- Check if the event *is* a muted thread root
        OR EXISTS (
            SELECT 1
            FROM public.cmr_threads t
            WHERE t.user_pubkey = a_user_pubkey
              AND t.scope = a_scope
              AND t.event_id = e.id
        )

        -- Check if the event *references* a muted thread root using the basic_tags table
        OR EXISTS (
            SELECT 1
            FROM public.basic_tags bt
            INNER JOIN public.cmr_threads t ON t.user_pubkey = a_user_pubkey AND t.scope = a_scope
            WHERE bt.id = a_event_id
              AND bt.tag = 'e'
              AND bt.arg1 = t.event_id
        )
    )
)
$$;


--
-- Name: is_event_hidden_except_author(bytea, public.cmr_scope, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_event_hidden_except_author(a_user_pubkey bytea, a_scope public.cmr_scope, a_event_id bytea) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
SELECT a_user_pubkey IS NOT NULL AND (
        EXISTS (SELECT 1 FROM zap_receipts zr WHERE zr.eid = a_event_id AND public.is_pubkey_hidden(a_user_pubkey, a_scope, zr.sender))
        OR EXISTS (
            SELECT 1
            FROM public.cmr_words_2 w, advsearch s
            WHERE w.user_pubkey = a_user_pubkey
              AND w.scope = a_scope
              AND s.id = a_event_id
              AND s.content_tsv @@ w.words
        )
        OR EXISTS (
            SELECT 1
            FROM public.cmr_hashtags_2 h, advsearch s
            WHERE h.user_pubkey = a_user_pubkey
              AND h.scope = a_scope
              AND s.id = a_event_id
              AND s.hashtag_tsv @@ h.hashtags
        )
        OR EXISTS (
            SELECT 1
            FROM public.cmr_threads t
            WHERE t.user_pubkey = a_user_pubkey
              AND t.scope = a_scope
              AND t.event_id = a_event_id
        )
        OR EXISTS (
            SELECT 1
            FROM public.basic_tags bt
            INNER JOIN public.cmr_threads t ON t.user_pubkey = a_user_pubkey AND t.scope = a_scope
            WHERE bt.id = a_event_id
              AND bt.tag = 'e'
              AND bt.arg1 = t.event_id
        )
)
$$;


--
-- Name: is_pubkey_hidden(bytea, public.cmr_scope, bytea, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_pubkey_hidden(a_user_pubkey bytea, a_scope public.cmr_scope, a_pubkey bytea, a_followed_override bytea DEFAULT NULL::bytea) RETURNS boolean
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM filterlist WHERE target = a_pubkey AND target_type = 'pubkey' AND blocked AND grp in ('impersonation', 'csam')) THEN
        RETURN true;
    END IF;

    IF EXISTS (
        SELECT 1 FROM cmr_pubkeys_allowed
        WHERE user_pubkey = a_user_pubkey AND pubkey = a_pubkey
    ) THEN
        RETURN false;
    END IF;

    IF EXISTS (
        SELECT 1 FROM cmr_pubkeys_scopes
        WHERE user_pubkey = a_user_pubkey AND pubkey = a_pubkey AND scope = a_scope
    ) THEN
        RETURN true;
    END IF;

    -- spam softban: the viewer follows the author / is the author / the author is the profile
    -- owner being viewed (a_followed_override, threaded down from feed_user_authored) -> the
    -- author is exempt from spam hiding; csam/impersonation and the viewer's explicit mutes
    -- above still apply, and NSFW is still enforced below.
    IF a_pubkey = a_user_pubkey
       OR a_pubkey = a_followed_override
       OR EXISTS (SELECT 1 FROM pubkey_followers WHERE pubkey = a_pubkey AND follower_pubkey = a_user_pubkey)
    THEN
        RETURN is_pubkey_hidden_by_group(a_user_pubkey, a_scope, a_pubkey, 'primal_nsfw', 'nsfw');
    END IF;

    IF EXISTS (
        SELECT 1 FROM lists
        WHERE pubkey = a_pubkey AND list = 'spam_block'
    ) THEN
        RETURN true;
    END IF;

    RETURN
        is_pubkey_hidden_by_group(a_user_pubkey, a_scope, a_pubkey, 'primal_spam', 'spam') OR
        is_pubkey_hidden_by_group(a_user_pubkey, a_scope, a_pubkey, 'primal_nsfw', 'nsfw');
END
$$;


--
-- Name: is_pubkey_hidden_by_group(bytea, public.cmr_scope, bytea, public.cmr_grp, public.filterlist_grp); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_pubkey_hidden_by_group(a_user_pubkey bytea, a_scope public.cmr_scope, a_pubkey bytea, a_cmr_grp public.cmr_grp, a_fl_grp public.filterlist_grp) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
SELECT
    EXISTS (
        SELECT 1 FROM cmr_groups cmr, filterlist fl
        WHERE 
            cmr.user_pubkey = a_user_pubkey AND cmr.grp = a_cmr_grp AND cmr.scope = a_scope AND 
            fl.target = a_pubkey AND fl.target_type = 'pubkey' AND fl.blocked AND fl.grp = a_fl_grp AND
            NOT EXISTS (SELECT 1 FROM filterlist fl2 WHERE fl2.target = a_pubkey AND fl2.target_type = 'pubkey' AND NOT fl2.blocked))
$$;


--
-- Name: is_user_following(bytea, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_user_following(a_pubkey bytea, a_user_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT jsonb_build_object(
    'kind', 10000125,
    'content', (SELECT CASE WHEN EXISTS (
      SELECT 1 FROM pubkey_followers WHERE follower_pubkey = a_pubkey AND pubkey = a_user_pubkey
    ) THEN 'true' ELSE 'false' END)
  )
$$;


--
-- Name: live_feed_hosts(bigint, bytea, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.live_feed_hosts(a_kind bigint, a_pubkey bytea, a_identifier character varying) RETURNS bytea[]
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    host_pubkeys bytea[];
BEGIN
    host_pubkeys := ARRAY (
        SELECT DECODE(tag.value->>1, 'hex')
        FROM parametrized_replaceable_events pre, events es, jsonb_array_elements(es.tags) AS tag(value)
        WHERE pre.pubkey = a_pubkey AND pre.identifier = a_identifier AND pre.kind = 30311
          AND es.id = pre.event_id 
          AND tag.value->>0 = 'p' AND LOWER(tag.value->>3) = 'host'
    );
    IF array_length(host_pubkeys, 1) IS NULL THEN
        host_pubkeys := ARRAY[a_pubkey];
    END IF;
    RETURN host_pubkeys;
END
$$;


--
-- Name: live_feed_initial_response(bigint, bytea, character varying, bytea, character varying, bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.live_feed_initial_response(a_kind bigint, a_pubkey bytea, a_identifier character varying, a_user_pubkey bytea, a_content_moderation_mode character varying, a_limit bigint DEFAULT 20, a_apply_humaness_check boolean DEFAULT true) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    zap post;
    zaps post[];
    total_zaps int8 := 0;
    total_satszapped int8 := 0;
    host_pubkeys bytea[] := live_feed_hosts(a_kind, a_pubkey, a_identifier);
BEGIN
    RETURN QUERY SELECT get_event_jsonb(r.event_id) FROM live_feed_posts(
                a_kind,
                a_pubkey,
                a_identifier,
                a_limit
            ) r WHERE NOT live_feed_is_hidden(r.event_id, a_user_pubkey, host_pubkeys, a_content_moderation_mode);

    -- the visible zaps, once for the three answers below
    zaps := ARRAY (
        SELECT (eid, created_at)::post FROM a_tags
        WHERE kind = 9735 AND ref_kind = a_kind AND ref_pubkey = a_pubkey AND ref_identifier = a_identifier
          AND NOT live_feed_is_hidden(eid, a_user_pubkey, host_pubkeys, a_content_moderation_mode));

    RETURN QUERY SELECT get_event_jsonb(x.event_id) FROM (
            SELECT eid AS event_id, created_at FROM a_tags
            WHERE kind = 7
              AND ref_kind = a_kind AND ref_pubkey = a_pubkey AND ref_identifier = a_identifier
              AND NOT live_feed_is_hidden(eid, a_user_pubkey, host_pubkeys, a_content_moderation_mode)
            UNION ALL
            SELECT z.event_id, z.created_at FROM UNNEST(zaps) z
        ) x
        ORDER BY x.created_at DESC LIMIT 1000;

    RETURN QUERY SELECT get_event_jsonb(z.event_id) FROM UNNEST(zaps) z
        ORDER BY get_zap_receipt_satszapped(z.event_id) DESC LIMIT 5;

    FOREACH zap IN ARRAY zaps LOOP
        total_zaps := total_zaps + 1;
        total_satszapped := total_satszapped + get_zap_receipt_satszapped(zap.event_id);
    END LOOP;

    RETURN NEXT jsonb_build_object(
        'kind', c_LIVE_EVENT_STATS(),
        'created_at', EXTRACT(EPOCH FROM NOW())::int8,
        'content', json_build_object(
            'total_zaps', total_zaps,
            'total_satszapped', total_satszapped
        )::text);
END
$$;


--
-- Name: live_feed_is_hidden(bytea, bytea, bytea[], character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.live_feed_is_hidden(a_event_id bytea, a_user_pubkey bytea, a_host_pubkeys bytea[], a_content_moderation_mode character varying) RETURNS boolean
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    host_pubkey bytea;
BEGIN
    IF a_content_moderation_mode IS DISTINCT FROM 'moderated' THEN
        RETURN false;
    END IF;
    IF is_event_hidden(a_user_pubkey, 'content', a_event_id) THEN
        RETURN true;
    END IF;
    FOREACH host_pubkey IN ARRAY coalesce(a_host_pubkeys, '{}') LOOP
        IF is_event_hidden(host_pubkey, 'content', a_event_id) THEN
            RETURN true;
        END IF;
    END LOOP;
    RETURN false;
END
$$;


--
-- Name: live_feed_posts(bigint, bytea, character varying, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.live_feed_posts(a_kind bigint, a_pubkey bytea, a_identifier character varying, a_limit bigint DEFAULT 20) RETURNS SETOF public.post
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    RETURN QUERY SELECT eid, created_at 
        FROM a_tags 
        WHERE kind = 1311
          AND ref_kind = a_kind AND ref_pubkey = a_pubkey AND ref_identifier = a_identifier
        ORDER BY created_at DESC LIMIT 10000;
END
$$;


--
-- Name: long_form_content_feed(bytea, character varying, character varying, character varying, bigint, bigint, bigint, bigint, bigint, bytea, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.long_form_content_feed(a_pubkey bytea DEFAULT NULL::bytea, a_notes character varying DEFAULT 'follows'::character varying, a_topic character varying DEFAULT NULL::character varying, a_curation character varying DEFAULT NULL::character varying, a_minwords bigint DEFAULT 0, a_limit bigint DEFAULT 20, a_since bigint DEFAULT 0, a_until bigint DEFAULT (EXTRACT(epoch FROM now()))::bigint, a_offset bigint DEFAULT 0, a_user_pubkey bytea DEFAULT NULL::bytea, a_apply_humaness_check boolean DEFAULT false) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
	posts post[];
BEGIN
    IF a_limit >= 1000 THEN
        RAISE EXCEPTION 'limit too big';
    END IF;

    posts := ARRAY(SELECT r FROM long_form_content_feed_posts_progressive(
        a_pubkey, a_notes, a_topic, a_curation, a_minwords,
        a_limit, a_since, a_until, a_offset) r);

    RETURN QUERY SELECT * FROM enrich_feed_events(posts, a_user_pubkey, a_apply_humaness_check, 'published_at');
END
$$;


--
-- Name: long_form_content_feed_posts(bytea, character varying, character varying, character varying, bigint, bigint, bigint, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.long_form_content_feed_posts(a_pubkey bytea DEFAULT NULL::bytea, a_notes character varying DEFAULT 'follows'::character varying, a_topic character varying DEFAULT NULL::character varying, a_curation character varying DEFAULT NULL::character varying, a_minwords bigint DEFAULT 0, a_limit bigint DEFAULT 20, a_since bigint DEFAULT 0, a_until bigint DEFAULT (EXTRACT(epoch FROM now()))::bigint, a_offset bigint DEFAULT 0) RETURNS SETOF public.post
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    IF a_curation IS NOT NULL and a_pubkey IS NOT NULL THEN
        RETURN QUERY select distinct (r.p).* FROM (
            select
                (reads.latest_eid, reads.published_at)::post as p
            from
                parametrized_replaceable_events pre,
                a_tags at,
                reads
            where
                pre.pubkey = a_pubkey and pre.identifier = a_curation and pre.kind = 30004 and
                pre.event_id = at.eid and
                at.ref_kind = 30023 and at.ref_pubkey = reads.pubkey and at.ref_identifier = reads.identifier and
                reads.published_at >= a_since and reads.published_at <= a_until and
                reads.words >= a_minwords
            order by reads.published_at desc limit a_limit offset a_offset) r;
    ELSIF a_pubkey IS NULL THEN
        RETURN QUERY select distinct (r.p).* FROM (
            select (latest_eid, published_at)::post as p
            from reads
            where
                published_at >= a_since and published_at <= a_until and
                words >= a_minwords
                and (a_topic is null or topics @@ plainto_tsquery('simple', replace(a_topic, ' ', '-')))
            order by published_at desc limit a_limit offset a_offset) r;
    ELSIF a_notes = 'zappedbyfollows' THEN
        RETURN QUERY select distinct (r.p).* FROM (
            select (rs.latest_eid, rs.published_at)::post as p
            from pubkey_followers pf, reads rs, reads_versions rv, zap_receipts zr
            where
                pf.follower_pubkey = a_pubkey and
                pf.pubkey = zr.sender and zr.target_eid = rv.eid and
                rv.pubkey = rs.pubkey and rv.identifier = rs.identifier and
                rs.published_at >= a_since and rs.published_at <= a_until and
                rs.words >= a_minwords
            order by rs.published_at desc limit a_limit offset a_offset) r;
    ELSE
        IF a_notes = 'follows' AND EXISTS (select 1 from pubkey_followers pf where pf.follower_pubkey = a_pubkey limit 1) THEN
            RETURN QUERY select distinct (r.p).* FROM (
                select (reads.latest_eid, reads.published_at)::post as p
                from reads, pubkey_followers pf
                where
                    pf.follower_pubkey = a_pubkey and pf.pubkey = reads.pubkey and
                    reads.published_at >= a_since and reads.published_at <= a_until and
                    reads.words >= a_minwords
                    and (a_topic is null or reads.topics @@ plainto_tsquery('simple', replace(a_topic, ' ', '-')))
                order by reads.published_at desc limit a_limit offset a_offset) r;
        ELSIF a_notes = 'authored' THEN
            RETURN QUERY select distinct (r.p).* FROM (
                select (reads.latest_eid, reads.published_at)::post as p
                from reads
                where
                    reads.pubkey = a_pubkey and
                    reads.published_at >= a_since and reads.published_at <= a_until and
                    reads.words >= a_minwords
                    and (a_topic is null or topics @@ plainto_tsquery('simple', replace(a_topic, ' ', '-')))
                order by published_at desc limit a_limit offset a_offset) r;
        ELSE
            RAISE EXCEPTION 'unsupported type of notes';
        END IF;
    END IF;
END
$$;


--
-- Name: long_form_content_feed_posts_progressive(bytea, character varying, character varying, character varying, bigint, bigint, bigint, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.long_form_content_feed_posts_progressive(a_pubkey bytea DEFAULT NULL::bytea, a_notes character varying DEFAULT 'follows'::character varying, a_topic character varying DEFAULT NULL::character varying, a_curation character varying DEFAULT NULL::character varying, a_minwords bigint DEFAULT 0, a_limit bigint DEFAULT 20, a_since bigint DEFAULT 0, a_until bigint DEFAULT (EXTRACT(epoch FROM now()))::bigint, a_offset bigint DEFAULT 0) RETURNS SETOF public.post
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    days int := 1;
    effective_until bigint;
    effective_since bigint;
    total_needed bigint := a_limit + a_offset;
    posts post[];
    start_ts timestamptz := clock_timestamp();
BEGIN
    effective_until := a_until;
    LOOP
        effective_since := GREATEST(effective_until - days * 86400, a_since);

        posts := posts || ARRAY(SELECT r FROM long_form_content_feed_posts(
            a_pubkey, a_notes, a_topic, a_curation, a_minwords,
            total_needed, effective_since, effective_until, 0) r);

        EXIT WHEN array_length(posts, 1) >= total_needed;
        EXIT WHEN effective_since <= a_since;
        EXIT WHEN clock_timestamp() - start_ts > interval '7 seconds';

        effective_until := effective_since;
        days := LEAST(days * 2, 64);
    END LOOP;

    RETURN QUERY SELECT * FROM unnest(posts) OFFSET a_offset LIMIT a_limit;
END
$$;


--
-- Name: multi_kind_feed(bigint[], bigint, bigint, bigint, bigint, bytea, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.multi_kind_feed(a_kinds bigint[], a_since bigint, a_until bigint, a_limit bigint, a_offset bigint, a_user_pubkey bytea, a_apply_humaness_check boolean) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
SELECT * FROM enrich_feed_events(
    ARRAY (
        SELECT (e.id, e.created_at)::post
        FROM events e
        WHERE e.kind = ANY(a_kinds)
          AND e.created_at >= a_since
          AND e.created_at <= a_until
        ORDER BY e.created_at DESC
        LIMIT a_limit
        OFFSET a_offset
    ),
    a_user_pubkey, a_apply_humaness_check)
$$;


--
-- Name: multi_kind_thread_view(bytea, bigint[], bigint, bigint, bigint, bigint, bytea, boolean, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.multi_kind_thread_view(a_event_id bytea, a_kinds bigint[] DEFAULT '{1}'::bigint[], a_limit bigint DEFAULT 20, a_since bigint DEFAULT 0, a_until bigint DEFAULT (EXTRACT(epoch FROM now()))::bigint, a_offset bigint DEFAULT 0, a_user_pubkey bytea DEFAULT NULL::bytea, a_apply_humaness_check boolean DEFAULT false, a_include_parent_posts boolean DEFAULT true) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    IF  EXISTS (SELECT 1 FROM filterlist WHERE grp in ('csam', 'impersonation') AND target_type = 'event' AND target = a_event_id AND blocked LIMIT 1) OR
        EXISTS (SELECT 1 FROM events es, filterlist fl WHERE es.id = a_event_id AND fl.target = es.pubkey AND fl.target_type = 'pubkey' AND fl.grp in ('csam', 'impersonation') AND fl.blocked LIMIT 1)
    THEN
        RETURN;
    END IF;
    IF NOT is_event_hidden(a_user_pubkey, 'content', a_event_id) AND NOT event_is_deleted(a_event_id) AND
        NOT EXISTS (SELECT 1 FROM filterlist WHERE target = a_event_id AND target_type = 'event' AND grp = 'spam' AND blocked)
    THEN
        RETURN QUERY SELECT DISTINCT * FROM enrich_feed_events(
            ARRAY(SELECT r FROM multi_kind_thread_view_reply_posts(
                a_event_id, a_kinds,
                a_limit, a_since, a_until, a_offset) r),
            a_user_pubkey, a_apply_humaness_check);
    END IF;

    IF a_include_parent_posts THEN
        RETURN QUERY SELECT DISTINCT * FROM enrich_feed_events(
            ARRAY(SELECT r FROM multi_kind_thread_view_parent_posts(a_event_id) r ORDER BY r.created_at),
            a_user_pubkey, false);
    ELSE
        RETURN QUERY SELECT DISTINCT * FROM enrich_feed_events(
            ARRAY(SELECT (id, created_at)::post FROM events WHERE id = a_event_id),
            a_user_pubkey, a_apply_humaness_check);
    END IF;
END
$$;


--
-- Name: multi_kind_thread_view_parent_posts(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.multi_kind_thread_view_parent_posts(a_event_id bytea) RETURNS SETOF public.post
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    peid bytea := a_event_id;
BEGIN
    WHILE true LOOP
        RETURN QUERY SELECT peid, created_at FROM events WHERE id = peid;
        SELECT arg1 INTO peid FROM basic_tags
            WHERE id = peid AND tag = 'e' AND arg3 IN ('reply', 'root')
            ORDER BY CASE arg3 WHEN 'reply' THEN 0 WHEN 'root' THEN 1 END
            LIMIT 1;
        IF NOT FOUND THEN
            EXIT;
        END IF;
    END LOOP;
END
$$;


--
-- Name: multi_kind_thread_view_reply_posts(bytea, bigint[], bigint, bigint, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.multi_kind_thread_view_reply_posts(a_event_id bytea, a_kinds bigint[] DEFAULT '{1}'::bigint[], a_limit bigint DEFAULT 20, a_since bigint DEFAULT 0, a_until bigint DEFAULT (EXTRACT(epoch FROM now()))::bigint, a_offset bigint DEFAULT 0) RETURNS SETOF public.post
    LANGUAGE sql STABLE
    AS $$
SELECT er.reply_event_id, er.reply_created_at FROM event_replies er
JOIN events e ON e.id = er.reply_event_id
WHERE er.event_id = a_event_id AND e.kind = ANY(a_kinds)
AND er.reply_created_at >= a_since AND er.reply_created_at <= a_until
ORDER BY er.reply_created_at DESC LIMIT a_limit OFFSET a_offset;
$$;


--
-- Name: note_mentions(bytea, integer, integer, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.note_mentions(a_event_id bytea, a_limit integer DEFAULT 100, a_offset integer DEFAULT 0, a_user_pubkey bytea DEFAULT NULL::bytea) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT (r).e FROM (
    SELECT response_messages_for_post(pn.arg2, a_user_pubkey, false, 0) AS r
    FROM pubkey_notifications pn
    WHERE pn.arg1 = a_event_id AND pn.type = 5
    ORDER BY pn.created_at DESC
    LIMIT a_limit OFFSET a_offset
  ) t WHERE (r).e IS NOT NULL
$$;


--
-- Name: note_mentions_count(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.note_mentions_count(a_event_id bytea) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT jsonb_build_object(
    'event_id', encode(a_event_id, 'hex'),
    'count', (SELECT count(1) FROM pubkey_notifications
              WHERE arg1 = a_event_id AND type = 5) -- YOUR_POST_WAS_MENTIONED_IN_POST = 5
  )
$$;


--
-- Name: notif_row_to_json(text, bigint, bigint, bytea, bytea, bytea, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notif_row_to_json(a_pubkey_hex text, a_created_at bigint, a_type bigint, a_arg1 bytea, a_arg2 bytea, a_arg3 bytea, a_arg4 bytea) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  j jsonb;
  raw jsonb;
BEGIN
  j := jsonb_build_object('created_at', a_created_at, 'pubkey', a_pubkey_hex, 'type', a_type);
  CASE a_type
    -- NEW_USER_FOLLOWED_YOU=1: (follower: PubKeyId)
    WHEN 1 THEN
      j := j || jsonb_build_object('follower', encode(a_arg1, 'hex'));
    -- USER_UNFOLLOWED_YOU=2: (follower: PubKeyId)
    WHEN 2 THEN
      j := j || jsonb_build_object('follower', encode(a_arg1, 'hex'));
    -- YOUR_POST_WAS_ZAPPED=3: (your_post: EventId, who_zapped_it: PubKeyId, satszapped: Int, message: String)
    WHEN 3 THEN
      j := j || jsonb_build_object('your_post', encode(a_arg1, 'hex'), 'who_zapped_it', encode(a_arg2, 'hex'));
      IF a_arg3 IS NOT NULL THEN
        BEGIN j := j || jsonb_build_object('satszapped', convert_from(a_arg3, 'UTF8')::jsonb); EXCEPTION WHEN OTHERS THEN END;
      END IF;
      IF a_arg4 IS NOT NULL THEN
        BEGIN j := j || jsonb_build_object('message', convert_from(a_arg4, 'UTF8')::jsonb); EXCEPTION WHEN OTHERS THEN END;
      END IF;
    -- YOUR_POST_WAS_LIKED=4: (your_post: EventId, who_liked_it: PubKeyId, reaction: String)
    WHEN 4 THEN
      j := j || jsonb_build_object('your_post', encode(a_arg1, 'hex'), 'who_liked_it', encode(a_arg2, 'hex'));
      IF a_arg3 IS NOT NULL THEN
        BEGIN j := j || jsonb_build_object('reaction', convert_from(a_arg3, 'UTF8')::jsonb); EXCEPTION WHEN OTHERS THEN END;
      END IF;
    -- YOUR_POST_WAS_REPOSTED=5: (your_post: EventId, who_reposted_it: PubKeyId)
    WHEN 5 THEN
      j := j || jsonb_build_object('your_post', encode(a_arg1, 'hex'), 'who_reposted_it', encode(a_arg2, 'hex'));
    -- YOUR_POST_WAS_REPLIED_TO=6: (your_post: EventId, who_replied_to_it: PubKeyId, reply: EventId)
    WHEN 6 THEN
      j := j || jsonb_build_object('your_post', encode(a_arg1, 'hex'), 'who_replied_to_it', encode(a_arg2, 'hex'));
      IF a_arg3 IS NOT NULL THEN j := j || jsonb_build_object('reply', encode(a_arg3, 'hex')); END IF;
    -- YOU_WERE_MENTIONED_IN_POST=7: (you_were_mentioned_in: EventId, you_were_mentioned_by: PubKeyId)
    WHEN 7 THEN
      j := j || jsonb_build_object('you_were_mentioned_in', encode(a_arg1, 'hex'), 'you_were_mentioned_by', encode(a_arg2, 'hex'));
    -- YOUR_POST_WAS_MENTIONED_IN_POST=8: (your_post: EventId, your_post_were_mentioned_in: EventId, your_post_was_mentioned_by: PubKeyId)
    WHEN 8 THEN
      j := j || jsonb_build_object('your_post', encode(a_arg1, 'hex'), 'your_post_were_mentioned_in', encode(a_arg2, 'hex'), 'your_post_was_mentioned_by', encode(a_arg3, 'hex'));
    -- POST_YOU_WERE_MENTIONED_IN_WAS_ZAPPED=101
    WHEN 101 THEN
      j := j || jsonb_build_object('post_you_were_mentioned_in', encode(a_arg1, 'hex'), 'who_zapped_it', encode(a_arg2, 'hex'));
      IF a_arg3 IS NOT NULL THEN
        BEGIN j := j || jsonb_build_object('satszapped', convert_from(a_arg3, 'UTF8')::jsonb); EXCEPTION WHEN OTHERS THEN END;
      END IF;
    -- POST_YOU_WERE_MENTIONED_IN_WAS_LIKED=102
    WHEN 102 THEN
      j := j || jsonb_build_object('post_you_were_mentioned_in', encode(a_arg1, 'hex'), 'who_liked_it', encode(a_arg2, 'hex'));
    -- POST_YOU_WERE_MENTIONED_IN_WAS_REPOSTED=103
    WHEN 103 THEN
      j := j || jsonb_build_object('post_you_were_mentioned_in', encode(a_arg1, 'hex'), 'who_reposted_it', encode(a_arg2, 'hex'));
    -- POST_YOU_WERE_MENTIONED_IN_WAS_REPLIED_TO=104
    WHEN 104 THEN
      j := j || jsonb_build_object('post_you_were_mentioned_in', encode(a_arg1, 'hex'), 'who_replied_to_it', encode(a_arg2, 'hex'));
      IF a_arg3 IS NOT NULL THEN j := j || jsonb_build_object('reply', encode(a_arg3, 'hex')); END IF;
    -- POST_YOUR_POST_WAS_MENTIONED_IN_WAS_ZAPPED=201
    WHEN 201 THEN
      j := j || jsonb_build_object('post_your_post_was_mentioned_in', encode(a_arg1, 'hex'), 'your_post', encode(a_arg2, 'hex'), 'who_zapped_it', encode(a_arg3, 'hex'));
      IF a_arg4 IS NOT NULL THEN
        BEGIN j := j || jsonb_build_object('satszapped', convert_from(a_arg4, 'UTF8')::jsonb); EXCEPTION WHEN OTHERS THEN END;
      END IF;
    -- POST_YOUR_POST_WAS_MENTIONED_IN_WAS_LIKED=202
    WHEN 202 THEN
      j := j || jsonb_build_object('post_your_post_was_mentioned_in', encode(a_arg1, 'hex'), 'your_post', encode(a_arg2, 'hex'), 'who_liked_it', encode(a_arg3, 'hex'));
    -- POST_YOUR_POST_WAS_MENTIONED_IN_WAS_REPOSTED=203
    WHEN 203 THEN
      j := j || jsonb_build_object('post_your_post_was_mentioned_in', encode(a_arg1, 'hex'), 'your_post', encode(a_arg2, 'hex'), 'who_reposed_it', encode(a_arg3, 'hex'));
    -- POST_YOUR_POST_WAS_MENTIONED_IN_WAS_REPLIED_TO=204
    WHEN 204 THEN
      j := j || jsonb_build_object('post_your_post_was_mentioned_in', encode(a_arg1, 'hex'), 'your_post', encode(a_arg2, 'hex'), 'who_replied_to_it', encode(a_arg3, 'hex'));
      IF a_arg4 IS NOT NULL THEN j := j || jsonb_build_object('reply', encode(a_arg4, 'hex')); END IF;
    -- YOUR_POST_WAS_HIGHLIGHTED=301
    WHEN 301 THEN
      j := j || jsonb_build_object('your_post', encode(a_arg1, 'hex'), 'who_highlighted_it', encode(a_arg2, 'hex'));
      IF a_arg3 IS NOT NULL THEN j := j || jsonb_build_object('highlight', encode(a_arg3, 'hex')); END IF;
    -- YOUR_POST_WAS_BOOKMARKED=302
    WHEN 302 THEN
      j := j || jsonb_build_object('your_post', encode(a_arg1, 'hex'), 'who_bookmarked_it', encode(a_arg2, 'hex'));
    -- NEW_DIRECT_MESSAGE=401
    WHEN 401 THEN
      j := j || jsonb_build_object('event_id', encode(a_arg1, 'hex'), 'sender', encode(a_arg2, 'hex'));
    -- LIVE_EVENT_HAPPENING=501
    WHEN 501 THEN
      j := j || jsonb_build_object('live_event_id', encode(a_arg1, 'hex'), 'host', encode(a_arg2, 'hex'));
      IF a_arg3 IS NOT NULL THEN
        BEGIN j := j || jsonb_build_object('coordinate', convert_from(a_arg3, 'UTF8')::jsonb); EXCEPTION WHEN OTHERS THEN END;
      END IF;
    -- REPLY_TO_REPLY=601
    WHEN 601 THEN
      j := j || jsonb_build_object('your_post', encode(a_arg1, 'hex'), 'who_replied_to_it', encode(a_arg2, 'hex'));
      IF a_arg3 IS NOT NULL THEN j := j || jsonb_build_object('reply', encode(a_arg3, 'hex')); END IF;
    ELSE
      -- Unknown type, just include raw args
      NULL;
  END CASE;
  -- Sort keys and compute id = sha256(json)
  -- Julia sorts keys alphabetically, then prepends id = sha256(json_without_id)
  raw := j;
  j := jsonb_build_object('id', encode(sha256(convert_to(raw::text, 'UTF8')), 'hex')) || raw;
  RETURN j;
END;
$$;


--
-- Name: notif_row_to_json(text, bigint, bigint, bytea, bytea, jsonb, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notif_row_to_json(a_pubkey_hex text, a_created_at bigint, a_type bigint, a_arg1 bytea, a_arg2 bytea, a_arg3 jsonb, a_arg4 jsonb) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  j jsonb;
  raw jsonb;
BEGIN
  j := jsonb_build_object('created_at', a_created_at, 'pubkey', a_pubkey_hex, 'type', a_type);
  CASE a_type
    -- NEW_USER_FOLLOWED_YOU=1: (follower: PubKeyId)
    WHEN 1 THEN
      j := j || jsonb_build_object('follower', encode(a_arg1, 'hex'));
    -- USER_UNFOLLOWED_YOU=2: (follower: PubKeyId)
    WHEN 2 THEN
      j := j || jsonb_build_object('follower', encode(a_arg1, 'hex'));
    -- YOUR_POST_WAS_ZAPPED=3: (your_post: EventId, who_zapped_it: PubKeyId, satszapped: Int, message: String)
    WHEN 3 THEN
      j := j || jsonb_build_object('your_post', encode(a_arg1, 'hex'), 'who_zapped_it', encode(a_arg2, 'hex'));
      IF a_arg3 IS NOT NULL THEN j := j || jsonb_build_object('satszapped', a_arg3); END IF;
      IF a_arg4 IS NOT NULL THEN j := j || jsonb_build_object('message', a_arg4); END IF;
    -- YOUR_POST_WAS_LIKED=4: (your_post: EventId, who_liked_it: PubKeyId, reaction: String)
    WHEN 4 THEN
      j := j || jsonb_build_object('your_post', encode(a_arg1, 'hex'), 'who_liked_it', encode(a_arg2, 'hex'));
      IF a_arg3 IS NOT NULL THEN j := j || jsonb_build_object('reaction', a_arg3); END IF;
    -- YOUR_POST_WAS_REPOSTED=5: (your_post: EventId, who_reposted_it: PubKeyId)
    WHEN 5 THEN
      j := j || jsonb_build_object('your_post', encode(a_arg1, 'hex'), 'who_reposted_it', encode(a_arg2, 'hex'));
    -- YOUR_POST_WAS_REPLIED_TO=6: (your_post: EventId, who_replied_to_it: PubKeyId, reply: EventId)
    WHEN 6 THEN
      j := j || jsonb_build_object('your_post', encode(a_arg1, 'hex'), 'who_replied_to_it', encode(a_arg2, 'hex'));
      IF a_arg3 IS NOT NULL THEN j := j || jsonb_build_object('reply', a_arg3); END IF;
    -- YOU_WERE_MENTIONED_IN_POST=7: (you_were_mentioned_in: EventId, you_were_mentioned_by: PubKeyId)
    WHEN 7 THEN
      j := j || jsonb_build_object('you_were_mentioned_in', encode(a_arg1, 'hex'), 'you_were_mentioned_by', encode(a_arg2, 'hex'));
    -- YOUR_POST_WAS_MENTIONED_IN_POST=8: (your_post: EventId, your_post_were_mentioned_in: EventId, your_post_was_mentioned_by: PubKeyId)
    -- arg1=your_post (EventId), arg2=your_post_were_mentioned_in (EventId), arg3=your_post_was_mentioned_by (PubKeyId as hex string in jsonb)
    WHEN 8 THEN
      j := j || jsonb_build_object('your_post', encode(a_arg1, 'hex'), 'your_post_were_mentioned_in', encode(a_arg2, 'hex'));
      IF a_arg3 IS NOT NULL THEN j := j || jsonb_build_object('your_post_was_mentioned_by', a_arg3); END IF;
    -- POST_YOU_WERE_MENTIONED_IN_WAS_ZAPPED=101
    WHEN 101 THEN
      j := j || jsonb_build_object('post_you_were_mentioned_in', encode(a_arg1, 'hex'), 'who_zapped_it', encode(a_arg2, 'hex'));
      IF a_arg3 IS NOT NULL THEN j := j || jsonb_build_object('satszapped', a_arg3); END IF;
    -- POST_YOU_WERE_MENTIONED_IN_WAS_LIKED=102
    WHEN 102 THEN
      j := j || jsonb_build_object('post_you_were_mentioned_in', encode(a_arg1, 'hex'), 'who_liked_it', encode(a_arg2, 'hex'));
    -- POST_YOU_WERE_MENTIONED_IN_WAS_REPOSTED=103
    WHEN 103 THEN
      j := j || jsonb_build_object('post_you_were_mentioned_in', encode(a_arg1, 'hex'), 'who_reposted_it', encode(a_arg2, 'hex'));
    -- POST_YOU_WERE_MENTIONED_IN_WAS_REPLIED_TO=104
    WHEN 104 THEN
      j := j || jsonb_build_object('post_you_were_mentioned_in', encode(a_arg1, 'hex'), 'who_replied_to_it', encode(a_arg2, 'hex'));
      IF a_arg3 IS NOT NULL THEN j := j || jsonb_build_object('reply', a_arg3); END IF;
    -- POST_YOUR_POST_WAS_MENTIONED_IN_WAS_ZAPPED=201: (post, your_post: EventId, who_zapped_it: PubKeyId, satszapped: Int)
    -- arg1=post (EventId), arg2=your_post (EventId), arg3=who_zapped_it (hex in jsonb), arg4=satszapped (int in jsonb)
    WHEN 201 THEN
      j := j || jsonb_build_object('post_your_post_was_mentioned_in', encode(a_arg1, 'hex'), 'your_post', encode(a_arg2, 'hex'));
      IF a_arg3 IS NOT NULL THEN j := j || jsonb_build_object('who_zapped_it', a_arg3); END IF;
      IF a_arg4 IS NOT NULL THEN j := j || jsonb_build_object('satszapped', a_arg4); END IF;
    -- POST_YOUR_POST_WAS_MENTIONED_IN_WAS_LIKED=202
    WHEN 202 THEN
      j := j || jsonb_build_object('post_your_post_was_mentioned_in', encode(a_arg1, 'hex'), 'your_post', encode(a_arg2, 'hex'));
      IF a_arg3 IS NOT NULL THEN j := j || jsonb_build_object('who_liked_it', a_arg3); END IF;
    -- POST_YOUR_POST_WAS_MENTIONED_IN_WAS_REPOSTED=203
    WHEN 203 THEN
      j := j || jsonb_build_object('post_your_post_was_mentioned_in', encode(a_arg1, 'hex'), 'your_post', encode(a_arg2, 'hex'));
      IF a_arg3 IS NOT NULL THEN j := j || jsonb_build_object('who_reposed_it', a_arg3); END IF;
    -- POST_YOUR_POST_WAS_MENTIONED_IN_WAS_REPLIED_TO=204
    WHEN 204 THEN
      j := j || jsonb_build_object('post_your_post_was_mentioned_in', encode(a_arg1, 'hex'), 'your_post', encode(a_arg2, 'hex'));
      IF a_arg3 IS NOT NULL THEN j := j || jsonb_build_object('who_replied_to_it', a_arg3); END IF;
      IF a_arg4 IS NOT NULL THEN j := j || jsonb_build_object('reply', a_arg4); END IF;
    -- YOUR_POST_WAS_HIGHLIGHTED=301
    WHEN 301 THEN
      j := j || jsonb_build_object('your_post', encode(a_arg1, 'hex'), 'who_highlighted_it', encode(a_arg2, 'hex'));
      IF a_arg3 IS NOT NULL THEN j := j || jsonb_build_object('highlight', a_arg3); END IF;
    -- YOUR_POST_WAS_BOOKMARKED=302
    WHEN 302 THEN
      j := j || jsonb_build_object('your_post', encode(a_arg1, 'hex'), 'who_bookmarked_it', encode(a_arg2, 'hex'));
    -- NEW_DIRECT_MESSAGE=401
    WHEN 401 THEN
      j := j || jsonb_build_object('event_id', encode(a_arg1, 'hex'), 'sender', encode(a_arg2, 'hex'));
    -- LIVE_EVENT_HAPPENING=501
    WHEN 501 THEN
      j := j || jsonb_build_object('live_event_id', encode(a_arg1, 'hex'), 'host', encode(a_arg2, 'hex'));
      IF a_arg3 IS NOT NULL THEN j := j || jsonb_build_object('coordinate', a_arg3); END IF;
    -- REPLY_TO_REPLY=601
    WHEN 601 THEN
      j := j || jsonb_build_object('your_post', encode(a_arg1, 'hex'), 'who_replied_to_it', encode(a_arg2, 'hex'));
      IF a_arg3 IS NOT NULL THEN j := j || jsonb_build_object('reply', a_arg3); END IF;
    ELSE
      NULL;
  END CASE;
  -- Sort keys and compute id = sha256(json_without_id)
  -- jsonb sorts keys alphabetically by default
  raw := j;
  j := jsonb_build_object('id', encode(sha256(convert_to(raw::text, 'UTF8')), 'hex')) || raw;
  RETURN j;
END;
$$;


--
-- Name: notification_is_hidden(bigint, bytea, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notification_is_hidden(type bigint, arg1 bytea, arg2 bytea) RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$
SELECT 
    CASE type
    WHEN 1 THEN user_is_human(arg1)
    WHEN 2 THEN user_is_human(arg1)

    WHEN 3 THEN user_is_human(arg2)
    WHEN 4 THEN user_is_human(arg2)
    WHEN 5 THEN user_is_human(arg2)
    WHEN 6 THEN user_is_human(arg2)

    WHEN 7 THEN user_is_human(arg2)
    /* WHEN 8 THEN user_is_human(arg3) */

    WHEN 101 THEN user_is_human(arg2)
    WHEN 102 THEN user_is_human(arg2)
    WHEN 103 THEN user_is_human(arg2)
    WHEN 104 THEN user_is_human(arg2)

    /* WHEN 201 THEN user_is_human(arg3) */
    /* WHEN 202 THEN user_is_human(arg3) */
    /* WHEN 203 THEN user_is_human(arg3) */
    /* WHEN 204 THEN user_is_human(arg3) */
    END CASE
$$;


--
-- Name: notification_is_visible(bigint, bytea, bytea, jsonb, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.notification_is_visible(type bigint, arg1 bytea, arg2 bytea, arg3 jsonb, a_user_pubkey bytea) RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$
SELECT
    CASE type
    WHEN 1 THEN user_is_human(arg1, a_user_pubkey) and not is_pubkey_hidden(a_user_pubkey, 'content', arg1)
    WHEN 2 THEN user_is_human(arg1, a_user_pubkey) and not is_pubkey_hidden(a_user_pubkey, 'content', arg1)

    WHEN 3 THEN user_is_human(arg2, a_user_pubkey) and not is_pubkey_hidden(a_user_pubkey, 'content', arg2)
    WHEN 4 THEN user_is_human(arg2, a_user_pubkey) and not is_pubkey_hidden(a_user_pubkey, 'content', arg2)
    WHEN 5 THEN user_is_human(arg2, a_user_pubkey) and not is_pubkey_hidden(a_user_pubkey, 'content', arg2)
    WHEN 6 THEN user_is_human(arg2, a_user_pubkey) and not is_pubkey_hidden(a_user_pubkey, 'content', arg2)

    WHEN 7 THEN user_is_human(arg2, a_user_pubkey) and not is_pubkey_hidden(a_user_pubkey, 'content', arg2)
    WHEN 8 THEN user_is_human(decode(arg3 #>> '{}', 'hex'), a_user_pubkey) and not is_pubkey_hidden(a_user_pubkey, 'content', decode(arg3 #>> '{}', 'hex'))

    WHEN 101 THEN user_is_human(arg2, a_user_pubkey) and not is_pubkey_hidden(a_user_pubkey, 'content', arg2)
    WHEN 102 THEN user_is_human(arg2, a_user_pubkey) and not is_pubkey_hidden(a_user_pubkey, 'content', arg2)
    WHEN 103 THEN user_is_human(arg2, a_user_pubkey) and not is_pubkey_hidden(a_user_pubkey, 'content', arg2)
    WHEN 104 THEN user_is_human(arg2, a_user_pubkey) and not is_pubkey_hidden(a_user_pubkey, 'content', arg2)

    /* WHEN 201 THEN user_is_human(arg3, a_user_pubkey) */
    /* WHEN 202 THEN user_is_human(arg3, a_user_pubkey) */
    /* WHEN 203 THEN user_is_human(arg3, a_user_pubkey) */
    /* WHEN 204 THEN user_is_human(arg3, a_user_pubkey) */

    WHEN 301 THEN user_is_human(arg2, a_user_pubkey) and not is_pubkey_hidden(a_user_pubkey, 'content', arg2)
    WHEN 302 THEN user_is_human(arg2, a_user_pubkey) and not is_pubkey_hidden(a_user_pubkey, 'content', arg2)

    WHEN 501 THEN user_is_human(arg2, a_user_pubkey) and not is_pubkey_hidden(a_user_pubkey, 'content', arg2)

    WHEN 601 THEN user_is_human(arg2, a_user_pubkey) and not is_pubkey_hidden(a_user_pubkey, 'content', arg2) and not event_has_excessive_mentions(arg1)

    ELSE false

    END CASE
$$;


--
-- Name: parse_bolt11_amount_sats(character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.parse_bolt11_amount_sats(a_bolt11 character varying) RETURNS bigint
    LANGUAGE sql
    AS $$
WITH extracted AS (
    SELECT
        SUBSTRING(a_bolt11 FROM 'lnbc(\d+)([mun])') AS amount,
        SUBSTRING(a_bolt11 FROM 'lnbc\d+([mun])') AS unit
)
SELECT
    CASE unit
        WHEN 'm' THEN CAST(amount AS DECIMAL) * 100000000 / 1000
        WHEN 'u' THEN CAST(amount AS DECIMAL) * 100000000 / 1000000
        WHEN 'n' THEN CAST(amount AS DECIMAL) * 100000000 / 1000000000
        ELSE CAST(amount AS DECIMAL) * 100000000
        END
FROM extracted;
$$;


--
-- Name: poll_stats(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.poll_stats(a_event_id bytea) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    eid_hex text;
    cached_opts jsonb;
BEGIN
    SELECT options INTO cached_opts FROM poll_stats WHERE event_id = a_event_id;

    IF cached_opts IS NOT NULL THEN
        eid_hex := encode(a_event_id, 'hex');
        RETURN NEXT jsonb_build_object(
            'kind', c_POLL_STATS(),
            'content', jsonb_build_object(eid_hex, cached_opts)::text);
        RETURN;
    END IF;
END;
$$;


--
-- Name: poll_votes(bytea, bigint, bigint, bigint, bigint, bytea, boolean, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.poll_votes(a_event_id bytea, a_since bigint, a_until bigint, a_limit bigint, a_offset bigint, a_user_pubkey bytea, a_apply_humaness_check boolean, a_option character varying DEFAULT NULL::character varying) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    allowed_eids bytea[];
    vote_eids bytea[];
    sender_pubkeys bytea[];
BEGIN
    IF a_option IS NULL THEN
        vote_eids := ARRAY (SELECT event_id FROM poll_votes_posts(
            a_event_id, a_since, a_until, a_limit, a_offset, a_option));
        RETURN QUERY SELECT * FROM enrich_feed_events(
            ARRAY (SELECT r FROM poll_votes_posts(
                a_event_id, a_since, a_until, a_limit, a_offset, a_option) r),
            a_user_pubkey, a_apply_humaness_check);
    ELSE
        vote_eids := ARRAY (SELECT event_id FROM poll_votes_posts(
            a_event_id, a_since, a_until, a_limit, a_offset, a_option));
        allowed_eids := vote_eids;
        RETURN QUERY SELECT e FROM enrich_feed_events(
            ARRAY (SELECT (event_id, created_at)::post FROM poll_votes_posts(
                a_event_id, a_since, a_until, a_limit, a_offset, a_option)),
            a_user_pubkey, a_apply_humaness_check) f(e)
        WHERE e IS NOT NULL
          AND NOT ((e->>'kind')::int8 = 9735 AND NOT (DECODE(e->>'id', 'hex') = ANY(allowed_eids)));
    END IF;

    -- return metadata for zap vote senders
    sender_pubkeys := ARRAY (
        SELECT DISTINCT oz.sender FROM og_zap_receipts oz
        WHERE oz.zap_receipt_id = ANY(vote_eids)
    );
    RETURN QUERY SELECT get_event_jsonb(md.value) FROM meta_data md
        WHERE md.key = ANY(sender_pubkeys);
    RETURN QUERY SELECT * FROM primal_verified_names(sender_pubkeys);
END;
$$;


--
-- Name: poll_votes_posts(bytea, bigint, bigint, bigint, bigint, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.poll_votes_posts(a_event_id bytea, a_since bigint, a_until bigint, a_limit bigint, a_offset bigint, a_option character varying DEFAULT NULL::character varying) RETURNS SETOF public.post
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    IF a_option IS NULL THEN
        RETURN QUERY
        SELECT bt.id, bt.created_at
        FROM basic_tags bt
        WHERE bt.arg1 = a_event_id
          AND bt.tag = 'e'
          AND bt.kind IN (1018, 9735)
          AND bt.created_at >= a_since
          AND bt.created_at <= a_until
        ORDER BY bt.created_at DESC
        LIMIT a_limit
        OFFSET a_offset;
    ELSE
        RETURN QUERY
        SELECT bt.id, bt.created_at
        FROM basic_tags bt
        WHERE bt.arg1 = a_event_id
          AND bt.tag = 'e'
          AND bt.kind IN (1018, 9735)
          AND bt.created_at >= a_since
          AND bt.created_at <= a_until
          AND EXISTS (
              SELECT 1 FROM poll_user_votes pv
              WHERE pv.vote_eid = bt.id AND pv.option_id = a_option
          )
        ORDER BY bt.created_at DESC
        LIMIT a_limit
        OFFSET a_offset;
    END IF;
END
$$;


--
-- Name: poll_votes_progressive(bytea, bigint, bigint, bigint, bigint, bytea, boolean, character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.poll_votes_progressive(a_event_id bytea, a_since bigint, a_until bigint, a_limit bigint, a_offset bigint, a_user_pubkey bytea, a_apply_humaness_check boolean, a_option character varying DEFAULT NULL::character varying) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    days int := 1;
    effective_until bigint;
    effective_since bigint;
    total_needed bigint := a_limit + a_offset;
    posts post[];
    start_ts timestamptz := clock_timestamp();
BEGIN
    effective_until := a_until;
    LOOP
        effective_since := GREATEST(effective_until - days * 86400, a_since);

        posts := posts || ARRAY(SELECT r FROM poll_votes_posts(
            a_event_id, effective_since, effective_until,
            total_needed, 0, a_option) r);

        EXIT WHEN array_length(posts, 1) >= total_needed;
        EXIT WHEN effective_since <= a_since;
        EXIT WHEN clock_timestamp() - start_ts > interval '7 seconds';

        effective_until := effective_since;
        days := LEAST(days * 2, 64);
    END LOOP;

    RETURN QUERY SELECT * FROM enrich_feed_events(
        (SELECT ARRAY(SELECT p FROM unnest(posts) p OFFSET a_offset LIMIT a_limit)),
        a_user_pubkey, a_apply_humaness_check);
END
$$;


--
-- Name: primal_verified_names(bytea[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.primal_verified_names(a_pubkeys bytea[]) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    r jsonb;
BEGIN
    SELECT json_object_agg(ENCODE(pubkey, 'hex'), name) INTO r FROM verified_users WHERE pubkey = ANY(a_pubkeys) and default_name;
    IF r IS NOT NULL THEN
        RETURN NEXT jsonb_build_object('kind', c_USER_PRIMAL_NAMES(), 'content', r::text);
    END IF;

    SELECT json_object_agg(
        ENCODE(pubkey, 'hex'), 
        jsonb_build_object(
            'style', case when style = '' then null else style end,
            'custom_badge', custom_badge, 
            'avatar_glow', avatar_glow,
            'in_leaderboard', in_leaderboard,
            'current_shoutout', case when current_shoutout = '' or current_shoutout is null then 'Supporter of open networks and open source builders'
                                else current_shoutout
                                end
    ))
    INTO r FROM membership_legend_customization WHERE pubkey = ANY(a_pubkeys);
    IF r IS NOT NULL THEN
        RETURN NEXT jsonb_build_object('kind', c_MEMBERSHIP_LEGEND_CUSTOMIZATION(), 'content', r::text);
    END IF;

    SELECT json_object_agg(
        ENCODE(pubkey, 'hex'), 
        jsonb_build_object(
            'cohort_1', cohort_1, 
            'cohort_2', cohort_2, 
            'tier', tier, 
            'expires_on', extract(epoch from valid_until)::int8,
            'legend_since', extract(epoch from least(legend_since, premium_since))::int8,
            'premium_since', extract(epoch from premium_since)::int8
    ))
    INTO r FROM memberships WHERE pubkey = ANY(a_pubkeys) AND 
    (tier = 'premium' or tier = 'premium-legend')
    ;
    IF r IS NOT NULL THEN
        RETURN NEXT jsonb_build_object('kind', c_MEMBERSHIP_COHORTS(), 'content', r::text);
    END IF;
END
$$;


--
-- Name: raise_notice(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.raise_notice(a text) RETURNS void
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
RAISE NOTICE '%', a;
END;
$$;


--
-- Name: record_trusted_pubkey_followers_cnt(); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.record_trusted_pubkey_followers_cnt()
    LANGUAGE plpgsql
    AS $$
DECLARE
    t timestamp := NOW();
BEGIN
    WITH fc AS (
        SELECT 
            pf.pubkey, COUNT(1) as cnt
        FROM 
            pubkey_followers pf, pubkey_trustrank tr1, pubkey_trustrank tr2
        WHERE 
            pf.pubkey = tr1.pubkey AND tr1.rank > 0 AND user_has_bio(tr1.pubkey) AND
            pf.follower_pubkey = tr2.pubkey AND tr2.rank > 0
        GROUP BY pf.pubkey
    )
    INSERT INTO trusted_pubkey_followers_cnt
    SELECT t, fc.pubkey, fc.cnt
    FROM fc;
END
$$;


--
-- Name: referenced_event_is_note(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.referenced_event_is_note(a_event_id bytea) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
select
    case
        when es.kind = 1 then true
        when es.kind = 6 then exists (
            select 1 from basic_tags bt, events es2
            where bt.id = a_event_id and bt.tag = 'e' and bt.arg1 = es2.id and es2.kind = 1)
        else false
        end
from events es
where es.id = a_event_id
$$;


--
-- Name: replaceable_event(bytea, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.replaceable_event(a_pubkey bytea, a_kind bigint) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
declare
  eid bytea;
  e jsonb;
begin
  for eid in select id from event where pubkey = a_pubkey and kind = a_kind and a_kind between 10000 and 19999
             order by created_at desc, id limit 1 loop
    e := get_event_jsonb(eid);
    if e is not null then
      return next e;
    end if;
  end loop;
end
$$;


--
-- Name: response_messages_for_post(bytea, bytea, boolean, bigint, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.response_messages_for_post(a_event_id bytea, a_user_pubkey bytea, a_is_referenced_event boolean, a_depth bigint, a_author_exempt bytea DEFAULT NULL::bytea) RETURNS SETOF public.response_messages_for_post_res
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
	e event%ROWTYPE;
    eid bytea;
    pk bytea;
BEGIN
    IF a_depth = 0 THEN
        RETURN;
    END IF;

    -- the one read of the event row (before: get_event, get_event_jsonb, is_event_hidden's lookup)
    SELECT * INTO e FROM events WHERE events.id = a_event_id LIMIT 1;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF event_is_deleted(e.id) THEN
        RETURN;
    ELSIF is_pubkey_hidden(a_user_pubkey, 'content', e.pubkey, a_author_exempt) THEN
        RETURN;
    -- is_event_hidden(a_user_pubkey, 'content', a_event_id, a_author_exempt) minus what is known
    -- here: the event exists and its author is not hidden (the same is_pubkey_hidden call)
    ELSIF is_event_hidden_except_author(a_user_pubkey, 'content', a_event_id) THEN
        RETURN;
    END IF;

    -- get_event_jsonb(e.id), built from the row in hand
    RETURN NEXT (jsonb_build_object(
		'id', ENCODE(e.id, 'hex'),
		'pubkey', ENCODE(e.pubkey, 'hex'),
		'created_at', e.created_at,
		'kind', e.kind,
		'tags', e.tags,
		'content', e.content::text,
		'sig', ENCODE(e.sig, 'hex')), a_is_referenced_event);

	RETURN NEXT (get_event_jsonb(meta_data.value), false) FROM meta_data WHERE e.pubkey = meta_data.key;

    FOR eid IN
        (
            SELECT arg1 FROM basic_tags WHERE id = a_event_id AND tag = 'e'
        ) UNION (
            SELECT argeid FROM event_mentions em WHERE em.eid = a_event_id AND tag = 'e'
        )
    LOOP
        RETURN QUERY SELECT * FROM response_messages_for_post(eid, a_user_pubkey, true, a_depth-1, a_author_exempt);
    END LOOP;

    FOR pk IN
        (
            SELECT arg1 FROM basic_tags WHERE id = a_event_id AND tag in ('p', 'P')
        ) UNION (
            SELECT argpubkey FROM event_mentions em WHERE em.eid = a_event_id AND tag in ('p', 'P')
        )
        LIMIT 50
    LOOP
        RETURN NEXT (get_event_jsonb(meta_data.value), false) FROM meta_data WHERE pk = meta_data.key;
    END LOOP;

    FOR eid IN
        (
            SELECT pre.event_id
            FROM a_tags at, parametrized_replaceable_events pre
            WHERE at.eid = a_event_id AND at.ref_kind = pre.kind AND at.ref_pubkey = pre.pubkey AND at.ref_identifier = pre.identifier
        ) UNION (
            SELECT pre.event_id
            FROM event_mentions em, parametrized_replaceable_events pre
            WHERE em.eid = a_event_id AND em.tag = 'a' AND em.argkind = pre.kind AND em.argpubkey = pre.pubkey AND em.argid = pre.identifier
        )
    LOOP
        RETURN QUERY SELECT * FROM response_messages_for_post(eid, a_user_pubkey, true, a_depth-1, a_author_exempt);
    END LOOP;
END;
$$;


--
-- Name: safe_json(text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.safe_json(i text, fallback jsonb) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
    AS $$
BEGIN
    RETURN i::jsonb;
EXCEPTION
    WHEN others THEN
        RETURN fallback;
END;
$$;


--
-- Name: safe_jsonb(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.safe_jsonb(data text) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
    AS $$
BEGIN
    RETURN data::jsonb;
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END;
$$;


--
-- Name: thread_view(bytea, bigint, bigint, bigint, bigint, bytea, boolean, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.thread_view(a_event_id bytea, a_limit bigint DEFAULT 20, a_since bigint DEFAULT 0, a_until bigint DEFAULT (EXTRACT(epoch FROM now()))::bigint, a_offset bigint DEFAULT 0, a_user_pubkey bytea DEFAULT NULL::bytea, a_apply_humaness_check boolean DEFAULT false, a_include_parent_posts boolean DEFAULT true) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    IF  EXISTS (SELECT 1 FROM filterlist WHERE grp in ('csam', 'impersonation') AND target_type = 'event' AND target = a_event_id AND blocked LIMIT 1) OR
        EXISTS (SELECT 1 FROM events es, filterlist fl WHERE es.id = a_event_id AND fl.target = es.pubkey AND fl.target_type = 'pubkey' AND fl.grp in ('csam', 'impersonation') AND fl.blocked LIMIT 1)
    THEN
        RETURN;
    END IF;
    IF NOT is_event_hidden(a_user_pubkey, 'content', a_event_id) AND NOT event_is_deleted(a_event_id) AND 
        NOT EXISTS (SELECT 1 FROM filterlist WHERE target = a_event_id AND target_type = 'event' AND grp = 'spam' AND blocked)
    THEN
        RETURN QUERY SELECT DISTINCT * FROM enrich_feed_events(
            ARRAY(SELECT r FROM thread_view_reply_posts(
                a_event_id, 
                a_limit, a_since, a_until, a_offset) r),
            a_user_pubkey, a_apply_humaness_check);
    END IF;

    IF a_include_parent_posts THEN
        RETURN QUERY SELECT DISTINCT * FROM enrich_feed_events(
            ARRAY(SELECT r FROM thread_view_parent_posts(a_event_id) r ORDER BY r.created_at), 
            a_user_pubkey, false);
    ELSE
        RETURN QUERY SELECT DISTINCT * FROM enrich_feed_events(
            ARRAY(SELECT (id, created_at)::post FROM events WHERE id = a_event_id),
            a_user_pubkey, a_apply_humaness_check);
    END IF;
END
$$;


--
-- Name: thread_view_parent_posts(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.thread_view_parent_posts(a_event_id bytea) RETURNS SETOF public.post
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    peid bytea := a_event_id;
BEGIN
    WHILE true LOOP
        RETURN QUERY SELECT peid, created_at FROM events WHERE id = peid;
        FOR peid IN SELECT value FROM event_thread_parents WHERE key = peid LOOP
        END LOOP;
        IF NOT FOUND THEN
            EXIT;
        END IF;
    END LOOP;
END
$$;


--
-- Name: thread_view_reply_posts(bytea, bigint, bigint, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.thread_view_reply_posts(a_event_id bytea, a_limit bigint DEFAULT 20, a_since bigint DEFAULT 0, a_until bigint DEFAULT (EXTRACT(epoch FROM now()))::bigint, a_offset bigint DEFAULT 0) RETURNS SETOF public.post
    LANGUAGE sql STABLE
    AS $$
select reply_event_id, reply_created_at from event_replies
where event_id = a_event_id and reply_created_at >= a_since and reply_created_at <= a_until
order by reply_created_at desc limit a_limit offset a_offset;
$$;


--
-- Name: trusted_nostr_users(character varying); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trusted_nostr_users(a_period character varying) RETURNS TABLE(t date, cnt integer)
    LANGUAGE sql
    AS $$
select date_trunc(a_period, to_timestamp(es.created_at))::date as t, count(distinct es.pubkey) as cnt
from events es
where es.created_at >= extract(epoch from now() - interval '6 months')::int8
group by t order by t
$$;


--
-- Name: try_cast_jsonb(text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.try_cast_jsonb(a_json text, a_default jsonb) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
    AS $$
BEGIN
  BEGIN
    RETURN a_json::jsonb;
  EXCEPTION
    WHEN OTHERS THEN
       RETURN a_default;
  END;
END;
$$;


--
-- Name: update_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
   NEW.updated_at = now();
   RETURN NEW;
END; $$;


--
-- Name: update_user_relative_daily_follower_count_increases(); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.update_user_relative_daily_follower_count_increases()
    LANGUAGE plpgsql
    AS $$
DECLARE
    ts1 timestamp;
    ts2 timestamp;
BEGIN
    SELECT t INTO ts2 FROM trusted_pubkey_followers_cnt ORDER BY t DESC LIMIT 1;
    /* SELECT t INTO ts1 FROM trusted_pubkey_followers_cnt ORDER BY t DESC LIMIT 1 OFFSET 1; */
    SELECT t INTO ts1 FROM trusted_pubkey_followers_cnt WHERE t < ts2 - INTERVAL '24h' ORDER BY t DESC LIMIT 1;
    /* SELECT t INTO ts1 FROM trusted_pubkey_followers_cnt WHERE t < ts2 - INTERVAL '3h' ORDER BY t DESC LIMIT 1; */

    CREATE TABLE IF NOT EXISTS daily_followers_cnt_increases (
        pubkey bytea not null, 
        cnt int8 not null, 
        increase int8 not null, 
        ratio float4 not null, 
        primary key (pubkey)
    );

    TRUNCATE daily_followers_cnt_increases;

    WITH 
        t1 AS (SELECT pubkey, cnt FROM trusted_pubkey_followers_cnt WHERE t = ts1),
        t2 AS (SELECT pubkey, cnt FROM trusted_pubkey_followers_cnt WHERE t = ts2)
    INSERT INTO daily_followers_cnt_increases 
        SELECT pubkey, cnt, dcnt, dcnt::float4/cnt AS relcnt FROM (
            SELECT t1.pubkey, t1.cnt, t2.cnt-t1.cnt AS dcnt 
            FROM t1, t2 
            WHERE t1.pubkey = t2.pubkey) a 
        WHERE dcnt > 0 ORDER BY relcnt DESC LIMIT 10000;

    COMMIT;
END
$$;


--
-- Name: user_blossom_servers(bytea[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_blossom_servers(a_pubkeys bytea[]) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
declare
    eid bytea;
begin
    for eid in select distinct on (pubkey) id from event where pubkey = any(a_pubkeys) and kind = 10063
               order by pubkey, created_at desc, id loop
            return next get_event_jsonb(eid);
        end loop;
end
$$;


--
-- Name: user_follows_posts(bytea, bigint, bigint, bigint, bigint, bigint, bigint[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_follows_posts(a_pubkey bytea, a_since bigint, a_until bigint, a_include_replies bigint, a_limit bigint, a_offset bigint, a_kinds bigint[] DEFAULT '{1}'::bigint[]) RETURNS SETOF public.post
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    IF a_kinds <@ '{1, 6, 20, 1068, 6969, 34235, 34236}'::bigint[] THEN
        RETURN QUERY
        SELECT
            es.event_id,
            es.created_at
        FROM
            pubkey_followers pf
            JOIN LATERAL (
                SELECT pe.event_id, pe.created_at, pe.is_reply
                FROM pubkey_events pe
                WHERE pe.pubkey = pf.pubkey
                  AND pe.kind = ANY(a_kinds)
                  AND pe.created_at >= a_since - 30
                  AND pe.created_at <= a_until - 30
                  AND NOT EXISTS (SELECT 1 FROM deleted_events de WHERE de.event_id = pe.event_id)
                ORDER BY pe.created_at DESC
                LIMIT a_limit
            ) es ON true
        WHERE
            pf.follower_pubkey = a_pubkey AND
            (
                es.is_reply = 0 OR
                es.is_reply = a_include_replies
            )
        ORDER BY
            es.created_at DESC
        LIMIT
            a_limit
        OFFSET
            a_offset;
    ELSE
        RETURN QUERY
        SELECT
            es.id,
            es.created_at
        FROM
            pubkey_followers pf
            JOIN LATERAL (
                SELECT e.id, e.created_at
                FROM event e
                WHERE e.pubkey = pf.pubkey
                  AND e.kind = ANY(a_kinds)
                  AND e.created_at >= a_since - 30
                  AND e.created_at <= a_until - 30
                ORDER BY e.created_at DESC
                LIMIT a_limit
            ) es ON true
            LEFT JOIN pubkey_events pe ON pe.event_id = es.id
        WHERE
            pf.follower_pubkey = a_pubkey AND
            (
                pe.event_id IS NULL OR
                pe.is_reply = 0 OR
                pe.is_reply = a_include_replies
            )
        ORDER BY
            es.created_at DESC
        LIMIT
            a_limit
        OFFSET
            a_offset;
    END IF;
END
$$;


--
-- Name: user_follows_posts_progressive(bytea, bigint, bigint, bigint, bigint, bigint, bigint[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_follows_posts_progressive(a_pubkey bytea, a_since bigint, a_until bigint, a_include_replies bigint, a_limit bigint, a_offset bigint, a_kinds bigint[] DEFAULT '{1}'::bigint[]) RETURNS SETOF public.post
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    days int := 1;
    effective_until bigint;
    effective_since bigint;
    total_needed bigint := a_limit + a_offset;
    posts post[];
    start_ts timestamptz := clock_timestamp();
BEGIN
    effective_until := a_until;
    LOOP
        effective_since := GREATEST(effective_until - days * 86400, a_since);

        posts := posts || ARRAY(SELECT r FROM user_follows_posts(
            a_pubkey, effective_since, effective_until,
            a_include_replies, total_needed, 0, a_kinds) r);

        EXIT WHEN array_length(posts, 1) >= total_needed;
        EXIT WHEN effective_since <= a_since;
        EXIT WHEN clock_timestamp() - start_ts > interval '7 seconds';

        effective_until := effective_since;
        days := LEAST(days * 2, 64);
    END LOOP;

    RETURN QUERY SELECT * FROM unnest(posts) OFFSET a_offset LIMIT a_limit;
END
$$;


--
-- Name: user_has_bio(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_has_bio(a_pubkey bytea) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
SELECT coalesce(length(try_cast_jsonb(es.content::text, '{}')->>'about'), 0) > 0
FROM meta_data md, events es 
WHERE md.key = a_pubkey AND md.value = es.id
LIMIT 1
$$;


--
-- Name: user_infos(bytea[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_infos(a_pubkeys bytea[]) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    mdeid bytea;
    r jsonb;
BEGIN
    FOR mdeid IN SELECT value FROM meta_data WHERE key = ANY(a_pubkeys) LOOP
        RETURN NEXT get_event_jsonb(mdeid);
        RETURN QUERY SELECT * FROM event_media_response(mdeid);
        RETURN QUERY SELECT * FROM event_preview_response(mdeid);
    END LOOP;

    SELECT json_object_agg(ENCODE(x.k, 'hex'), COALESCE(pfc.value, 0)) INTO r
    FROM (SELECT DISTINCT k FROM UNNEST(a_pubkeys) k WHERE k IS NOT NULL) x
    LEFT JOIN pubkey_followers_cnt pfc ON pfc.key = x.k
    WHERE pfc.key IS NOT NULL OR EXISTS (SELECT 1 FROM meta_data md WHERE md.key = x.k);
	RETURN NEXT jsonb_build_object('kind', c_USER_SCORES(), 'content', r::text);
	RETURN NEXT jsonb_build_object('kind', c_USER_FOLLOWER_COUNTS(), 'content', r::text);

    RETURN QUERY SELECT * FROM primal_verified_names(a_pubkeys);
    RETURN QUERY SELECT * FROM user_blossom_servers(a_pubkeys);
END
$$;


--
-- Name: user_infos(text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_infos(a_pubkeys text[]) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
SELECT * FROM user_infos(ARRAY (SELECT DECODE(UNNEST(a_pubkeys), 'hex')))
$$;


--
-- Name: user_is_human(bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_is_human(a_pubkey bytea) RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$
SELECT (
    EXISTS (SELECT 1 FROM pubkey_trustrank ptr WHERE ptr.pubkey = a_pubkey) OR
    EXISTS (SELECT 1 FROM human_override ho WHERE ho.pubkey = a_pubkey AND ho.is_human)
)
$$;


--
-- Name: user_is_human(bytea, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_is_human(a_pubkey bytea, a_user_pubkey bytea) RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE
    AS $$
SELECT (
    EXISTS (SELECT 1 FROM pubkey_trustrank ptr WHERE ptr.pubkey = a_pubkey) OR
    EXISTS (SELECT 1 FROM human_override ho WHERE ho.pubkey = a_pubkey AND ho.is_human) OR
    EXISTS (SELECT 1 FROM pubkey_followers WHERE pubkey = a_pubkey AND follower_pubkey = a_user_pubkey)
)
$$;


--
-- Name: user_live_events(bigint, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_live_events(a_kind bigint, a_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
SELECT get_event_jsonb(lep.event_id)
FROM live_event_participants lep
WHERE lep.participant_pubkey = a_pubkey
  AND lep.kind = a_kind
  AND lep.created_at >= EXTRACT(EPOCH FROM NOW() - INTERVAL '1 hour')::int8
$$;


--
-- Name: user_profile_scored_content(bytea, integer, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_profile_scored_content(a_pubkey bytea, a_limit integer DEFAULT 5, a_user_pubkey bytea DEFAULT NULL::bytea) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    AS $$
  SELECT (r).e FROM (
    SELECT response_messages_for_post(es.event_id, a_user_pubkey, false, 0) AS r
    FROM event_stats es
    WHERE es.author_pubkey = a_pubkey AND es.score > 0
    ORDER BY es.score DESC
    LIMIT a_limit
  ) t WHERE (r).e IS NOT NULL
$$;


--
-- Name: user_search_follows(bytea, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_search_follows(a_follower bytea, a_query text, a_limit integer DEFAULT 10) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  q text;
BEGIN
  q := a_query || ':*';
  RETURN QUERY
  SELECT jsonb_build_object(
    'pubkey', encode(us.pubkey, 'hex'),
    'followers_count', coalesce(pfc.value, 0)
  )
  FROM user_search us
  JOIN pubkey_followers pf ON pf.follower_pubkey = a_follower AND pf.pubkey = us.pubkey
  LEFT JOIN pubkey_followers_cnt pfc ON pfc.key = us.pubkey
  WHERE
    us.name @@ plainto_tsquery('simple', q) OR
    us.display_name @@ plainto_tsquery('simple', q) OR
    us.nip05 @@ plainto_tsquery('simple', q)
  ORDER BY coalesce(pfc.value, 0) DESC
  LIMIT a_limit;
END;
$$;


--
-- Name: user_search_query(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_search_query(a_query text, a_limit integer DEFAULT 10) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
  q text;
BEGIN
  q := a_query || ':*';
  RETURN QUERY
  SELECT jsonb_build_object(
    'pubkey', encode(us.pubkey, 'hex'),
    'followers_count', pfc.value
  )
  FROM user_search us, pubkey_followers_cnt pfc
  WHERE
    (
      us.name @@ to_tsquery('simple', q) OR
      us.username @@ to_tsquery('simple', q) OR
      us.display_name @@ to_tsquery('simple', q) OR
      us."displayName" @@ to_tsquery('simple', q) OR
      us.nip05 @@ to_tsquery('simple', q) OR
      us.lud16 @@ to_tsquery('simple', q)
    ) AND
    us.pubkey = pfc.key AND
    NOT EXISTS (SELECT 1 FROM filterlist WHERE grp IN ('csam', 'impersonation') AND target_type = 'pubkey' AND target = us.pubkey AND blocked LIMIT 1)
  ORDER BY pfc.value DESC
  LIMIT a_limit;
END;
$$;


--
-- Name: wsconntasks(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.wsconntasks(a_port bigint DEFAULT 14001) RETURNS TABLE(tokio_task bigint, task bigint, trace character varying)
    LANGUAGE sql STABLE
    AS $$
SELECT * FROM dblink(format('host=127.0.0.1 port=%s', a_port), 'select * from tasks;') AS t(tokio_task int8, task int8, trace varchar)
$$;


--
-- Name: zap_response(record, bytea); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.zap_response(r record, a_user_pubkey bytea) RETURNS SETOF jsonb
    LANGUAGE plpgsql STABLE
    AS $$	
DECLARE
    pk bytea;
    pubkeys bytea[] := '{}';
BEGIN
    IF (a_user_pubkey IS NOT null AND is_pubkey_hidden(a_user_pubkey, 'content', r.sender)) OR
        is_pubkey_hidden(r.receiver, 'content', r.sender) 
    THEN
        RETURN;
    END IF;

    FOR pk IN VALUES (r.sender), (r.receiver) LOOP
        RETURN NEXT get_event_jsonb(meta_data.value) FROM meta_data WHERE pk = meta_data.key;
        pubkeys := array_append(pubkeys, pk);
    END LOOP;

    RETURN NEXT get_event_jsonb(r.zap_receipt_id);

    RETURN NEXT jsonb_build_object(
        'kind', c_ZAP_EVENT(),
        'content', json_build_object( 
            'event_id', ENCODE(r.event_id, 'hex'), 
            'created_at', r.created_at, 
            'sender', ENCODE(r.sender, 'hex'),
            'receiver', ENCODE(r.receiver, 'hex'),
            'amount_sats', r.amount_sats,
            'zap_receipt_id', ENCODE(r.zap_receipt_id, 'hex'))::text);

    IF pubkeys != '{}' THEN
        RETURN QUERY SELECT * FROM primal_verified_names(pubkeys);
        RETURN QUERY SELECT * FROM user_blossom_servers(pubkeys);
    END IF;
END $$;


--
-- Name: a_tags_1_7d98c5333f; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.a_tags_1_7d98c5333f (
    i bigint NOT NULL,
    eid bytea NOT NULL,
    kind bigint NOT NULL,
    created_at bigint NOT NULL,
    ref_kind bigint NOT NULL,
    ref_pubkey bytea NOT NULL,
    ref_identifier character varying NOT NULL,
    ref_arg4 character varying NOT NULL,
    imported_at bigint NOT NULL
);


--
-- Name: a_tags; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.a_tags AS
 SELECT i,
    eid,
    kind,
    created_at,
    ref_kind,
    ref_pubkey,
    ref_identifier,
    ref_arg4,
    imported_at
   FROM public.a_tags_1_7d98c5333f;


--
-- Name: a_tags_1_7d98c5333f_i_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.a_tags_1_7d98c5333f_i_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: a_tags_1_7d98c5333f_i_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.a_tags_1_7d98c5333f_i_seq OWNED BY public.a_tags_1_7d98c5333f.i;


--
-- Name: advsearch_5_d7da6f551e; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.advsearch_5_d7da6f551e (
    i bigint NOT NULL,
    id bytea,
    pubkey bytea NOT NULL,
    created_at bigint NOT NULL,
    kind bigint NOT NULL,
    content_tsv tsvector NOT NULL,
    hashtag_tsv tsvector NOT NULL,
    reply_tsv tsvector NOT NULL,
    mention_tsv tsvector NOT NULL,
    filter_tsv tsvector NOT NULL,
    url_tsv tsvector NOT NULL
)
WITH (autovacuum_analyze_scale_factor='0.01');
ALTER TABLE ONLY public.advsearch_5_d7da6f551e ALTER COLUMN content_tsv SET STATISTICS 10000;
ALTER TABLE ONLY public.advsearch_5_d7da6f551e ALTER COLUMN hashtag_tsv SET STATISTICS 10000;


--
-- Name: advsearch; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.advsearch AS
 SELECT i,
    id,
    pubkey,
    created_at,
    kind,
    content_tsv,
    hashtag_tsv,
    reply_tsv,
    mention_tsv,
    filter_tsv,
    url_tsv
   FROM public.advsearch_5_d7da6f551e;


--
-- Name: advsearch_5_d7da6f551e_i_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.advsearch_5_d7da6f551e_i_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: advsearch_5_d7da6f551e_i_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.advsearch_5_d7da6f551e_i_seq OWNED BY public.advsearch_5_d7da6f551e.i;


--
-- Name: parametrized_replaceable_events; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.parametrized_replaceable_events AS
 SELECT pubkey,
    kind,
    public.event_d_tag(tags) AS identifier,
    id AS event_id,
    created_at,
    (0)::bigint AS rowid
   FROM public.event e
  WHERE ((kind >= 30000) AND (kind <= 39999) AND (public.event_d_tag(tags) IS NOT NULL) AND (id = ( SELECT n.id
           FROM public.event n
          WHERE ((n.kind >= 30000) AND (n.kind <= 39999) AND (n.kind = e.kind) AND (n.pubkey = e.pubkey) AND ((public.event_d_tag(n.tags))::text = (public.event_d_tag(e.tags))::text) AND (n.created_at = ( SELECT max(m.created_at) AS max
                   FROM public.event m
                  WHERE ((m.kind >= 30000) AND (m.kind <= 39999) AND (m.kind = e.kind) AND (m.pubkey = e.pubkey) AND ((public.event_d_tag(m.tags))::text = (public.event_d_tag(e.tags))::text)))))
          ORDER BY n.id
         LIMIT 1)));


--
-- Name: allow_list; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.allow_list AS
 SELECT pubkey AS key,
    event_id AS value,
    (0)::bigint AS rowid
   FROM public.parametrized_replaceable_events
  WHERE ((kind = 30000) AND ((identifier)::text = 'allowlist'::text));


--
-- Name: basic_tags_6_62c3d17c2f; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.basic_tags_6_62c3d17c2f (
    i bigint NOT NULL,
    id bytea NOT NULL,
    pubkey bytea NOT NULL,
    created_at bigint NOT NULL,
    kind bigint NOT NULL,
    tag character(1) NOT NULL,
    arg1 bytea NOT NULL,
    arg3 character varying NOT NULL,
    imported_at bigint NOT NULL
);


--
-- Name: basic_tags; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.basic_tags AS
 SELECT i,
    id,
    pubkey,
    created_at,
    kind,
    tag,
    arg1,
    arg3,
    imported_at
   FROM public.basic_tags_6_62c3d17c2f;


--
-- Name: basic_tags_6_62c3d17c2f_i_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.basic_tags_6_62c3d17c2f_i_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: basic_tags_6_62c3d17c2f_i_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.basic_tags_6_62c3d17c2f_i_seq OWNED BY public.basic_tags_6_62c3d17c2f.i;


--
-- Name: bookmarks; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.bookmarks AS
 SELECT pubkey,
    id AS event_id,
    (0)::bigint AS rowid
   FROM public.event e
  WHERE ((kind = 10003) AND (id = ( SELECT n.id
           FROM public.event n
          WHERE ((n.pubkey = e.pubkey) AND (n.kind = 10003) AND (n.created_at = ( SELECT max(m.created_at) AS max
                   FROM public.event m
                  WHERE ((m.pubkey = e.pubkey) AND (m.kind = 10003)))))
          ORDER BY n.id
         LIMIT 1)));


--
-- Name: cache; Type: TABLE; Schema: public; Owner: -
--

CREATE UNLOGGED TABLE public.cache (
    key text NOT NULL,
    value jsonb NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: cmr_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cmr_groups (
    user_pubkey bytea,
    grp public.cmr_grp NOT NULL,
    scope public.cmr_scope NOT NULL
);


--
-- Name: cmr_hashtags_2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cmr_hashtags_2 (
    user_pubkey bytea NOT NULL,
    scope public.cmr_scope NOT NULL,
    hashtags tsquery NOT NULL
);


--
-- Name: cmr_pubkeys_allowed; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cmr_pubkeys_allowed (
    user_pubkey bytea,
    pubkey bytea NOT NULL
);


--
-- Name: cmr_pubkeys_scopes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cmr_pubkeys_scopes (
    user_pubkey bytea,
    pubkey bytea NOT NULL,
    scope public.cmr_scope NOT NULL
);


--
-- Name: cmr_threads; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cmr_threads (
    user_pubkey bytea NOT NULL,
    event_id bytea NOT NULL,
    scope public.cmr_scope NOT NULL
);


--
-- Name: cmr_words_2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cmr_words_2 (
    user_pubkey bytea NOT NULL,
    scope public.cmr_scope NOT NULL,
    words tsquery NOT NULL
);


--
-- Name: contact_lists; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.contact_lists AS
 SELECT pubkey AS key,
    id AS value,
    (0)::bigint AS rowid
   FROM public.event e
  WHERE ((kind = 3) AND (id = ( SELECT n.id
           FROM public.event n
          WHERE ((n.pubkey = e.pubkey) AND (n.kind = 3) AND (n.created_at = ( SELECT max(m.created_at) AS max
                   FROM public.event m
                  WHERE ((m.pubkey = e.pubkey) AND (m.kind = 3)))))
          ORDER BY n.id
         LIMIT 1)));


--
-- Name: coverages_1_8656fc443b; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.coverages_1_8656fc443b (
    name character varying NOT NULL,
    t bigint NOT NULL,
    t2 bigint NOT NULL
)
WITH (fillfactor='80');


--
-- Name: daily_followers_cnt_increases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_followers_cnt_increases (
    pubkey bytea NOT NULL,
    cnt bigint NOT NULL,
    increase bigint NOT NULL,
    ratio real NOT NULL
);


--
-- Name: deleted_events_1_0249f47b16; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.deleted_events_1_0249f47b16 (
    event_id bytea NOT NULL,
    deletion_event_id bytea NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: deleted_events; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.deleted_events AS
 SELECT event_id,
    deletion_event_id,
    rowid
   FROM public.deleted_events_1_0249f47b16;


--
-- Name: dvm_feeds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dvm_feeds (
    pubkey bytea NOT NULL,
    identifier character varying NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    results jsonb,
    kind character varying NOT NULL,
    personalized boolean NOT NULL,
    ok boolean NOT NULL
);


--
-- Name: event_hashtags_1_295f217c0e; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_hashtags_1_295f217c0e (
    event_id bytea NOT NULL,
    hashtag character varying NOT NULL,
    created_at bigint NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: event_hashtags; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_hashtags AS
 SELECT event_id,
    hashtag,
    created_at,
    rowid
   FROM public.event_hashtags_1_295f217c0e;


--
-- Name: event_hls_media; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_hls_media (
    event_id bytea NOT NULL,
    url character varying NOT NULL,
    media_url character varying NOT NULL,
    provider character varying NOT NULL,
    hls_url character varying NOT NULL,
    created_at bigint NOT NULL,
    extra jsonb
);


--
-- Name: event_hooks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_hooks (
    event_id bytea NOT NULL,
    funcall text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: event_media_1_30bf07e9cf; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_media_1_30bf07e9cf (
    event_id bytea NOT NULL,
    url character varying NOT NULL,
    rowid bigint DEFAULT 0
)
WITH (autovacuum_analyze_scale_factor='0.01');


--
-- Name: event_media; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_media AS
 SELECT event_id,
    url,
    rowid
   FROM public.event_media_1_30bf07e9cf;


--
-- Name: event_mentions_1_a056fb6737; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_mentions_1_a056fb6737 (
    eid bytea NOT NULL,
    tag character(1) NOT NULL,
    argeid bytea,
    argpubkey bytea,
    argkind bigint,
    argid character varying
);


--
-- Name: event_mentions; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_mentions AS
 SELECT eid,
    tag,
    argeid,
    argpubkey,
    argkind,
    argid
   FROM public.event_mentions_1_a056fb6737;


--
-- Name: event_preview_1_310cef356e; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_preview_1_310cef356e (
    event_id bytea NOT NULL,
    url character varying NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: event_preview; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_preview AS
 SELECT event_id,
    url,
    rowid
   FROM public.event_preview_1_310cef356e;


--
-- Name: event_replies_1_9d033b5bb3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_replies_1_9d033b5bb3 (
    event_id bytea NOT NULL,
    reply_event_id bytea NOT NULL,
    reply_created_at bigint NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: zap_receipts_1_9fe40119b2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.zap_receipts_1_9fe40119b2 (
    eid bytea NOT NULL,
    created_at bigint NOT NULL,
    target_eid bytea,
    sender bytea,
    receiver bytea NOT NULL,
    satszapped bigint,
    imported_at bigint NOT NULL,
    og_sender bytea,
    og_amount_sats bigint,
    og_event_id bytea
);


--
-- Name: og_zap_receipts; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.og_zap_receipts AS
 SELECT eid AS zap_receipt_id,
    created_at,
    og_sender AS sender,
    receiver,
    og_amount_sats AS amount_sats,
    og_event_id AS event_id,
    (0)::bigint AS rowid
   FROM public.zap_receipts_1_9fe40119b2
  WHERE (og_amount_sats IS NOT NULL);


--
-- Name: event_pubkey_action_refs; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_pubkey_action_refs AS
 SELECT bt.arg1 AS event_id,
    bt.id AS ref_event_id,
    bt.pubkey AS ref_pubkey,
    bt.created_at AS ref_created_at,
    bt.kind AS ref_kind,
    (0)::bigint AS rowid
   FROM public.basic_tags_6_62c3d17c2f bt
  WHERE ((bt.tag = 'e'::bpchar) AND (bt.kind = 6))
UNION ALL
 SELECT bt.arg1 AS event_id,
    bt.id AS ref_event_id,
    bt.pubkey AS ref_pubkey,
    bt.created_at AS ref_created_at,
    bt.kind AS ref_kind,
    (0)::bigint AS rowid
   FROM (public.basic_tags_6_62c3d17c2f bt
     JOIN public.event ev ON ((ev.id = bt.id)))
  WHERE ((bt.tag = 'e'::bpchar) AND (bt.kind = 7) AND ((ev.content = ''::text) OR ("left"(ev.content, 1) = ANY (ARRAY['+'::text, chr(129305), chr(10084), chr(65039)]))))
UNION ALL
 SELECT DISTINCT bt.arg1 AS event_id,
    bt.id AS ref_event_id,
    bt.pubkey AS ref_pubkey,
    bt.created_at AS ref_created_at,
    bt.kind AS ref_kind,
    (0)::bigint AS rowid
   FROM public.basic_tags_6_62c3d17c2f bt
  WHERE ((bt.tag = 'e'::bpchar) AND (bt.kind = ANY (ARRAY[(1)::bigint, (20)::bigint, (1068)::bigint, (6969)::bigint, (1111)::bigint])) AND (EXISTS ( SELECT 1
           FROM public.event_replies_1_9d033b5bb3 er
          WHERE ((er.reply_event_id = bt.id) AND (er.event_id = bt.arg1)))))
UNION ALL
 SELECT z.event_id,
    z.zap_receipt_id AS ref_event_id,
    z.sender AS ref_pubkey,
    z.created_at AS ref_created_at,
    (9735)::bigint AS ref_kind,
    (0)::bigint AS rowid
   FROM public.og_zap_receipts z;


--
-- Name: event_pubkey_actions; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_pubkey_actions AS
 SELECT event_id,
    ref_pubkey AS pubkey,
    min(ref_created_at) AS created_at,
    max(ref_created_at) AS updated_at,
    (max(
        CASE
            WHEN (ref_kind = ANY (ARRAY[(1)::bigint, (20)::bigint, (1068)::bigint, (6969)::bigint, (1111)::bigint])) THEN 1
            ELSE 0
        END))::bigint AS replied,
    (max(
        CASE
            WHEN (ref_kind = 7) THEN 1
            ELSE 0
        END))::bigint AS liked,
    (max(
        CASE
            WHEN (ref_kind = 6) THEN 1
            ELSE 0
        END))::bigint AS reposted,
    (max(
        CASE
            WHEN (ref_kind = 9735) THEN 1
            ELSE 0
        END))::bigint AS zapped,
    (0)::bigint AS rowid
   FROM public.event_pubkey_action_refs
  GROUP BY event_id, ref_pubkey;


--
-- Name: event_replies; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_replies AS
 SELECT event_id,
    reply_event_id,
    reply_created_at,
    rowid
   FROM public.event_replies_1_9d033b5bb3;


--
-- Name: event_stats_1_1b380f4869; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.event_stats_1_1b380f4869 (
    event_id bytea NOT NULL,
    author_pubkey bytea NOT NULL,
    created_at bigint NOT NULL,
    likes bigint NOT NULL,
    replies bigint NOT NULL,
    mentions bigint NOT NULL,
    reposts bigint NOT NULL,
    zaps bigint NOT NULL,
    satszapped bigint NOT NULL,
    score bigint NOT NULL,
    score24h bigint NOT NULL,
    rowid bigint DEFAULT 0
)
WITH (fillfactor='90', autovacuum_vacuum_scale_factor='0.01', autovacuum_vacuum_insert_scale_factor='0.01');


--
-- Name: event_stats; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_stats AS
 SELECT event_id,
    author_pubkey,
    created_at,
    likes,
    replies,
    mentions,
    reposts,
    zaps,
    satszapped,
    score,
    score24h,
    rowid
   FROM public.event_stats_1_1b380f4869;


--
-- Name: event_tags; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_tags AS
 SELECT id,
    pubkey,
    kind,
    created_at,
    (jsonb_array_elements(tags) ->> 0) AS tag,
    (jsonb_array_elements(tags) ->> 1) AS arg1
   FROM public.event;


--
-- Name: event_thread_parents; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.event_thread_parents AS
 SELECT reply_event_id AS key,
    event_id AS value,
    (0)::bigint AS rowid
   FROM public.event_replies_1_9d033b5bb3;


--
-- Name: events; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.events AS
 SELECT id,
    pubkey,
    created_at,
    kind,
    tags,
    content,
    sig,
    imported_at
   FROM public.event;


--
-- Name: fetcher_relays; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fetcher_relays (
    relay_url character varying NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    source_event_id bytea
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
-- Name: id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: follow_lists; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.follow_lists (
    id bigint DEFAULT nextval('public.id_seq'::regclass) NOT NULL,
    pubkey bytea NOT NULL,
    identifier character varying NOT NULL,
    follow_pubkey bytea NOT NULL
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
-- Name: lists; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lists (
    list character varying(200) NOT NULL,
    pubkey bytea NOT NULL,
    added_at integer NOT NULL
);


--
-- Name: live_event_notification_created; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.live_event_notification_created (
    kind bigint NOT NULL,
    pubkey bytea NOT NULL,
    identifier character varying NOT NULL,
    follower_pubkey bytea NOT NULL,
    created_at bigint NOT NULL
);


--
-- Name: live_event_participants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.live_event_participants (
    kind bigint NOT NULL,
    pubkey bytea NOT NULL,
    identifier character varying NOT NULL,
    participant_pubkey bytea NOT NULL,
    event_id bytea NOT NULL,
    created_at bigint NOT NULL
);


--
-- Name: live_event_pubkey_filterlist; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.live_event_pubkey_filterlist (
    user_pubkey bytea NOT NULL,
    blocked_pubkey bytea NOT NULL,
    event_id bytea NOT NULL,
    created_at bigint NOT NULL
);


--
-- Name: media_1_16fa35f2dc; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.media_1_16fa35f2dc (
    url character varying NOT NULL,
    media_url character varying NOT NULL,
    size character varying NOT NULL,
    animated bigint NOT NULL,
    imported_at bigint NOT NULL,
    download_duration double precision NOT NULL,
    width bigint NOT NULL,
    height bigint NOT NULL,
    mimetype character varying NOT NULL,
    category character varying NOT NULL,
    category_confidence double precision NOT NULL,
    duration double precision NOT NULL,
    rowid bigint DEFAULT 0,
    orig_sha256 bytea
)
WITH (autovacuum_analyze_scale_factor='0.01');

ALTER TABLE ONLY public.media_1_16fa35f2dc REPLICA IDENTITY FULL;


--
-- Name: media; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.media AS
 SELECT url,
    media_url,
    size,
    animated,
    imported_at,
    download_duration,
    width,
    height,
    mimetype,
    category,
    category_confidence,
    duration,
    rowid,
    orig_sha256
   FROM public.media_1_16fa35f2dc;


--
-- Name: media_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.media_metadata (
    sha256 bytea NOT NULL,
    model character varying NOT NULL,
    md jsonb NOT NULL,
    t timestamp without time zone NOT NULL,
    sha256_ bytea
);


--
-- Name: media_storage; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.media_storage (
    media_url character varying NOT NULL,
    storage_provider character varying NOT NULL,
    added_at bigint NOT NULL,
    key character varying NOT NULL,
    h character varying NOT NULL,
    ext character varying NOT NULL,
    content_type character varying NOT NULL,
    size bigint NOT NULL,
    sha256 bytea,
    media_block_id uuid
)
WITH (autovacuum_analyze_scale_factor='0.01');


--
-- Name: media_storage_priority; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.media_storage_priority (
    storage_provider character varying NOT NULL,
    priority integer NOT NULL
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


--
-- Name: meta_data; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.meta_data AS
 SELECT pubkey AS key,
    id AS value,
    (0)::bigint AS rowid
   FROM public.event e
  WHERE ((kind = 0) AND (id = ( SELECT n.id
           FROM public.event n
          WHERE ((n.pubkey = e.pubkey) AND (n.kind = 0) AND (n.created_at = ( SELECT max(m.created_at) AS max
                   FROM public.event m
                  WHERE ((m.pubkey = e.pubkey) AND (m.kind = 0)))))
          ORDER BY n.id
         LIMIT 1)));


--
-- Name: mute_list; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.mute_list AS
 SELECT pubkey AS key,
    id AS value,
    (0)::bigint AS rowid
   FROM public.event e
  WHERE ((kind = 10000) AND (id = ( SELECT n.id
           FROM public.event n
          WHERE ((n.pubkey = e.pubkey) AND (n.kind = 10000) AND (n.created_at = ( SELECT max(m.created_at) AS max
                   FROM public.event m
                  WHERE ((m.pubkey = e.pubkey) AND (m.kind = 10000)))))
          ORDER BY n.id
         LIMIT 1)));


--
-- Name: mute_list_2; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.mute_list_2 AS
 SELECT pubkey AS key,
    event_id AS value,
    (0)::bigint AS rowid
   FROM public.parametrized_replaceable_events
  WHERE ((kind = 30000) AND ((identifier)::text = 'mute'::text));


--
-- Name: mute_lists; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.mute_lists AS
 SELECT pubkey AS key,
    event_id AS value,
    (0)::bigint AS rowid
   FROM public.parametrized_replaceable_events
  WHERE ((kind = 30000) AND ((identifier)::text = 'mutelists'::text));


--
-- Name: note_length; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.note_length AS
 SELECT id AS eid,
    (length(content))::bigint AS length
   FROM public.event e
  WHERE (kind = ANY (ARRAY[(1)::bigint, (6)::bigint, (30023)::bigint]));


--
-- Name: note_stats_1_07d205f278; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.note_stats_1_07d205f278 (
    eid bytea NOT NULL,
    long_replies bigint NOT NULL
);


--
-- Name: note_stats; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.note_stats AS
 SELECT eid,
    long_replies
   FROM public.note_stats_1_07d205f278;


--
-- Name: notification_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_types (
    type integer NOT NULL,
    name character varying NOT NULL
);


--
-- Name: parameterized_replaceable_list; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.parameterized_replaceable_list AS
 SELECT pubkey,
    identifier,
    created_at,
    event_id,
    (0)::bigint AS rowid
   FROM public.parametrized_replaceable_events
  WHERE ((kind = 30000) AND ((identifier)::text <> ALL (ARRAY[('mute'::character varying)::text, ('mutelists'::character varying)::text, ('allowlist'::character varying)::text])));


--
-- Name: poll_stats_1_d8de047040; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.poll_stats_1_d8de047040 (
    event_id bytea NOT NULL,
    options jsonb NOT NULL,
    updated_at bigint NOT NULL
);


--
-- Name: poll_stats; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.poll_stats AS
 SELECT event_id,
    options,
    updated_at
   FROM public.poll_stats_1_d8de047040;


--
-- Name: poll_user_votes_1_5fa4d82e64; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.poll_user_votes_1_5fa4d82e64 (
    poll_id bytea NOT NULL,
    pubkey bytea NOT NULL,
    option_id character varying NOT NULL,
    created_at bigint NOT NULL,
    vote_eid bytea NOT NULL
);


--
-- Name: poll_user_votes; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.poll_user_votes AS
 SELECT poll_id,
    pubkey,
    option_id,
    created_at,
    vote_eid
   FROM public.poll_user_votes_1_5fa4d82e64;


--
-- Name: preview_1_44299731c7; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.preview_1_44299731c7 (
    url character varying NOT NULL,
    imported_at bigint NOT NULL,
    download_duration double precision NOT NULL,
    mimetype character varying NOT NULL,
    category character varying NOT NULL,
    category_confidence double precision NOT NULL,
    md_title character varying NOT NULL,
    md_description character varying NOT NULL,
    md_image character varying NOT NULL,
    icon_url character varying NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: preview; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.preview AS
 SELECT url,
    imported_at,
    download_duration,
    mimetype,
    category,
    category_confidence,
    md_title,
    md_description,
    md_image,
    icon_url,
    rowid
   FROM public.preview_1_44299731c7;


--
-- Name: pubkey_bookmarks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pubkey_bookmarks (
    pubkey bytea NOT NULL,
    ref_event_id bytea,
    ref_kind bytea,
    ref_pubkey bytea,
    ref_identifier bytea
);


--
-- Name: pubkey_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pubkey_stats (
    pubkey bytea NOT NULL,
    followers bigint DEFAULT 0 NOT NULL,
    zaps bigint DEFAULT 0 NOT NULL,
    satszapped bigint DEFAULT 0 NOT NULL,
    media_cnt bigint DEFAULT 0 NOT NULL,
    content_zap_cnt bigint DEFAULT 0 NOT NULL
)
WITH (fillfactor='80');


--
-- Name: pubkey_content_zap_cnt; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_content_zap_cnt AS
 SELECT pubkey,
    content_zap_cnt AS cnt
   FROM public.pubkey_stats
  WHERE (content_zap_cnt <> 0);


--
-- Name: pubkey_directmsgs_1_c794110a2c; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pubkey_directmsgs_1_c794110a2c (
    receiver bytea NOT NULL,
    sender bytea NOT NULL,
    created_at bigint NOT NULL,
    event_id bytea NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: pubkey_directmsgs; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_directmsgs AS
 SELECT receiver,
    sender,
    created_at,
    event_id,
    rowid
   FROM public.pubkey_directmsgs_1_c794110a2c;


--
-- Name: pubkey_directmsgs_cnt_1_efdf9742a6; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pubkey_directmsgs_cnt_1_efdf9742a6 (
    receiver bytea NOT NULL,
    sender bytea,
    cnt bigint NOT NULL,
    latest_at bigint NOT NULL,
    latest_event_id bytea NOT NULL,
    rowid bigint DEFAULT 0
)
WITH (fillfactor='80');


--
-- Name: pubkey_directmsgs_cnt; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_directmsgs_cnt AS
 SELECT receiver,
    sender,
    cnt,
    latest_at,
    latest_event_id,
    rowid
   FROM public.pubkey_directmsgs_cnt_1_efdf9742a6;


--
-- Name: pubkey_events_1_1dcbfe1466; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pubkey_events_1_1dcbfe1466 (
    pubkey bytea NOT NULL,
    event_id bytea NOT NULL,
    created_at bigint NOT NULL,
    is_reply bigint NOT NULL,
    rowid bigint DEFAULT 0,
    kind bigint
)
WITH (autovacuum_vacuum_scale_factor='0.01', autovacuum_vacuum_insert_scale_factor='0.01');


--
-- Name: pubkey_events; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_events AS
 SELECT pubkey,
    event_id,
    created_at,
    is_reply,
    rowid,
    kind
   FROM public.pubkey_events_1_1dcbfe1466;


--
-- Name: pubkey_followers_1_d52305fb47; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pubkey_followers_1_d52305fb47 (
    pubkey bytea NOT NULL,
    follower_pubkey bytea NOT NULL,
    follower_contact_list_event_id bytea NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: pubkey_followers; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_followers AS
 SELECT pubkey,
    follower_pubkey,
    follower_contact_list_event_id,
    rowid
   FROM public.pubkey_followers_1_d52305fb47;


--
-- Name: pubkey_followers_cnt; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_followers_cnt AS
 SELECT pubkey AS key,
    followers AS value,
    (0)::bigint AS rowid
   FROM public.pubkey_stats
  WHERE (followers <> 0);


--
-- Name: pubkey_ln_address; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_ln_address AS
 SELECT pubkey,
    public.event_lud16(content) AS ln_address,
    (0)::bigint AS rowid
   FROM public.event e
  WHERE ((kind = 0) AND (public.event_lud16(content) IS NOT NULL) AND (id = ( SELECT n.id
           FROM public.event n
          WHERE ((n.pubkey = e.pubkey) AND (n.kind = 0) AND (n.created_at = ( SELECT max(m.created_at) AS max
                   FROM public.event m
                  WHERE ((m.pubkey = e.pubkey) AND (m.kind = 0)))))
          ORDER BY n.id
         LIMIT 1)));


--
-- Name: pubkey_media_cnt; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_media_cnt AS
 SELECT pubkey,
    media_cnt AS cnt
   FROM public.pubkey_stats
  WHERE (media_cnt <> 0);


--
-- Name: pubkey_notification_cnts_1_d78f6fcade; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pubkey_notification_cnts_1_d78f6fcade (
    pubkey bytea NOT NULL,
    type1 bigint DEFAULT 0,
    type2 bigint DEFAULT 0,
    type3 bigint DEFAULT 0,
    type4 bigint DEFAULT 0,
    type5 bigint DEFAULT 0,
    type6 bigint DEFAULT 0,
    type7 bigint DEFAULT 0,
    type8 bigint DEFAULT 0,
    type101 bigint DEFAULT 0,
    type102 bigint DEFAULT 0,
    type103 bigint DEFAULT 0,
    type104 bigint DEFAULT 0,
    type201 bigint DEFAULT 0,
    type202 bigint DEFAULT 0,
    type203 bigint DEFAULT 0,
    type204 bigint DEFAULT 0,
    rowid bigint DEFAULT 0,
    type301 integer DEFAULT 0 NOT NULL,
    type302 integer DEFAULT 0 NOT NULL,
    type303 integer DEFAULT 0 NOT NULL,
    type401 integer DEFAULT 0 NOT NULL,
    type501 integer DEFAULT 0 NOT NULL,
    type601 integer DEFAULT 0 NOT NULL
)
WITH (fillfactor='80');


--
-- Name: pubkey_notification_cnts; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_notification_cnts AS
 SELECT pubkey,
    type1,
    type2,
    type3,
    type4,
    type5,
    type6,
    type7,
    type8,
    type101,
    type102,
    type103,
    type104,
    type201,
    type202,
    type203,
    type204,
    rowid,
    type301,
    type302,
    type303,
    type401,
    type501,
    type601
   FROM public.pubkey_notification_cnts_1_d78f6fcade;


--
-- Name: pubkey_notifications_1_e5459ab9dd; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pubkey_notifications_1_e5459ab9dd (
    pubkey bytea NOT NULL,
    created_at bigint NOT NULL,
    type bigint NOT NULL,
    arg1 bytea NOT NULL,
    arg2 bytea,
    arg3 jsonb,
    arg4 jsonb,
    rowid bigint DEFAULT 0
);


--
-- Name: pubkey_notifications; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_notifications AS
 SELECT pubkey,
    created_at,
    type,
    arg1,
    arg2,
    arg3,
    arg4,
    rowid
   FROM public.pubkey_notifications_1_e5459ab9dd;


--
-- Name: pubkey_trustrank; Type: TABLE; Schema: public; Owner: -
--

CREATE UNLOGGED TABLE public.pubkey_trustrank (
    pubkey bytea NOT NULL,
    rank double precision NOT NULL
);


--
-- Name: pubkey_zapped; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.pubkey_zapped AS
 SELECT pubkey,
    zaps,
    satszapped,
    (0)::bigint AS rowid
   FROM public.pubkey_stats
  WHERE ((zaps <> 0) OR (satszapped <> 0));


--
-- Name: reads_12_68c6bbfccd; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reads_12_68c6bbfccd (
    pubkey bytea NOT NULL,
    identifier character varying NOT NULL,
    published_at bigint NOT NULL,
    latest_eid bytea NOT NULL,
    latest_created_at bigint NOT NULL,
    likes bigint NOT NULL,
    zaps bigint NOT NULL,
    satszapped bigint NOT NULL,
    replies bigint NOT NULL,
    reposts bigint NOT NULL,
    topics tsvector NOT NULL,
    words bigint NOT NULL,
    lang character varying NOT NULL,
    lang_prob double precision NOT NULL,
    image character varying NOT NULL,
    summary character varying NOT NULL
);


--
-- Name: reads; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.reads AS
 SELECT pubkey,
    identifier,
    published_at,
    latest_eid,
    latest_created_at,
    likes,
    zaps,
    satszapped,
    replies,
    reposts,
    topics,
    words,
    lang,
    lang_prob,
    image,
    summary
   FROM public.reads_12_68c6bbfccd;


--
-- Name: reads_interactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reads_interactions (
    pubkey bytea NOT NULL,
    eid bytea NOT NULL
);


--
-- Name: reads_interactions_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reads_interactions_state (
    id integer DEFAULT 1 NOT NULL,
    listed boolean DEFAULT false NOT NULL,
    ready boolean DEFAULT false NOT NULL,
    CONSTRAINT reads_interactions_state_id_check CHECK ((id = 1))
);


--
-- Name: reads_versions; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.reads_versions AS
 SELECT pubkey,
    public.event_d_tag(tags) AS identifier,
    id AS eid
   FROM public.event e
  WHERE ((kind >= 30000) AND (kind <= 39999) AND (kind = 30023) AND (public.event_d_tag(tags) IS NOT NULL));


--
-- Name: relay_list_metadata; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.relay_list_metadata AS
 SELECT pubkey,
    id AS event_id,
    (0)::bigint AS rowid
   FROM public.event e
  WHERE ((kind = 10002) AND (id = ( SELECT n.id
           FROM public.event n
          WHERE ((n.pubkey = e.pubkey) AND (n.kind = 10002) AND (n.created_at = ( SELECT max(m.created_at) AS max
                   FROM public.event m
                  WHERE ((m.pubkey = e.pubkey) AND (m.kind = 10002)))))
          ORDER BY n.id
         LIMIT 1)));


--
-- Name: relay_url_map; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.relay_url_map (
    src character varying NOT NULL,
    dest character varying NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version text NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL,
    applied_by text,
    checksum text,
    duration_ms integer
);


--
-- Name: score_expiry; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.score_expiry (
    event_id bytea NOT NULL,
    author_pubkey bytea NOT NULL,
    change bigint NOT NULL,
    expire_at bigint NOT NULL
);


--
-- Name: spam_note_content_hash; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.spam_note_content_hash (
    content_sha256 bytea NOT NULL,
    added_at bigint NOT NULL
);


--
-- Name: text_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.text_metadata (
    sha256 bytea NOT NULL,
    model character varying NOT NULL,
    md jsonb NOT NULL,
    t timestamp without time zone NOT NULL,
    text character varying,
    event_id bytea
);


--
-- Name: trusted_pubkey_followers_cnt; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.trusted_pubkey_followers_cnt (
    t timestamp without time zone NOT NULL,
    pubkey bytea NOT NULL,
    cnt bigint NOT NULL
);


--
-- Name: user_search; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_search (
    pubkey bytea NOT NULL,
    event_id bytea NOT NULL,
    name tsvector,
    username tsvector,
    display_name tsvector,
    displayname tsvector,
    nip05 tsvector,
    lud16 tsvector
);


--
-- Name: vars; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vars (
    key character varying NOT NULL,
    value jsonb NOT NULL,
    updated_at timestamp without time zone NOT NULL
);


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
-- Name: video_thumbnails_1_107d5a46eb; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.video_thumbnails_1_107d5a46eb (
    video_url character varying NOT NULL,
    thumbnail_url character varying NOT NULL,
    rowid bigint DEFAULT 0
);


--
-- Name: video_thumbnails; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.video_thumbnails AS
 SELECT video_url,
    thumbnail_url,
    rowid
   FROM public.video_thumbnails_1_107d5a46eb;


--
-- Name: wsconnvars; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wsconnvars (
    name character varying NOT NULL,
    value jsonb NOT NULL
);


--
-- Name: zap_receipt_invoices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.zap_receipt_invoices (
    zap_receipt_eid bytea NOT NULL,
    invoice character varying NOT NULL
);


--
-- Name: zap_receipts; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.zap_receipts AS
 SELECT eid,
    created_at,
    target_eid,
    sender,
    receiver,
    satszapped,
    imported_at
   FROM public.zap_receipts_1_9fe40119b2
  WHERE (sender IS NOT NULL);


--
-- Name: a_tags_1_7d98c5333f i; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.a_tags_1_7d98c5333f ALTER COLUMN i SET DEFAULT nextval('public.a_tags_1_7d98c5333f_i_seq'::regclass);


--
-- Name: advsearch_5_d7da6f551e i; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.advsearch_5_d7da6f551e ALTER COLUMN i SET DEFAULT nextval('public.advsearch_5_d7da6f551e_i_seq'::regclass);


--
-- Name: basic_tags_6_62c3d17c2f i; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.basic_tags_6_62c3d17c2f ALTER COLUMN i SET DEFAULT nextval('public.basic_tags_6_62c3d17c2f_i_seq'::regclass);


--
-- Name: a_tags_1_7d98c5333f a_tags_1_7d98c5333f_eid_ref_kind_ref_pubkey_ref_identifier__key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.a_tags_1_7d98c5333f
    ADD CONSTRAINT a_tags_1_7d98c5333f_eid_ref_kind_ref_pubkey_ref_identifier__key UNIQUE (eid, ref_kind, ref_pubkey, ref_identifier, ref_arg4);


--
-- Name: a_tags_1_7d98c5333f a_tags_1_7d98c5333f_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.a_tags_1_7d98c5333f
    ADD CONSTRAINT a_tags_1_7d98c5333f_pkey PRIMARY KEY (i);


--
-- Name: advsearch_5_d7da6f551e advsearch_5_d7da6f551e_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.advsearch_5_d7da6f551e
    ADD CONSTRAINT advsearch_5_d7da6f551e_id_key UNIQUE (id);


--
-- Name: advsearch_5_d7da6f551e advsearch_5_d7da6f551e_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.advsearch_5_d7da6f551e
    ADD CONSTRAINT advsearch_5_d7da6f551e_pkey PRIMARY KEY (i);


--
-- Name: cache cache_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cache
    ADD CONSTRAINT cache_pkey PRIMARY KEY (key);


--
-- Name: cmr_hashtags_2 cmr_hashtags_2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cmr_hashtags_2
    ADD CONSTRAINT cmr_hashtags_2_pkey PRIMARY KEY (user_pubkey, scope);


--
-- Name: cmr_threads cmr_threads_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cmr_threads
    ADD CONSTRAINT cmr_threads_pkey PRIMARY KEY (user_pubkey, event_id, scope);


--
-- Name: cmr_words_2 cmr_words_2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cmr_words_2
    ADD CONSTRAINT cmr_words_2_pkey PRIMARY KEY (user_pubkey, scope);


--
-- Name: coverages_1_8656fc443b coverages_1_8656fc443b_name_t_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.coverages_1_8656fc443b
    ADD CONSTRAINT coverages_1_8656fc443b_name_t_key UNIQUE (name, t);


--
-- Name: daily_followers_cnt_increases daily_followers_cnt_increases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_followers_cnt_increases
    ADD CONSTRAINT daily_followers_cnt_increases_pkey PRIMARY KEY (pubkey);


--
-- Name: deleted_events_1_0249f47b16 deleted_events_1_0249f47b16_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deleted_events_1_0249f47b16
    ADD CONSTRAINT deleted_events_1_0249f47b16_pkey PRIMARY KEY (event_id);


--
-- Name: dvm_feeds dvm_feeds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dvm_feeds
    ADD CONSTRAINT dvm_feeds_pkey PRIMARY KEY (pubkey, identifier);


--
-- Name: event_hls_media event_hls_media_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_hls_media
    ADD CONSTRAINT event_hls_media_pkey PRIMARY KEY (event_id, url, provider);


--
-- Name: event_media_1_30bf07e9cf event_media_1_30bf07e9cf_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_media_1_30bf07e9cf
    ADD CONSTRAINT event_media_1_30bf07e9cf_pkey PRIMARY KEY (event_id, url);


--
-- Name: event event_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event
    ADD CONSTRAINT event_pkey PRIMARY KEY (id);


--
-- Name: event_preview_1_310cef356e event_preview_1_310cef356e_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.event_preview_1_310cef356e
    ADD CONSTRAINT event_preview_1_310cef356e_pkey PRIMARY KEY (event_id, url);


--
-- Name: fetcher_relays fetcher_relays_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fetcher_relays
    ADD CONSTRAINT fetcher_relays_pk PRIMARY KEY (relay_url);


--
-- Name: filterlist filterlist_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filterlist
    ADD CONSTRAINT filterlist_pkey PRIMARY KEY (target, target_type, blocked, grp);


--
-- Name: follow_lists follow_lists_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.follow_lists
    ADD CONSTRAINT follow_lists_pkey PRIMARY KEY (pubkey, identifier, follow_pubkey);


--
-- Name: human_override human_override_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.human_override
    ADD CONSTRAINT human_override_pkey PRIMARY KEY (pubkey);


--
-- Name: live_event_notification_created live_event_notification_created_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.live_event_notification_created
    ADD CONSTRAINT live_event_notification_created_pkey PRIMARY KEY (kind, pubkey, identifier, follower_pubkey);


--
-- Name: live_event_participants live_event_participants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.live_event_participants
    ADD CONSTRAINT live_event_participants_pkey PRIMARY KEY (kind, pubkey, identifier, participant_pubkey);


--
-- Name: live_event_pubkey_filterlist live_event_pubkey_filterlist_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.live_event_pubkey_filterlist
    ADD CONSTRAINT live_event_pubkey_filterlist_pkey PRIMARY KEY (user_pubkey, blocked_pubkey);


--
-- Name: media_1_16fa35f2dc media_1_16fa35f2dc_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.media_1_16fa35f2dc
    ADD CONSTRAINT media_1_16fa35f2dc_pkey PRIMARY KEY (url, media_url, size, animated);


--
-- Name: media_metadata media_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.media_metadata
    ADD CONSTRAINT media_metadata_pkey PRIMARY KEY (sha256, model);


--
-- Name: media_storage media_storage_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.media_storage
    ADD CONSTRAINT media_storage_pk PRIMARY KEY (h, storage_provider);


--
-- Name: media_storage_priority media_storage_priority_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.media_storage_priority
    ADD CONSTRAINT media_storage_priority_pk PRIMARY KEY (storage_provider);


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
-- Name: note_stats_1_07d205f278 note_stats_1_07d205f278_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.note_stats_1_07d205f278
    ADD CONSTRAINT note_stats_1_07d205f278_pkey PRIMARY KEY (eid);


--
-- Name: notification_types notification_types_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_types
    ADD CONSTRAINT notification_types_pk PRIMARY KEY (type);


--
-- Name: poll_stats_1_d8de047040 poll_stats_1_d8de047040_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.poll_stats_1_d8de047040
    ADD CONSTRAINT poll_stats_1_d8de047040_pkey PRIMARY KEY (event_id);


--
-- Name: poll_user_votes_1_5fa4d82e64 poll_user_votes_1_5fa4d82e64_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.poll_user_votes_1_5fa4d82e64
    ADD CONSTRAINT poll_user_votes_1_5fa4d82e64_pkey PRIMARY KEY (poll_id, pubkey);


--
-- Name: preview_1_44299731c7 preview_1_44299731c7_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.preview_1_44299731c7
    ADD CONSTRAINT preview_1_44299731c7_pkey PRIMARY KEY (url);


--
-- Name: pubkey_notification_cnts_1_d78f6fcade pubkey_notification_cnts_1_d78f6fcade_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pubkey_notification_cnts_1_d78f6fcade
    ADD CONSTRAINT pubkey_notification_cnts_1_d78f6fcade_pkey PRIMARY KEY (pubkey);


--
-- Name: pubkey_stats pubkey_stats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pubkey_stats
    ADD CONSTRAINT pubkey_stats_pkey PRIMARY KEY (pubkey);


--
-- Name: pubkey_trustrank pubkey_trustrank_new_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pubkey_trustrank
    ADD CONSTRAINT pubkey_trustrank_new_pkey PRIMARY KEY (pubkey);


--
-- Name: reads_12_68c6bbfccd reads_12_68c6bbfccd_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reads_12_68c6bbfccd
    ADD CONSTRAINT reads_12_68c6bbfccd_pkey PRIMARY KEY (pubkey, identifier);


--
-- Name: reads_interactions reads_interactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reads_interactions
    ADD CONSTRAINT reads_interactions_pkey PRIMARY KEY (pubkey, eid);


--
-- Name: reads_interactions_state reads_interactions_state_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reads_interactions_state
    ADD CONSTRAINT reads_interactions_state_pkey PRIMARY KEY (id);


--
-- Name: relay_url_map relay_url_map_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.relay_url_map
    ADD CONSTRAINT relay_url_map_pkey PRIMARY KEY (src);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: spam_note_content_hash spam_note_content_hash_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.spam_note_content_hash
    ADD CONSTRAINT spam_note_content_hash_pkey PRIMARY KEY (content_sha256);


--
-- Name: text_metadata text_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.text_metadata
    ADD CONSTRAINT text_metadata_pkey PRIMARY KEY (sha256, model);


--
-- Name: trusted_pubkey_followers_cnt trusted_pubkey_followers_cnt_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.trusted_pubkey_followers_cnt
    ADD CONSTRAINT trusted_pubkey_followers_cnt_pkey PRIMARY KEY (t, pubkey);


--
-- Name: user_search user_search_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_search
    ADD CONSTRAINT user_search_pkey PRIMARY KEY (pubkey);


--
-- Name: vars vars_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vars
    ADD CONSTRAINT vars_pkey PRIMARY KEY (key);


--
-- Name: video_thumbnails_1_107d5a46eb video_thumbnails_1_107d5a46eb_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.video_thumbnails_1_107d5a46eb
    ADD CONSTRAINT video_thumbnails_1_107d5a46eb_pkey PRIMARY KEY (video_url);


--
-- Name: wsconnvars wsconnvars_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.wsconnvars
    ADD CONSTRAINT wsconnvars_pkey PRIMARY KEY (name);


--
-- Name: zap_receipt_invoices zap_receipt_invoices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.zap_receipt_invoices
    ADD CONSTRAINT zap_receipt_invoices_pkey PRIMARY KEY (zap_receipt_eid, invoice);


--
-- Name: zap_receipts_1_9fe40119b2 zap_receipts_1_9fe40119b2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.zap_receipts_1_9fe40119b2
    ADD CONSTRAINT zap_receipts_1_9fe40119b2_pkey PRIMARY KEY (eid);


--
-- Name: a_tags_1_7d98c5333f_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX a_tags_1_7d98c5333f_created_at_idx ON public.a_tags_1_7d98c5333f USING btree (created_at);


--
-- Name: a_tags_1_7d98c5333f_ref_kind_ref_pubkey_ref_identifier_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX a_tags_1_7d98c5333f_ref_kind_ref_pubkey_ref_identifier_idx ON public.a_tags_1_7d98c5333f USING btree (ref_kind, ref_pubkey, ref_identifier);


--
-- Name: advsearch_5_d7da6f551e_content_tsv_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX advsearch_5_d7da6f551e_content_tsv_idx ON public.advsearch_5_d7da6f551e USING gin (content_tsv);


--
-- Name: advsearch_5_d7da6f551e_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX advsearch_5_d7da6f551e_created_at_idx ON public.advsearch_5_d7da6f551e USING btree (created_at);


--
-- Name: advsearch_5_d7da6f551e_filter_tsv_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX advsearch_5_d7da6f551e_filter_tsv_idx ON public.advsearch_5_d7da6f551e USING gin (filter_tsv);


--
-- Name: advsearch_5_d7da6f551e_hashtag_tsv_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX advsearch_5_d7da6f551e_hashtag_tsv_idx ON public.advsearch_5_d7da6f551e USING gin (hashtag_tsv);


--
-- Name: advsearch_5_d7da6f551e_kind_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX advsearch_5_d7da6f551e_kind_idx ON public.advsearch_5_d7da6f551e USING btree (kind);


--
-- Name: advsearch_5_d7da6f551e_pubkey_created_at_desc_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX advsearch_5_d7da6f551e_pubkey_created_at_desc_idx ON public.advsearch_5_d7da6f551e USING btree (pubkey, created_at DESC);


--
-- Name: advsearch_5_d7da6f551e_reply_tsv_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX advsearch_5_d7da6f551e_reply_tsv_idx ON public.advsearch_5_d7da6f551e USING gin (reply_tsv);


--
-- Name: basic_tags_6_62c3d17c2f_arg1_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX basic_tags_6_62c3d17c2f_arg1_idx ON public.basic_tags_6_62c3d17c2f USING hash (arg1);


--
-- Name: basic_tags_6_62c3d17c2f_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX basic_tags_6_62c3d17c2f_created_at_idx ON public.basic_tags_6_62c3d17c2f USING btree (created_at);


--
-- Name: basic_tags_6_62c3d17c2f_e_actor_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX basic_tags_6_62c3d17c2f_e_actor_idx ON public.basic_tags_6_62c3d17c2f USING btree (arg1, pubkey, kind) WHERE ((tag = 'e'::bpchar) AND (kind = ANY (ARRAY[(1)::bigint, (6)::bigint, (7)::bigint, (20)::bigint, (1068)::bigint, (1111)::bigint, (6969)::bigint])));


--
-- Name: basic_tags_6_62c3d17c2f_e_kind_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX basic_tags_6_62c3d17c2f_e_kind_time_idx ON public.basic_tags_6_62c3d17c2f USING btree (arg1, kind, created_at DESC) WHERE ((tag = 'e'::bpchar) AND (kind = ANY (ARRAY[(1)::bigint, (6)::bigint, (7)::bigint, (20)::bigint, (1068)::bigint, (1111)::bigint, (6969)::bigint])));


--
-- Name: basic_tags_6_62c3d17c2f_id_tag_arg1_arg3_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX basic_tags_6_62c3d17c2f_id_tag_arg1_arg3_key ON public.basic_tags_6_62c3d17c2f USING btree (id, tag, arg1, arg3);


--
-- Name: basic_tags_6_62c3d17c2f_imported_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX basic_tags_6_62c3d17c2f_imported_at_idx ON public.basic_tags_6_62c3d17c2f USING btree (imported_at);


--
-- Name: basic_tags_6_62c3d17c2f_live_event_host_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX basic_tags_6_62c3d17c2f_live_event_host_idx ON public.basic_tags_6_62c3d17c2f USING btree (arg1, created_at DESC) INCLUDE (pubkey) WHERE ((kind = 30311) AND (tag = 'p'::bpchar) AND (lower((arg3)::text) = 'host'::text));


--
-- Name: basic_tags_6_62c3d17c2f_pkey; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX basic_tags_6_62c3d17c2f_pkey ON public.basic_tags_6_62c3d17c2f USING btree (i);


--
-- Name: basic_tags_6_62c3d17c2f_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX basic_tags_6_62c3d17c2f_pubkey_idx ON public.basic_tags_6_62c3d17c2f USING btree (pubkey);


--
-- Name: cmr_groups_user_pubkey_grp_scope_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cmr_groups_user_pubkey_grp_scope_idx ON public.cmr_groups USING btree (user_pubkey, grp, scope);


--
-- Name: cmr_pubkeys_allowed_user_pubkey_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cmr_pubkeys_allowed_user_pubkey_pubkey_idx ON public.cmr_pubkeys_allowed USING btree (user_pubkey, pubkey);


--
-- Name: cmr_pubkeys_scopes_user_pubkey_pubkey_scope_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX cmr_pubkeys_scopes_user_pubkey_pubkey_scope_idx ON public.cmr_pubkeys_scopes USING btree (user_pubkey, pubkey, scope);


--
-- Name: event_addressable_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_addressable_idx ON public.event USING btree (kind, pubkey, public.event_d_tag(tags), created_at DESC) WHERE ((kind >= 30000) AND (kind <= 39999));


--
-- Name: event_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_created_at_idx ON public.event USING btree (created_at);


--
-- Name: event_created_at_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_created_at_kind ON public.event USING btree (created_at, kind);


--
-- Name: event_hashtags_1_295f217c0e_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_hashtags_1_295f217c0e_created_at_idx ON public.event_hashtags_1_295f217c0e USING btree (created_at);


--
-- Name: event_hashtags_1_295f217c0e_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_hashtags_1_295f217c0e_event_id_idx ON public.event_hashtags_1_295f217c0e USING btree (event_id);


--
-- Name: event_hashtags_1_295f217c0e_hashtag_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_hashtags_1_295f217c0e_hashtag_idx ON public.event_hashtags_1_295f217c0e USING btree (hashtag);


--
-- Name: event_hooks_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_hooks_created_at_idx ON public.event_hooks USING btree (created_at);


--
-- Name: event_hooks_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_hooks_event_id_idx ON public.event_hooks USING btree (event_id);


--
-- Name: event_imported_at_kind_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_imported_at_kind_idx ON public.event USING btree (imported_at, kind);


--
-- Name: event_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_kind ON public.event USING btree (kind);


--
-- Name: event_lud16_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_lud16_idx ON public.event USING btree (public.event_lud16(content)) WHERE (kind = 0);


--
-- Name: event_media_1_30bf07e9cf_url_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_media_1_30bf07e9cf_url_idx ON public.event_media_1_30bf07e9cf USING btree (url);


--
-- Name: event_mentions_1_a056fb6737_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX event_mentions_1_a056fb6737_unique ON public.event_mentions_1_a056fb6737 USING btree (eid, tag, argeid, argpubkey, argkind, argid) NULLS NOT DISTINCT;


--
-- Name: event_pubkey_kind_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_pubkey_kind_created_at_idx ON public.event USING btree (pubkey, kind, created_at DESC);


--
-- Name: event_replies_1_9d033b5bb3_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_replies_1_9d033b5bb3_event_id_idx ON public.event_replies_1_9d033b5bb3 USING btree (event_id);


--
-- Name: event_replies_1_9d033b5bb3_reply_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_replies_1_9d033b5bb3_reply_created_at_idx ON public.event_replies_1_9d033b5bb3 USING btree (reply_created_at);


--
-- Name: event_replies_1_9d033b5bb3_reply_event_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX event_replies_1_9d033b5bb3_reply_event_id_key ON public.event_replies_1_9d033b5bb3 USING btree (reply_event_id);


--
-- Name: event_stats_1_1b380f4869_author_pubkey_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_author_pubkey_created_at_idx ON public.event_stats_1_1b380f4869 USING btree (author_pubkey, created_at);


--
-- Name: event_stats_1_1b380f4869_author_pubkey_satszapped_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_author_pubkey_satszapped_idx ON public.event_stats_1_1b380f4869 USING btree (author_pubkey, satszapped);


--
-- Name: event_stats_1_1b380f4869_author_pubkey_score_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_author_pubkey_score_idx ON public.event_stats_1_1b380f4869 USING btree (author_pubkey, score);


--
-- Name: event_stats_1_1b380f4869_created_at_satszapped_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_created_at_satszapped_idx ON public.event_stats_1_1b380f4869 USING btree (created_at, satszapped);


--
-- Name: event_stats_1_1b380f4869_created_at_score24h_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_created_at_score24h_idx ON public.event_stats_1_1b380f4869 USING btree (created_at, score24h);


--
-- Name: event_stats_1_1b380f4869_event_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX event_stats_1_1b380f4869_event_id_key ON public.event_stats_1_1b380f4869 USING btree (event_id);


--
-- Name: event_stats_1_1b380f4869_score_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX event_stats_1_1b380f4869_score_created_at_idx ON public.event_stats_1_1b380f4869 USING btree (score DESC, created_at);


--
-- Name: fetcher_relays_updated_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX fetcher_relays_updated_at_index ON public.fetcher_relays USING btree (updated_at);


--
-- Name: lists_pubkey; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX lists_pubkey ON public.lists USING btree (pubkey);


--
-- Name: live_event_participants_kind_participant_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX live_event_participants_kind_participant_pubkey_idx ON public.live_event_participants USING btree (kind, participant_pubkey);


--
-- Name: media_1_16fa35f2dc_orig_sha256_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_1_16fa35f2dc_orig_sha256_idx ON public.media_1_16fa35f2dc USING btree (orig_sha256);


--
-- Name: media_1_16fa35f2dc_url_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_1_16fa35f2dc_url_idx ON public.media_1_16fa35f2dc USING btree (url);


--
-- Name: media_storage_sha256_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX media_storage_sha256_idx ON public.media_storage USING btree (sha256);


--
-- Name: poll_user_votes_1_5fa4d82e64_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX poll_user_votes_1_5fa4d82e64_pubkey_idx ON public.poll_user_votes_1_5fa4d82e64 USING btree (pubkey);


--
-- Name: pubkey_bookmarks_pubkey_ref_event_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_bookmarks_pubkey_ref_event_id ON public.pubkey_bookmarks USING btree (pubkey, ref_event_id);


--
-- Name: pubkey_directmsgs_1_c794110a2c_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_directmsgs_1_c794110a2c_created_at_idx ON public.pubkey_directmsgs_1_c794110a2c USING btree (created_at);


--
-- Name: pubkey_directmsgs_1_c794110a2c_receiver_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_directmsgs_1_c794110a2c_receiver_event_id_idx ON public.pubkey_directmsgs_1_c794110a2c USING btree (receiver, event_id);


--
-- Name: pubkey_directmsgs_1_c794110a2c_receiver_sender_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_directmsgs_1_c794110a2c_receiver_sender_idx ON public.pubkey_directmsgs_1_c794110a2c USING btree (receiver, sender);


--
-- Name: pubkey_directmsgs_cnt_1_efdf9742a6_receiver_sender_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_directmsgs_cnt_1_efdf9742a6_receiver_sender_idx ON public.pubkey_directmsgs_cnt_1_efdf9742a6 USING btree (receiver, sender);


--
-- Name: pubkey_directmsgs_cnt_1_efdf9742a6_receiver_sender_uniq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pubkey_directmsgs_cnt_1_efdf9742a6_receiver_sender_uniq ON public.pubkey_directmsgs_cnt_1_efdf9742a6 USING btree (receiver, sender) NULLS NOT DISTINCT;


--
-- Name: pubkey_directmsgs_cnt_1_efdf9742a6_sender_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_directmsgs_cnt_1_efdf9742a6_sender_idx ON public.pubkey_directmsgs_cnt_1_efdf9742a6 USING btree (sender);


--
-- Name: pubkey_events_1_1dcbfe1466_created_at_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_events_1_1dcbfe1466_created_at_pubkey_idx ON public.pubkey_events_1_1dcbfe1466 USING btree (created_at DESC, pubkey);


--
-- Name: pubkey_events_1_1dcbfe1466_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pubkey_events_1_1dcbfe1466_event_id_idx ON public.pubkey_events_1_1dcbfe1466 USING btree (event_id);


--
-- Name: pubkey_events_1_1dcbfe1466_pubkey_created_at_incl_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_events_1_1dcbfe1466_pubkey_created_at_incl_idx ON public.pubkey_events_1_1dcbfe1466 USING btree (pubkey, created_at DESC) INCLUDE (event_id, is_reply, kind);


--
-- Name: pubkey_events_1_1dcbfe1466_pubkey_is_reply_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_events_1_1dcbfe1466_pubkey_is_reply_idx ON public.pubkey_events_1_1dcbfe1466 USING btree (pubkey, is_reply);


--
-- Name: pubkey_followers_1_d52305fb47_follower_pubkey_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_followers_1_d52305fb47_follower_pubkey_pubkey_idx ON public.pubkey_followers_1_d52305fb47 USING btree (follower_pubkey, pubkey);


--
-- Name: pubkey_followers_1_d52305fb47_pubkey_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_followers_1_d52305fb47_pubkey_idx ON public.pubkey_followers_1_d52305fb47 USING btree (pubkey);


--
-- Name: pubkey_notifications_1_e5459ab9dd_arg1_type8_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_notifications_1_e5459ab9dd_arg1_type8_idx ON public.pubkey_notifications_1_e5459ab9dd USING btree (arg1) WHERE (type = 8);


--
-- Name: pubkey_notifications_1_e5459ab9dd_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_notifications_1_e5459ab9dd_created_at_idx ON public.pubkey_notifications_1_e5459ab9dd USING btree (created_at);


--
-- Name: pubkey_notifications_1_e5459ab9dd_pubkey_arg1_idx_; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_notifications_1_e5459ab9dd_pubkey_arg1_idx_ ON public.pubkey_notifications_1_e5459ab9dd USING btree (pubkey, arg1) WHERE ((type <> 1) AND (type <> 2));


--
-- Name: pubkey_notifications_1_e5459ab9dd_pubkey_arg2_idx_; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_notifications_1_e5459ab9dd_pubkey_arg2_idx_ ON public.pubkey_notifications_1_e5459ab9dd USING btree (pubkey, arg2) WHERE ((type <> 1) AND (type <> 2));


--
-- Name: pubkey_notifications_1_e5459ab9dd_pubkey_created_at_type_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pubkey_notifications_1_e5459ab9dd_pubkey_created_at_type_idx ON public.pubkey_notifications_1_e5459ab9dd USING btree (pubkey, created_at, type);


--
-- Name: reads_12_68c6bbfccd_feed_published_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reads_12_68c6bbfccd_feed_published_at_idx ON public.reads_12_68c6bbfccd USING btree (published_at) INCLUDE (latest_eid, pubkey) WHERE ((words >= 100) AND ((summary)::text <> ''::text) AND ((image)::text <> ''::text));


--
-- Name: reads_12_68c6bbfccd_identifier_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reads_12_68c6bbfccd_identifier_idx ON public.reads_12_68c6bbfccd USING btree (identifier);


--
-- Name: reads_12_68c6bbfccd_published_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reads_12_68c6bbfccd_published_at_idx ON public.reads_12_68c6bbfccd USING btree (published_at);


--
-- Name: reads_12_68c6bbfccd_topics_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reads_12_68c6bbfccd_topics_idx ON public.reads_12_68c6bbfccd USING gin (topics);


--
-- Name: reads_latest_eid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX reads_latest_eid_idx ON public.reads_12_68c6bbfccd USING btree (latest_eid);


--
-- Name: score_expiry_expire_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX score_expiry_expire_at_idx ON public.score_expiry USING btree (expire_at);


--
-- Name: text_metadata_event_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX text_metadata_event_id_idx ON public.text_metadata USING btree (event_id);


--
-- Name: user_search_display_name_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_search_display_name_idx ON public.user_search USING gin (display_name);


--
-- Name: user_search_displayname_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_search_displayname_idx ON public.user_search USING gin (displayname);


--
-- Name: user_search_lud16_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_search_lud16_idx ON public.user_search USING gin (lud16);


--
-- Name: user_search_name_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_search_name_idx ON public.user_search USING gin (name);


--
-- Name: user_search_nip05_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_search_nip05_idx ON public.user_search USING gin (nip05);


--
-- Name: user_search_username_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX user_search_username_idx ON public.user_search USING gin (username);


--
-- Name: verified_users_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX verified_users_name ON public.verified_users USING btree (name);


--
-- Name: verified_users_pubkey; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX verified_users_pubkey ON public.verified_users USING btree (pubkey);


--
-- Name: zap_receipt_invoices_invoice_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX zap_receipt_invoices_invoice_idx ON public.zap_receipt_invoices USING btree (invoice);


--
-- Name: zap_receipts_1_9fe40119b2_imported_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX zap_receipts_1_9fe40119b2_imported_at_idx ON public.zap_receipts_1_9fe40119b2 USING btree (imported_at);


--
-- Name: zap_receipts_1_9fe40119b2_og_amount_sats_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX zap_receipts_1_9fe40119b2_og_amount_sats_idx ON public.zap_receipts_1_9fe40119b2 USING btree (og_amount_sats) WHERE (og_amount_sats IS NOT NULL);


--
-- Name: zap_receipts_1_9fe40119b2_og_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX zap_receipts_1_9fe40119b2_og_created_at_idx ON public.zap_receipts_1_9fe40119b2 USING btree (created_at) WHERE (og_amount_sats IS NOT NULL);


--
-- Name: zap_receipts_1_9fe40119b2_og_event_id_sender_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX zap_receipts_1_9fe40119b2_og_event_id_sender_idx ON public.zap_receipts_1_9fe40119b2 USING btree (og_event_id, og_sender) WHERE (og_amount_sats IS NOT NULL);


--
-- Name: zap_receipts_1_9fe40119b2_og_sender_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX zap_receipts_1_9fe40119b2_og_sender_idx ON public.zap_receipts_1_9fe40119b2 USING btree (og_sender) WHERE (og_amount_sats IS NOT NULL);


--
-- Name: zap_receipts_1_9fe40119b2_receiver_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX zap_receipts_1_9fe40119b2_receiver_idx ON public.zap_receipts_1_9fe40119b2 USING btree (receiver);


--
-- Name: zap_receipts_1_9fe40119b2_sender_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX zap_receipts_1_9fe40119b2_sender_idx ON public.zap_receipts_1_9fe40119b2 USING btree (sender);


--
-- Name: zap_receipts_1_9fe40119b2_target_eid_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX zap_receipts_1_9fe40119b2_target_eid_idx ON public.zap_receipts_1_9fe40119b2 USING btree (target_eid);


--
-- Name: cache update_cache_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_cache_updated_at BEFORE UPDATE ON public.cache FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


--
-- PostgreSQL database dump complete
--


-- the migrations this schema includes (sql/migrate.sh skips them)
INSERT INTO public.schema_migrations VALUES ('0002_julia_tables_for_the_ocaml_daemons', '2026-10-10 09:40:14.43902+00', 'baseline', '85adbe1e1a33efba', 22);
INSERT INTO public.schema_migrations VALUES ('1001_pubkey_directmsgs_cnt_unique', '2026-10-10 10:10:29.380324+00', 'baseline', '2f3d007c8f7a1d65', NULL);
INSERT INTO public.schema_migrations VALUES ('1002_parametrized_replaceable_events_pubkey_kind_identifier', '2026-10-10 10:11:32.877365+00', 'baseline', '35f034cb9b6967fb', 49087);
INSERT INTO public.schema_migrations VALUES ('4001_processing_nodes_running_func_created_at', '2026-10-10 10:11:32.905687+00', 'baseline', '552ac9315ec67c29', 10);
INSERT INTO public.schema_migrations VALUES ('2001_spam_softban_author_exempt', '2026-10-10 15:07:58.24036+00', 'baseline', 'f11a594ec23bfad4', 15);
INSERT INTO public.schema_migrations VALUES ('2002_reads_feed_published_at', '2026-10-12 09:39:21.646826+00', 'baseline', '25fac995cb753f3b', 468);
INSERT INTO public.schema_migrations VALUES ('2003_enrich_feed_events_once_per_event', '2026-10-12 09:39:21.677991+00', 'baseline', '3b93f06162dfdd76', 13);
INSERT INTO public.schema_migrations VALUES ('2004_get_media_url_stable', '2026-10-12 09:39:21.705712+00', 'baseline', '751bf59cf18714f6', 10);
INSERT INTO public.schema_migrations VALUES ('2005_live_feed_moderation_once', '2026-10-12 09:39:21.732057+00', 'baseline', '610d1aca7d0a23bc', 10);
INSERT INTO public.schema_migrations VALUES ('2006_advsearch_tsv_statistics', '2026-10-12 09:40:23.517357+00', 'baseline', 'a88d17c7172217ef', 61766);
INSERT INTO public.schema_migrations VALUES ('2007_reads_interactions', '2026-10-12 11:55:33.090409+00', 'baseline', 'ca8d25e9843d02d3', 19);
INSERT INTO public.schema_migrations VALUES ('1003_lean_schema_drop_classic_tables', '2026-11-18 12:49:32.383796+00', 'baseline', 'b23714809c6806ae', 17);
INSERT INTO public.schema_migrations VALUES ('2008_drop_classic_sql_functions', '2026-11-18 12:49:32.406008+00', 'baseline', '439b1b726fcd868a', 8);
