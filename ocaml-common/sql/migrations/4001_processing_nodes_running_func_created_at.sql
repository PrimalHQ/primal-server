-- lock_timeout: 120s
-- processing_nodes: partial index for the media scheduler's start-up reset of stuck tasks
-- (ocaml-jobs/lib_media/procgraph.ml reset_stuck, run once per execute_funcs entry):
--   update processing_nodes set started_at = null
--   where created_at >= now() - interval '2d' and func = $1 and started_at is not null and finished_at is null
-- Without it each reset range-scans processing_nodes_created_at_idx over every row of the last two days
-- (5 M rows on the media host, 1085 GB heap / 660 M rows) and filters; on a cold cache that took
-- 11-35 s per func, past the jobs daemon's 30 s statement_timeout, and primal-jobs crash-looped for
-- 8 minutes after its restart on 2026-10-09. The rows it matches (started, unfinished) are a handful,
-- so the index stays tiny.
-- Only where the table exists (the media host; the stage host has none). Built concurrently: one
-- full heap scan plus a validation pass, so expect a long, I/O-heavy run on the media host. A build
-- that failed half-way leaves an invalid index, which `if not exists` would keep: drop it first.
-- Idempotent.
select exists (select 1 from pg_class where relname = 'processing_nodes' and relkind in ('r', 'p')) as has_processing_nodes,
       exists (select 1 from pg_class c join pg_index i on i.indexrelid = c.oid
               where c.relname = 'processing_nodes_running_func_created_at_idx' and not i.indisvalid) as invalid_leftover
\gset
\if :invalid_leftover
drop index concurrently processing_nodes_running_func_created_at_idx;
\endif
\if :has_processing_nodes
create index concurrently if not exists processing_nodes_running_func_created_at_idx
  on processing_nodes (func, created_at)
  where started_at is not null and finished_at is null;
\endif
