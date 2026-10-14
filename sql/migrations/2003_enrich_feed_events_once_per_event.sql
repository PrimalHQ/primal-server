-- enrich_feed_events: enrich each event once. response_messages_for_post walks the e/p/a references
-- of every post to depth 3, and in a deep thread each reply references its ancestors, which reference
-- theirs: one reply on the stage host gave 817 rows for 67 distinct messages, and the loop below ran
-- the full per-event enrichment (zaps, stats, action counts, relays, media, ...) for each of them
-- (0.7 s; a 98-post thread took 7.4 s). An event already enriched in the same role (referenced or
-- not: the role decides the wrapper and the humaness check) is now skipped. The rows a repeat would
-- add are the same rows again, and every caller takes DISTINCT rows (the API's queries, thread_view,
-- multi_kind_thread_view), so no response changes. A null id (missing metadata) is never skipped,
-- as before. Body otherwise the stage database's (pg_get_functiondef, as in 2001). Idempotent.
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
$function$;
