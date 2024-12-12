-- utils

CREATE OR REPLACE FUNCTION public.raise_notice(a text) RETURNS void LANGUAGE 'plpgsql' STABLE PARALLEL UNSAFE
AS $BODY$
BEGIN
RAISE NOTICE '%', a;
END;
$BODY$;

CREATE OR REPLACE FUNCTION public.count_jsonb_keys(j jsonb) RETURNS bigint LANGUAGE sql
AS $$ SELECT count(*) from (SELECT jsonb_object_keys(j)) v $$;

-- consts

CREATE OR REPLACE FUNCTION public.c_EVENT_STATS() RETURNS int LANGUAGE sql IMMUTABLE PARALLEL SAFE AS 'SELECT 10000100';
CREATE OR REPLACE FUNCTION public.c_REFERENCED_EVENT() RETURNS int LANGUAGE sql IMMUTABLE PARALLEL SAFE AS 'SELECT 10000107';
CREATE OR REPLACE FUNCTION public.c_USER_SCORES() RETURNS int LANGUAGE sql IMMUTABLE PARALLEL SAFE AS 'SELECT 10000108';
CREATE OR REPLACE FUNCTION public.c_RANGE() RETURNS int LANGUAGE sql IMMUTABLE PARALLEL SAFE AS 'SELECT 10000113';
CREATE OR REPLACE FUNCTION public.c_EVENT_ACTIONS_COUNT() RETURNS int LANGUAGE sql IMMUTABLE PARALLEL SAFE AS 'SELECT 10000115';
CREATE OR REPLACE FUNCTION public.c_MEDIA_METADATA() RETURNS int LANGUAGE sql IMMUTABLE PARALLEL SAFE AS 'SELECT 10000119';
CREATE OR REPLACE FUNCTION public.c_LINK_METADATA() RETURNS int LANGUAGE sql IMMUTABLE PARALLEL SAFE AS 'SELECT 10000128';
CREATE OR REPLACE FUNCTION public.c_ZAP_EVENT() RETURNS int LANGUAGE sql IMMUTABLE PARALLEL SAFE AS 'SELECT 10000129';
CREATE OR REPLACE FUNCTION public.c_USER_FOLLOWER_COUNTS() RETURNS int LANGUAGE sql IMMUTABLE PARALLEL SAFE AS 'SELECT 10000133';
CREATE OR REPLACE FUNCTION public.c_EVENT_RELAYS() RETURNS int LANGUAGE sql IMMUTABLE PARALLEL SAFE AS 'SELECT 10000141';
CREATE OR REPLACE FUNCTION public.c_LONG_FORM_METADATA() RETURNS int LANGUAGE sql IMMUTABLE PARALLEL SAFE AS 'SELECT 10000144';
CREATE OR REPLACE FUNCTION public.c_USER_PRIMAL_NAMES() RETURNS int LANGUAGE sql IMMUTABLE PARALLEL SAFE AS 'SELECT 10000158';
CREATE OR REPLACE FUNCTION public.c_MEMBERSHIP_LEGEND_CUSTOMIZATION() RETURNS int LANGUAGE sql IMMUTABLE PARALLEL SAFE AS 'SELECT 10000168';
CREATE OR REPLACE FUNCTION public.c_MEMBERSHIP_COHORTS() RETURNS int LANGUAGE sql IMMUTABLE PARALLEL SAFE AS 'SELECT 10000169';
/* CREATE OR REPLACE FUNCTION public.c_COLLECTION_ORDER() RETURNS int LANGUAGE sql IMMUTABLE PARALLEL SAFE AS 'SELECT 10000161'; */

-- types

CREATE TYPE cmr_scope AS ENUM ('content', 'trending');
CREATE TYPE cmr_grp AS ENUM ('primal_spam', 'primal_nsfw');
CREATE TYPE filterlist_grp AS ENUM ('spam', 'nsfw', 'csam');
CREATE TYPE filterlist_target AS ENUM ('pubkey', 'event');
CREATE TYPE media_size AS ENUM ('original', 'small', 'medium', 'large');
CREATE TYPE response_messages_for_post_res AS (e jsonb, is_referenced_event bool);
CREATE TYPE post AS (event_id bytea, created_at int8);

-- content moderation

CREATE OR REPLACE FUNCTION public.event_is_deleted(a_event_id bytea) RETURNS bool
    LANGUAGE 'sql' STABLE PARALLEL UNSAFE
AS $BODY$
SELECT EXISTS (SELECT 1 FROM deleted_events WHERE event_id = a_event_id)
$BODY$;

