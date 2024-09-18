DROP EXTENSION pg_primal; CREATE EXTENSION pg_primal;

CREATE VIEW event_tags AS
SELECT event.id,
    event.pubkey,
    event.kind,
    event.created_at,
    jsonb_array_elements(event.tags) ->> 0 AS tag,
    jsonb_array_elements(event.tags) ->> 1 AS arg1
   FROM event;


