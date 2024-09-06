CREATE OR REPLACE FUNCTION public.user_is_human(a_pubkey bytea) RETURNS bool
LANGUAGE 'sql' STABLE PARALLEL SAFE
AS $BODY$
SELECT (
    EXISTS (SELECT 1 FROM pubkey_trustrank ptr WHERE ptr.pubkey = a_pubkey) OR
    EXISTS (SELECT 1 FROM human_override ho WHERE ho.pubkey = a_pubkey AND ho.is_human)
)
$BODY$;

CREATE OR REPLACE FUNCTION public.notification_is_visible(type int8, arg1 bytea, arg2 bytea) RETURNS bool
LANGUAGE 'sql' STABLE PARALLEL SAFE
AS $BODY$
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
$BODY$;