CREATE OR REPLACE FUNCTION public.is_pubkey_hidden_by_group(a_user_pubkey bytea, a_scope cmr_scope, a_pubkey bytea, a_cmr_grp cmr_grp, a_fl_grp filterlist_grp) RETURNS bool
    LANGUAGE 'sql' STABLE PARALLEL UNSAFE
AS $BODY$
SELECT
    EXISTS (
        SELECT 1 FROM cmr_groups cmr, filterlist fl
        WHERE 
            cmr.user_pubkey = a_user_pubkey AND cmr.grp = a_cmr_grp AND cmr.scope = a_scope AND 
            fl.target = a_pubkey AND fl.target_type = 'pubkey' AND fl.blocked AND fl.grp = a_fl_grp AND
            NOT EXISTS (SELECT 1 FROM filterlist fl2 WHERE fl2.target = a_pubkey AND fl2.target_type = 'pubkey' AND NOT fl2.blocked))
$BODY$;

CREATE OR REPLACE FUNCTION public.is_pubkey_hidden(a_user_pubkey bytea, a_scope cmr_scope, a_pubkey bytea) RETURNS bool
    LANGUAGE 'plpgsql' STABLE PARALLEL UNSAFE
AS $BODY$
BEGIN
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
$BODY$;

CREATE OR REPLACE FUNCTION public.is_event_hidden(a_user_pubkey bytea, a_scope cmr_scope, a_event_id bytea) RETURNS bool
    LANGUAGE 'sql' STABLE PARALLEL UNSAFE
AS $BODY$
SELECT EXISTS (SELECT 1 FROM events WHERE events.id = a_event_id AND is_pubkey_hidden(a_user_pubkey, a_scope, events.pubkey))
$BODY$;

CREATE OR REPLACE FUNCTION public.user_is_human(a_pubkey bytea, a_user_pubkey bytea) RETURNS bool
LANGUAGE 'sql' STABLE PARALLEL SAFE
AS $BODY$
SELECT (
    EXISTS (SELECT 1 FROM pubkey_trustrank ptr WHERE ptr.pubkey = a_pubkey) OR
    EXISTS (SELECT 1 FROM human_override ho WHERE ho.pubkey = a_pubkey AND ho.is_human) OR
    EXISTS (SELECT 1 FROM pubkey_followers WHERE pubkey = a_pubkey AND follower_pubkey = a_user_pubkey)
)
$BODY$;

CREATE OR REPLACE FUNCTION public.notification_is_visible(type int8, arg1 bytea, arg2 bytea, a_user_pubkey bytea) RETURNS bool
LANGUAGE 'sql' STABLE PARALLEL SAFE
AS $BODY$
SELECT
    CASE type
    WHEN 1 THEN user_is_human(arg1, a_user_pubkey)
    WHEN 2 THEN user_is_human(arg1, a_user_pubkey)

    WHEN 3 THEN user_is_human(arg2, a_user_pubkey)
    WHEN 4 THEN user_is_human(arg2, a_user_pubkey)
    WHEN 5 THEN user_is_human(arg2, a_user_pubkey)
    WHEN 6 THEN user_is_human(arg2, a_user_pubkey)

    WHEN 7 THEN user_is_human(arg2, a_user_pubkey)
    /* WHEN 8 THEN user_is_human(arg3, a_user_pubkey) */

    WHEN 101 THEN user_is_human(arg2, a_user_pubkey)
    WHEN 102 THEN user_is_human(arg2, a_user_pubkey)
    WHEN 103 THEN user_is_human(arg2, a_user_pubkey)
    WHEN 104 THEN user_is_human(arg2, a_user_pubkey)

    /* WHEN 201 THEN user_is_human(arg3, a_user_pubkey) */
    /* WHEN 202 THEN user_is_human(arg3, a_user_pubkey) */
    /* WHEN 203 THEN user_is_human(arg3, a_user_pubkey) */
    /* WHEN 204 THEN user_is_human(arg3, a_user_pubkey) */
    END CASE
$BODY$;

-- enrichment

CREATE OR REPLACE FUNCTION public.get_event(a_event_id bytea) RETURNS event
    LANGUAGE 'sql' STABLE PARALLEL UNSAFE
AS $BODY$
SELECT
	*
FROM
	events
WHERE
	events.id = a_event_id
LIMIT
	1
$BODY$;

CREATE OR REPLACE FUNCTION public.get_event_jsonb(a_event_id bytea) RETURNS jsonb 
    LANGUAGE 'sql' STABLE PARALLEL UNSAFE
AS $BODY$
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
$BODY$;

CREATE OR REPLACE FUNCTION public.event_stats(a_event_id bytea) RETURNS SETOF jsonb 
    LANGUAGE 'sql' STABLE PARALLEL UNSAFE
