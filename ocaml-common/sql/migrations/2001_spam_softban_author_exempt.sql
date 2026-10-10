-- The spam softban (sql/app.sql, "follow-aware spam softban"): is_pubkey_hidden, is_event_hidden,
-- response_messages_for_post and enrich_feed_events gained a trailing optional argument
-- (a_followed_override / a_author_exempt), and feed_user_authored passes the profile owner down.
-- The API calls the 4-argument is_pubkey_hidden; a database that only has the old signatures
-- answers "function is_pubkey_hidden(unknown, cmr_scope, bytea, unknown) does not exist".
-- The old signatures are dropped rather than kept next to the new ones: a 3-argument call would
-- then match both (the new one through its default) and fail as ambiguous. The defaults keep the
-- old callers (Julia, other SQL functions) working unchanged. One transaction, so no caller sees
-- the functions missing. Bodies are the stage database's (pg_get_functiondef).
begin;

drop function if exists public.is_pubkey_hidden(bytea, cmr_scope, bytea);
drop function if exists public.is_event_hidden(bytea, cmr_scope, bytea);
drop function if exists public.response_messages_for_post(bytea, bytea, boolean, bigint);
drop function if exists public.enrich_feed_events(post[], bytea, boolean, character varying, boolean);

CREATE OR REPLACE FUNCTION public.is_pubkey_hidden(a_user_pubkey bytea, a_scope cmr_scope, a_pubkey bytea, a_followed_override bytea DEFAULT NULL::bytea)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.is_event_hidden(a_user_pubkey bytea, a_scope cmr_scope, a_event_id bytea, a_author_exempt bytea DEFAULT NULL::bytea)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.response_messages_for_post(a_event_id bytea, a_user_pubkey bytea, a_is_referenced_event boolean, a_depth bigint, a_author_exempt bytea DEFAULT NULL::bytea)
 RETURNS SETOF response_messages_for_post_res
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
	e event%ROWTYPE;
    eid bytea;
    pk bytea;
BEGIN
    IF a_depth = 0 THEN
        RETURN;
    END IF;

	e := get_event(a_event_id);

    IF event_is_deleted(e.id) THEN
        RETURN;
    ELSIF is_pubkey_hidden(a_user_pubkey, 'content', e.pubkey, a_author_exempt) THEN
        RETURN;
    ELSIF is_event_hidden(a_user_pubkey, 'content', a_event_id, a_author_exempt) THEN
        RETURN;
    ELSIF EXISTS (
        SELECT 1 FROM pubkey_followers pf
        WHERE pf.follower_pubkey = a_user_pubkey AND e.pubkey = pf.pubkey
    ) THEN
        -- user follows publisher
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
$function$
;

CREATE OR REPLACE FUNCTION public.enrich_feed_events(a_posts post[], a_user_pubkey bytea, a_apply_humaness_check boolean, a_order_by character varying DEFAULT 'created_at'::character varying, presort boolean DEFAULT true, a_author_exempt bytea DEFAULT NULL::bytea)
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
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
    poll_seen bytea[] := '{}';
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

                -- IF e_kind = 1 OR e_kind = 30023 THEN
                    /* IF NOT t.is_referenced_event THEN */
                        RETURN QUERY SELECT * FROM event_zaps(e_id, a_user_pubkey);
                    /* END IF; */

                    FOR identifier IN SELECT pre.identifier FROM parametrized_replaceable_events pre WHERE event_id = e_id LOOP
                        RETURN QUERY SELECT * FROM event_zaps(e_pubkey, identifier, a_user_pubkey);
                    END LOOP;

                    -- IF    e_kind = 1     THEN RETURN QUERY SELECT * FROM event_stats(e_id);
                    -- ELSIF e_kind = 30023 THEN RETURN QUERY SELECT * FROM event_stats_for_long_form_content(e_id);
                    IF    e_kind != 30023 THEN RETURN QUERY SELECT * FROM event_stats(e_id);
                    ELSIF e_kind =  30023 THEN RETURN QUERY SELECT * FROM event_stats_for_long_form_content(e_id);
                    END IF;

                    RETURN QUERY SELECT * FROM event_action_cnt(e_id, a_user_pubkey);
                -- END IF;

                IF e_kind = 1 OR e_kind = 30023 OR e_kind = 0 THEN
                    FOR r IN SELECT * FROM event_relay WHERE event_id = e_id LOOP
                        relay_url := r.relay_url;
                        FOR r IN SELECT dest FROM relay_url_map WHERE src = relay_url LIMIT 1 LOOP
                            relay_url := r.dest;
                        END LOOP;
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
                    -- RETURN QUERY SELECT get_event_jsonb(value) FROM contact_lists WHERE key = e_pubkey LIMIT 1; -- bugs prod ios app
                    -- RETURN QUERY SELECT get_event_jsonb(event_id) FROM relay_list_metadata WHERE pubkey = e_pubkey LIMIT 1;
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

    IF count_jsonb_keys(relays) > 0 THEN
        RETURN NEXT jsonb_build_object('kind', c_EVENT_RELAYS(), 'content', relays::text);
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
    
	/* RETURN NEXT jsonb_build_object( */
	/* 	'kind', c_COLLECTION_ORDER(), */
	/* 	'content', json_build_object( */
	/* 		'elements', elements, */ 
	/* 		'order_by', a_order_by)::text); */
END;
$function$
;

CREATE OR REPLACE FUNCTION public.feed_user_authored(a_pubkey bytea, a_since bigint, a_until bigint, a_include_replies bigint, a_limit bigint, a_offset bigint, a_user_pubkey bytea, a_apply_humaness_check boolean, a_kinds bigint[] DEFAULT '{1}'::bigint[])
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
BEGIN
    IF EXISTS (SELECT 1 FROM filterlist WHERE grp in ('csam', 'impersonation') AND target_type = 'pubkey' AND target = a_pubkey AND blocked LIMIT 1) THEN
        RETURN;
    END IF;

    -- profile feed: exempt the profile owner from spam-softban hiding (threaded explicitly via
    -- a_author_exempt) so non-followers still see their authored posts.
    RETURN QUERY SELECT * FROM enrich_feed_events(
        ARRAY (
            select (e.id, pe.created_at)::post
            from
                pubkey_events pe
                JOIN events e ON e.id = pe.event_id
            where
                pe.pubkey = a_pubkey and pe.created_at >= a_since and pe.created_at <= a_until and
                pe.is_reply = a_include_replies and
                e.kind = ANY(a_kinds)
            order by pe.created_at desc limit a_limit offset a_offset
        ),
        a_user_pubkey, a_apply_humaness_check, a_author_exempt => a_pubkey);
END
$function$
;

commit;
