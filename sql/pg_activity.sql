select * from pg_stat_activity where state != 'idle' and pid != pg_backend_pid();
