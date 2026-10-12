-- live_feed (the initial answer of a live stream's chat): moderation checked once per row, and cheaply.
-- live_feed_initial_response runs live_feed_is_hidden (is_event_hidden for the viewer and every host)
-- over the stream's chat messages (up to 10000), its reactions and zaps, and once more over the zaps
-- for the top five and again for the totals. On the stage host a stream with 2156 chat messages and
-- 1307 zaps took 6.7 s, four statements of 1.4-2.2 s.
-- 1. live_feed_is_hidden: is_event_hidden over `unnest(a_host_pubkeys)` inside an EXISTS costs six
--    times a direct call (the host is a column there, not a parameter); a loop over the hosts calls it
--    directly. Same results: null or other modes false, a null or empty host list checks the viewer
--    only (stage host: 3644 rows x 4 modes, null viewer, null/empty hosts, no difference). The unused
--    `select es.pubkey into pubkey` is gone. 1.3 s -> 0.26 s over 1307 zaps.
-- 2. live_feed_initial_response: the visible zaps are found once and reused by the latest-1000 list,
--    the top five and the totals (the totals stay a loop: a receipt without an amount makes them null,
--    as before).
-- Idempotent.
CREATE OR REPLACE FUNCTION public.live_feed_is_hidden(a_event_id bytea, a_user_pubkey bytea, a_host_pubkeys bytea[], a_content_moderation_mode character varying)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.live_feed_initial_response(a_kind bigint, a_pubkey bytea, a_identifier character varying, a_user_pubkey bytea, a_content_moderation_mode character varying, a_limit bigint DEFAULT 20, a_apply_humaness_check boolean DEFAULT true)
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
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
$function$;