AS $BODY$
	SELECT jsonb_build_object('kind', c_EVENT_STATS(), 'content', row_to_json(a)::text)
	FROM (
		SELECT ENCODE(a_event_id, 'hex') as event_id, likes, replies, mentions, reposts, zaps, satszapped, score, score24h 
		FROM event_stats WHERE event_id = a_event_id
		LIMIT 1
	) a
$BODY$;

CREATE OR REPLACE FUNCTION public.event_stats_for_long_form_content(a_event_id bytea) RETURNS SETOF jsonb 
    LANGUAGE 'sql' STABLE PARALLEL UNSAFE
AS $BODY$
	SELECT jsonb_build_object('kind', c_EVENT_STATS(), 'content', row_to_json(a)::text)
	FROM (
        SELECT ENCODE(a_event_id, 'hex') as event_id, likes, replies, 0 AS mentions, reposts, zaps, satszapped, 0 AS score, 0 AS score24h 
        FROM reads WHERE latest_eid = a_event_id LIMIT 1
	) a
$BODY$;

CREATE OR REPLACE FUNCTION public.event_action_cnt(a_event_id bytea, a_user_pubkey bytea) RETURNS SETOF jsonb 
    LANGUAGE 'sql' STABLE PARALLEL UNSAFE
AS $BODY$	
	SELECT jsonb_build_object('kind', c_EVENT_ACTIONS_COUNT(), 'content', row_to_json(a)::text)
	FROM (
		SELECT 
            ENCODE(event_id, 'hex') AS event_id, 
            replied::int4::bool, 
            liked::int4::bool, 
            reposted::int4::bool, 
            zapped::int4::bool
		FROM event_pubkey_actions WHERE event_id = a_event_id AND pubkey = a_user_pubkey
		LIMIT 1
	) a
$BODY$;

CREATE OR REPLACE FUNCTION public.event_media_response(a_event_id bytea) RETURNS SETOF jsonb 
    LANGUAGE 'plpgsql' STABLE PARALLEL UNSAFE
AS $BODY$	
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
            FOR r IN SELECT size AS s, animated AS a, width AS w, height AS h, mimetype AS mt, duration AS dur FROM media WHERE media.url = r_url LOOP
                variants := variants || jsonb_build_array(jsonb_build_object(
                        's', SUBSTR(r.s, 1, 1),
                        'a', r.a,
                        'w', r.w,
                        'h', r.h,
                        'mt', r.mt,
                        'dur', r.dur,
                        'media_url', cdn_url(r_url, r.s, r.a::int4::bool)));
                root_mt := r.mt;
            END LOOP;
            resources := resources || jsonb_build_array(jsonb_build_object(
                    'url', r_url,
                    'variants', variants,
                    'mt', root_mt));
            FOR r_thumbnail_url IN SELECT thumbnail_url FROM video_thumbnails WHERE video_url = r_url LOOP
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
END $BODY$;

CREATE OR REPLACE FUNCTION public.event_preview_response(a_event_id bytea) RETURNS SETOF jsonb 
    LANGUAGE 'plpgsql' STABLE PARALLEL UNSAFE
AS $BODY$	
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
END $BODY$;

CREATE OR REPLACE FUNCTION public.zap_response(r record, a_user_pubkey bytea) RETURNS SETOF jsonb 
    LANGUAGE 'plpgsql' STABLE PARALLEL UNSAFE
AS $BODY$	
DECLARE
    pk bytea;
BEGIN
    IF (a_user_pubkey IS NOT null AND is_pubkey_hidden(a_user_pubkey, 'content', r.sender)) OR
        is_pubkey_hidden(r.receiver, 'content', r.sender) 
    THEN
        RETURN;
    END IF;

    FOR pk IN VALUES (r.sender), (r.receiver) LOOP
        RETURN NEXT get_event_jsonb(meta_data.value) FROM meta_data WHERE pk = meta_data.key;
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
END $BODY$;

CREATE OR REPLACE FUNCTION public.event_zaps(a_event_id bytea, a_user_pubkey bytea) RETURNS SETOF jsonb 
    LANGUAGE 'plpgsql' STABLE PARALLEL UNSAFE
AS $BODY$	
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
END $BODY$;

CREATE OR REPLACE FUNCTION public.event_zaps(a_pubkey bytea, a_identifier varchar, a_user_pubkey bytea) RETURNS SETOF jsonb 
    LANGUAGE 'plpgsql' STABLE PARALLEL UNSAFE
AS $BODY$	
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
END $BODY$;

CREATE OR REPLACE FUNCTION public.event_zap_by_zap_receipt_id(a_zap_receipt_id bytea, a_user_pubkey bytea) RETURNS SETOF jsonb 
    LANGUAGE 'plpgsql' STABLE PARALLEL UNSAFE
