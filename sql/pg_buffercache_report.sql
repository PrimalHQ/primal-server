SELECT c.relname,
   Pg_size_pretty(Count(*) * 8192)
   AS buffered,
   Round(100.0 * Count(*) / (SELECT setting
                             FROM   pg_settings
                             WHERE  name = 'shared_buffers') :: INTEGER, 1)
   AS
   buffers_percent,
   Round(100.0 * Count(*) * 8192 / Pg_relation_size(c.oid), 1)
   AS
   percent_of_relation
FROM   pg_class c
       INNER JOIN pg_buffercache b
               ON b.relfilenode = c.relfilenode
       INNER JOIN pg_database d
               ON ( b.reldatabase = d.oid
                    AND d.datname = Current_database() )
WHERE  Pg_relation_size(c.oid) > 0
GROUP  BY c.oid,
          c.relname
ORDER  BY 3 DESC
LIMIT  30;   