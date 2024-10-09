DROP EXTENSION pg_primal; CREATE EXTENSION pg_primal;

CREATE VIEW event_tags AS
SELECT event.id,
    event.pubkey,
    event.kind,
    event.created_at,
    jsonb_array_elements(event.tags) ->> 0 AS tag,
    jsonb_array_elements(event.tags) ->> 1 AS arg1
   FROM event;

CREATE TABLE IF NOT EXISTS wsconnvars (
    name varchar not null primary key, 
    value jsonb not null
);
INSERT INTO wsconnvars VALUES ('logging_enabled', 'true') ON CONFLICT DO NOTHING;
INSERT INTO wsconnvars VALUES ('idle_connection_timeout', '600') ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS wsconnruns (
    run bigserial not null primary key,
    tstart timestamp not null,
    servername varchar not null,
    port int8 not null
);
CREATE UNLOGGED TABLE IF NOT EXISTS wsconnlog (
    t timestamp not null,
    run int8 not null,
    task int8 not null,
    tokio_task int8 not null,
    info jsonb not null,
    func varchar,
    conn int8
);
CREATE INDEX IF NOT EXISTS wsconnlog_t_idx ON wsconnlog (t);

CREATE EXTENSION dblink;

CREATE OR REPLACE FUNCTION public.wsconntasks(a_port int8 DEFAULT 14001) 
    RETURNS TABLE(tokio_task int8, task int8, trace varchar)
    LANGUAGE 'sql' STABLE PARALLEL UNSAFE
AS $BODY$
SELECT * FROM dblink(format('host=127.0.0.1 port=%s', a_port), 'select * from tasks;') AS t(tokio_task int8, task int8, trace varchar)
$BODY$;