AS $BODY$	
DECLARE
    r record;
BEGIN
    FOR r IN 
        SELECT zap_receipt_id, created_at, event_id, sender, receiver, amount_sats FROM og_zap_receipts 
        WHERE zap_receipt_id = a_zap_receipt_id
    LOOP
        RETURN QUERY SELECT * FROM zap_response(r, a_user_pubkey);
    END LOOP;
END $BODY$;

CREATE OR REPLACE FUNCTION public.response_messages_for_post(
        a_event_id bytea,
        a_user_pubkey bytea,
        a_is_referenced_event bool,
        a_depth int8) 
    RETURNS SETOF response_messages_for_post_res
    LANGUAGE 'plpgsql' STABLE PARALLEL UNSAFE
AS $BODY$
DECLARE
	e event%ROWTYPE;
    eid bytea;
    pk bytea;
BEGIN
    IF a_depth = 0 THEN
        RETURN;
    END IF;

	e := get_event(a_event_id);

    IF EXISTS (
        SELECT 1 FROM pubkey_followers pf 
        WHERE pf.follower_pubkey = a_user_pubkey AND e.pubkey = pf.pubkey
    ) THEN
        -- user follows publisher
    ELSIF event_is_deleted(e.id) OR is_pubkey_hidden(a_user_pubkey, 'content', e.pubkey) THEN
        RETURN;
    END IF;

    DECLARE
        e_jsonb jsonb := get_event_jsonb(e.id);
    BEGIN
        IF e_jsonb IS null THEN
            RETURN;
        END IF;
        RETURN NEXT (e_jsonb, a_is_referenced_event);
    END;

	RETURN NEXT (get_event_jsonb(meta_data.value), false) FROM meta_data WHERE e.pubkey = meta_data.key;

    FOR eid IN 
        (
            SELECT arg1 FROM basic_tags WHERE id = a_event_id AND tag = 'e'
        ) UNION (
            SELECT argeid FROM event_mentions em WHERE em.eid = a_event_id AND tag = 'e'
        )
    LOOP
        RETURN QUERY SELECT * FROM response_messages_for_post(eid, a_user_pubkey, true, a_depth-1);
    END LOOP;

    FOR pk IN 
        (
            SELECT arg1 FROM basic_tags WHERE id = a_event_id AND tag = 'p'
        ) UNION (
            SELECT argpubkey FROM event_mentions em WHERE em.eid = a_event_id AND tag = 'p'
        )
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
        RETURN QUERY SELECT * FROM response_messages_for_post(eid, a_user_pubkey, true, a_depth-1);
    END LOOP;
END;
$BODY$;

-- feeds

CREATE OR REPLACE FUNCTION public.user_follows_posts(
        a_pubkey bytea,
        a_since bigint,
        a_until bigint,
        a_include_replies bigint,
        a_limit bigint,
        a_offset bigint) 
	RETURNS SETOF post
    LANGUAGE 'sql' STABLE PARALLEL UNSAFE
AS $BODY$
SELECT
	pe.event_id,
	pe.created_at
FROM
	pubkey_events pe,
	pubkey_followers pf
WHERE
	pf.follower_pubkey = a_pubkey AND
	pf.pubkey = pe.pubkey AND
	pe.created_at >= a_since AND
	pe.created_at <= a_until AND
	(
		pe.is_reply = 0 OR
		pe.is_reply = a_include_replies
	)
ORDER BY
	pe.created_at DESC
LIMIT
	a_limit
OFFSET
	a_offset
$BODY$;

CREATE OR REPLACE FUNCTION public.enrich_feed_events(
    a_posts post[], 
    a_user_pubkey bytea, 
    a_apply_humaness_check bool, 
    a_order_by varchar DEFAULT 'created_at'
)
	RETURNS SETOF jsonb
    LANGUAGE 'plpgsql' STABLE PARALLEL UNSAFE
AS $BODY$
DECLARE
	t RECORD;
	p RECORD;
	r RECORD;
	max_created_at int8 := null;
	min_created_at int8 := null;
    relay_url varchar;
    relays jsonb := '{}';
    user_scores jsonb := '{}';
    pubkeys bytea[] := '{}';
    identifier varchar;
    a_posts_sorted post[];
    elements jsonb := '{}';
