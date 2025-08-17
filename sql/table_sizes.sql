select table_schema, table_name, pg_size_pretty(pg_total_relation_size(table_schema || '.' || table_name)), pg_total_relation_size(table_schema || '.' || table_name) 
from information_schema.tables 
where table_schema in ('public') or table_schema like 'studio%' 
order by 4 desc;