BEGIN
    BEGIN
        a_posts_sorted := ARRAY (SELECT (event_id, created_at)::post FROM UNNEST(a_posts) p ORDER BY created_at DESC);
        SELECT COALESCE(jsonb_agg(ENCODE(event_id, 'hex')), '[]'::jsonb) INTO elements FROM UNNEST(a_posts_sorted) p;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE '% %', SQLERRM, SQLSTATE;
    END;

	FOREACH p IN ARRAY a_posts_sorted LOOP
		max_created_at := GREATEST(max_created_at, p.created_at);
		min_created_at := LEAST(min_created_at, p.created_at);
        FOR t IN SELECT * FROM response_messages_for_post(p.event_id, a_user_pubkey, false, 3) LOOP
            DECLARE
                e jsonb := t.e;
                e_id bytea := DECODE(e->>'id', 'hex');
                e_kind int8 := e->>'kind';
                e_pubkey bytea := DECODE(e->>'pubkey', 'hex');
                read_eid bytea;
            BEGIN
                IF e_pubkey IS NOT NULL THEN
                    pubkeys := array_append(pubkeys, e_pubkey);
                END IF;

                IF a_apply_humaness_check AND NOT user_is_human(e_pubkey, a_user_pubkey) THEN
                    CONTINUE;
                END IF;

                IF e_kind = 6 AND (
                    EXISTS (SELECT 1 FROM basic_tags WHERE id = e_id AND tag = 'p' AND is_pubkey_hidden(a_user_pubkey, 'content', arg1))
                    OR
                    EXISTS (SELECT 1 FROM basic_tags WHERE id = e_id AND tag = 'e' AND event_is_deleted(arg1))
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

                IF e_kind = 1 OR e_kind = 30023 THEN
                    /* IF NOT t.is_referenced_event THEN */
                        RETURN QUERY SELECT * FROM event_zaps(e_id, a_user_pubkey);
                    /* END IF; */

                    FOR identifier IN SELECT pre.identifier FROM parametrized_replaceable_events pre WHERE event_id = e_id LOOP
                        RETURN QUERY SELECT * FROM event_zaps(e_pubkey, identifier, a_user_pubkey);
                    END LOOP;

                    IF    e_kind = 1     THEN RETURN QUERY SELECT * FROM event_stats(e_id);
                    ELSIF e_kind = 30023 THEN RETURN QUERY SELECT * FROM event_stats_for_long_form_content(e_id);
                    END IF;

                    RETURN QUERY SELECT * FROM event_action_cnt(e_id, a_user_pubkey);

                    FOR r IN SELECT * FROM event_relay WHERE event_id = e_id LOOP
                        relay_url := r.relay_url;
                        SELECT dest INTO relay_url FROM relay_url_map WHERE src = relay_url LIMIT 1;
                        IF NOT (relay_url IS null) THEN
                            relays := jsonb_set(relays, array[(e->>'id')::text], to_jsonb(relay_url));
                        END IF;
                    END LOOP;
                END IF;

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
                    FOR r IN SELECT value FROM pubkey_followers_cnt WHERE key = e_pubkey LIMIT 1 LOOP
                        user_scores := jsonb_set(user_scores, array[e->>'pubkey'::text], to_jsonb(r.value));
                    END LOOP;
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

    IF count_jsonb_keys(relays) > 0 THEN
        RETURN NEXT jsonb_build_object('kind', c_EVENT_RELAYS(), 'content', relays::text);
    END IF;

    IF pubkeys != '{}' THEN
        RETURN QUERY SELECT * FROM primal_verified_names(pubkeys);
    END IF;

	RETURN NEXT jsonb_build_object(
		'kind', c_RANGE(),
		'content', json_build_object(
			'since', min_created_at, 
			'until', max_created_at, 
			'order_by', a_order_by,
            'elements', elements)::text);
    
	/* RETURN NEXT jsonb_build_object( */
	/* 	'kind', c_COLLECTION_ORDER(), */
	/* 	'content', json_build_object( */
	/* 		'elements', elements, */ 
	/* 		'order_by', a_order_by)::text); */
END;
$BODY$;

CREATE OR REPLACE FUNCTION public.feed_user_follows(
        a_pubkey bytea,
        a_since bigint,
        a_until bigint,
        a_include_replies bigint,
        a_limit bigint,
        a_offset bigint,
        a_user_pubkey bytea, 
        a_apply_humaness_check bool) 
	RETURNS SETOF jsonb
    LANGUAGE 'sql' STABLE PARALLEL UNSAFE
AS $BODY$
SELECT * FROM enrich_feed_events(
    ARRAY (
        SELECT r
        FROM user_follows_posts(
            a_pubkey,
            a_since,
            a_until,
            a_include_replies,
            a_limit,
            a_offset) r),
    a_user_pubkey, a_apply_humaness_check)
$BODY$;

CREATE OR REPLACE FUNCTION public.feed_user_authored(
        a_pubkey bytea,
        a_since bigint,
        a_until bigint,
        a_include_replies bigint,
        a_limit bigint,
        a_offset bigint,
        a_user_pubkey bytea, 
        a_apply_humaness_check bool) 
	RETURNS SETOF jsonb
    LANGUAGE 'plpgsql' STABLE PARALLEL UNSAFE
AS $BODY$
BEGIN
    IF EXISTS (SELECT 1 FROM filterlist WHERE grp = 'csam' AND target_type = 'pubkey' AND target = a_pubkey AND blocked LIMIT 1) THEN
        RETURN;
    END IF;

    RETURN QUERY SELECT * FROM enrich_feed_events(
        ARRAY (
            select (pe.event_id, pe.created_at)::post
            from pubkey_events pe
            where pe.pubkey = a_pubkey and pe.created_at >= a_since and pe.created_at <= a_until and pe.is_reply = a_include_replies
            order by pe.created_at desc limit a_limit offset a_offset
        ),
        a_user_pubkey, a_apply_humaness_check);
END
$BODY$;

CREATE OR REPLACE FUNCTION public.long_form_content_feed(
        a_pubkey bytea DEFAULT null, 
        a_notes varchar DEFAULT 'follows',
        a_topic varchar DEFAULT null,
        a_curation varchar DEFAULT null,
        a_minwords int8 DEFAULT 0,
        a_limit int8 DEFAULT 20, a_since int8 DEFAULT 0, a_until int8 DEFAULT EXTRACT(EPOCH FROM NOW())::int8, a_offset int8 DEFAULT 0,
        a_user_pubkey bytea DEFAULT null,
        a_apply_humaness_check bool DEFAULT false)
	RETURNS SETOF jsonb
    LANGUAGE 'plpgsql' STABLE PARALLEL UNSAFE
AS $BODY$
DECLARE
	posts post[];
BEGIN
    IF a_limit >= 1000 THEN
        RAISE EXCEPTION 'limit too big';
    END IF;

    IF a_curation IS NOT NULL and a_pubkey IS NOT NULL THEN
        posts := ARRAY (select distinct r.p FROM (
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
            order by reads.published_at desc limit a_limit offset a_offset) r);
    ELSIF a_pubkey IS NULL THEN
        posts := ARRAY (select distinct r.p FROM (
            select (latest_eid, published_at)::post as p
            from reads
            where 
                published_at >= a_since and published_at <= a_until and
                words >= a_minwords
                and (a_topic is null or topics @@ plainto_tsquery('simple', replace(a_topic, ' ', '-')))
            order by published_at desc limit a_limit offset a_offset) r);
    ELSIF a_notes = 'zappedbyfollows' THEN
        posts := ARRAY (select distinct r.p FROM (
            select (rs.latest_eid, rs.published_at)::post as p
            from pubkey_followers pf, reads rs, reads_versions rv, zap_receipts zr
            where 
                pf.follower_pubkey = a_pubkey and 
                pf.pubkey = zr.sender and zr.target_eid = rv.eid and
                rv.pubkey = rs.pubkey and rv.identifier = rs.identifier and
                rs.published_at >= a_since and rs.published_at <= a_until and
                rs.words >= a_minwords
            order by rs.published_at desc limit a_limit offset a_offset) r);
    ELSE
        IF a_notes = 'follows' AND EXISTS (select 1 from pubkey_followers pf where pf.follower_pubkey = a_pubkey limit 1) THEN
            posts := ARRAY (select distinct r.p FROM (
                select (reads.latest_eid, reads.published_at)::post as p
                from reads, pubkey_followers pf
                where 
                    pf.follower_pubkey = a_pubkey and pf.pubkey = reads.pubkey and 
                    reads.published_at >= a_since and reads.published_at <= a_until and
                    reads.words >= a_minwords
                    and (a_topic is null or reads.topics @@ plainto_tsquery('simple', replace(a_topic, ' ', '-')))
                order by reads.published_at desc limit a_limit offset a_offset) r);
        ELSIF a_notes = 'authored' THEN
            posts := ARRAY (select distinct r.p FROM (
                select (reads.latest_eid, reads.published_at)::post as p
                from reads
                where 
                    reads.pubkey = a_pubkey and 
                    reads.published_at >= a_since and reads.published_at <= a_until and
                    reads.words >= a_minwords
                    and (a_topic is null or topics @@ plainto_tsquery('simple', replace(a_topic, ' ', '-')))
                order by published_at desc limit a_limit offset a_offset) r);
        ELSE
            RAISE EXCEPTION 'unsupported type of notes';
        END IF;
    END IF;

    RETURN QUERY SELECT * FROM enrich_feed_events(posts, a_user_pubkey, a_apply_humaness_check, 'published_at');
END
$BODY$;

CREATE OR REPLACE FUNCTION public.primal_verified_names(a_pubkeys bytea[])
	RETURNS SETOF jsonb
    LANGUAGE 'plpgsql' STABLE PARALLEL UNSAFE
AS $BODY$
DECLARE
    r jsonb;
BEGIN
    SELECT json_object_agg(ENCODE(pubkey, 'hex'), name) INTO r FROM verified_users WHERE pubkey = ANY(a_pubkeys) and default_name;
    IF r IS NOT NULL THEN
        RETURN NEXT jsonb_build_object('kind', c_USER_PRIMAL_NAMES(), 'content', r::text);
    END IF;

    SELECT json_object_agg(
        ENCODE(pubkey, 'hex'), 
        jsonb_build_object('style', style, 'custom_badge', custom_badge, 'avatar_glow', avatar_glow))
    INTO r FROM membership_legend_customization WHERE pubkey = ANY(a_pubkeys);
    IF r IS NOT NULL THEN
        RETURN NEXT jsonb_build_object('kind', c_MEMBERSHIP_LEGEND_CUSTOMIZATION(), 'content', r::text);
    END IF;

    SELECT json_object_agg(
        ENCODE(pubkey, 'hex'), 
        jsonb_build_object('cohort_1', cohort_1, 'cohort_2', cohort_2, 'tier', tier, 'expires_on', extract(epoch from valid_until)::int8))
    INTO r FROM memberships WHERE pubkey = ANY(a_pubkeys) AND 
    (tier = 'premium' or tier = 'premium-legend')
    ;
    IF r IS NOT NULL THEN
        RETURN NEXT jsonb_build_object('kind', c_MEMBERSHIP_COHORTS(), 'content', r::text);
    END IF;
END
$BODY$;

CREATE OR REPLACE FUNCTION public.user_infos(a_pubkeys text[])
	RETURNS SETOF jsonb
    LANGUAGE 'sql' STABLE PARALLEL UNSAFE
AS $BODY$
SELECT * FROM user_infos(ARRAY (SELECT DECODE(UNNEST(a_pubkeys), 'hex')))
$BODY$;

CREATE OR REPLACE FUNCTION public.user_infos(a_pubkeys bytea[])
	RETURNS SETOF jsonb
    LANGUAGE 'plpgsql' STABLE PARALLEL UNSAFE
AS $BODY$
DECLARE
    mdeid bytea;
    r jsonb;
BEGIN
    FOR mdeid IN SELECT value FROM meta_data WHERE key = ANY(a_pubkeys) LOOP
        RETURN NEXT get_event_jsonb(mdeid);
        RETURN QUERY SELECT * FROM event_media_response(mdeid);
        RETURN QUERY SELECT * FROM event_preview_response(mdeid);
    END LOOP;

    SELECT json_object_agg(ENCODE(key, 'hex'), value) INTO r FROM pubkey_followers_cnt WHERE key = ANY(a_pubkeys);
	RETURN NEXT jsonb_build_object('kind', c_USER_SCORES(), 'content', r::text);
	RETURN NEXT jsonb_build_object('kind', c_USER_FOLLOWER_COUNTS(), 'content', r::text);

    RETURN QUERY SELECT * FROM primal_verified_names(a_pubkeys);
END
$BODY$;

CREATE OR REPLACE FUNCTION public.thread_view(
    a_event_id bytea,
    a_limit int8 DEFAULT 20, a_since int8 DEFAULT 0, a_until int8 DEFAULT EXTRACT(EPOCH FROM NOW())::int8, a_offset int8 DEFAULT 0,
    a_user_pubkey bytea DEFAULT null,
    a_apply_humaness_check bool DEFAULT false)
	RETURNS SETOF jsonb
    LANGUAGE 'plpgsql' STABLE PARALLEL UNSAFE
AS $BODY$
BEGIN
    IF  EXISTS (SELECT 1 FROM filterlist WHERE grp = 'csam' AND target_type = 'event' AND target = a_event_id AND blocked LIMIT 1) OR
        EXISTS (SELECT 1 FROM events es, filterlist fl WHERE es.id = a_event_id AND fl.target = es.pubkey AND fl.target_type = 'pubkey' AND fl.grp = 'csam' AND fl.blocked LIMIT 1)
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

    RETURN QUERY SELECT DISTINCT * FROM enrich_feed_events(
        ARRAY(SELECT r FROM thread_view_parent_posts(a_event_id) r ORDER BY r.created_at), 
        a_user_pubkey, false);
END
$BODY$;

CREATE OR REPLACE FUNCTION public.thread_view_reply_posts(
    a_event_id bytea,
    a_limit int8 DEFAULT 20, a_since int8 DEFAULT 0, a_until int8 DEFAULT EXTRACT(EPOCH FROM NOW())::int8, a_offset int8 DEFAULT 0)
	RETURNS SETOF post
    LANGUAGE 'sql' STABLE PARALLEL UNSAFE
AS $BODY$
select reply_event_id, reply_created_at from event_replies
where event_id = a_event_id and reply_created_at >= a_since and reply_created_at <= a_until
order by reply_created_at desc limit a_limit offset a_offset;
$BODY$;

CREATE OR REPLACE FUNCTION public.thread_view_parent_posts(a_event_id bytea)
	RETURNS SETOF post
    LANGUAGE 'plpgsql' STABLE PARALLEL UNSAFE
AS $BODY$
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
$BODY$;

CREATE OR REPLACE FUNCTION public.get_bookmarks(a_pubkey bytea)
	RETURNS SETOF jsonb
    LANGUAGE 'sql' STABLE PARALLEL UNSAFE
AS $BODY$
SELECT get_event_jsonb(event_id) FROM bookmarks WHERE pubkey = a_pubkey;
$BODY$;

CREATE OR REPLACE FUNCTION public.content_moderation_filtering(a_results jsonb, a_scope cmr_scope, a_user_pubkey bytea)
	RETURNS SETOF jsonb
    LANGUAGE 'sql' STABLE PARALLEL UNSAFE
AS $BODY$
SELECT e 
FROM jsonb_array_elements(a_results) r(e) 
WHERE e->>'pubkey' IS NULL OR NOT is_pubkey_hidden(a_user_pubkey, a_scope, DECODE(e->>'pubkey', 'hex'))
$BODY$;

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER LANGUAGE 'plpgsql' AS $BODY$
BEGIN
   NEW.updated_at = now();
   RETURN NEW;
END; $BODY$;

CREATE OR REPLACE FUNCTION humaness_threshold_trustrank() RETURNS float4 STABLE LANGUAGE 'sql' AS $$
SELECT RANK FROM pubkey_trustrank ORDER BY rank DESC LIMIT 1 OFFSET 50000
$$;

CREATE TABLE IF NOT EXISTS trusted_pubkey_followers_cnt (
    t timestamp not null,
    pubkey bytea not null,
    cnt int8 not null,
    PRIMARY KEY (t, pubkey)
);

CREATE OR REPLACE FUNCTION try_cast_jsonb(a_json text, a_default jsonb) RETURNS jsonb IMMUTABLE PARALLEL SAFE 
LANGUAGE 'plpgsql' AS $BODY$
BEGIN
  BEGIN
    RETURN a_json::jsonb;
  EXCEPTION
    WHEN OTHERS THEN
       RETURN a_default;
  END;
END;
$BODY$;

CREATE OR REPLACE FUNCTION user_has_bio(a_pubkey bytea) RETURNS bool STABLE LANGUAGE 'sql' AS $BODY$
SELECT coalesce(length(try_cast_jsonb(es.content::text, '{}')->>'about'), 0) > 0
FROM meta_data md, events es 
WHERE md.key = a_pubkey AND md.value = es.id
LIMIT 1
$BODY$;

CREATE OR REPLACE PROCEDURE record_trusted_pubkey_followers_cnt() 
LANGUAGE 'plpgsql' AS $BODY$
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
$BODY$;

CREATE OR REPLACE PROCEDURE update_user_relative_daily_follower_count_increases() 
LANGUAGE 'plpgsql' AS $BODY$
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
$BODY$;

SELECT cron.schedule('record_trusted_pubkey_followers_cnt',                 '0 */3 * * *', 'CALL record_trusted_pubkey_followers_cnt()');
SELECT cron.schedule('record_trusted_pubkey_followers_cnt_delete_old',      '0 * * * *', $$DELETE FROM trusted_pubkey_followers_cnt WHERE t < NOW() - INTERVAL '2 DAY'$$);
SELECT cron.schedule('update_user_relative_daily_follower_count_increases', '0 * * * *', 'CALL update_user_relative_daily_follower_count_increases()');

CREATE TABLE IF NOT EXISTS public.vars (
	"name" varchar NOT NULL,
	value jsonb NULL,
	CONSTRAINT vars_pk PRIMARY KEY (name)
);

CREATE OR REPLACE FUNCTION safe_jsonb(data text) RETURNS jsonb
LANGUAGE 'plpgsql' IMMUTABLE PARALLEL SAFE AS $BODY$
BEGIN
    RETURN data::jsonb;
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END;
$BODY$;

