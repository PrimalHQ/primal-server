-- lock_timeout: 120s
-- advsearch: finer statistics for the full-text columns, so the planner knows a rare word is rare.
-- With the default target (100) pg_statistic keeps the 1000 most common words of content_tsv (the
-- rarest at frequency 0.0023), and any other word is estimated at half that: 306 k of 270 M rows
-- for a word that occurs 58 times. Each search window then bitmap-ANDed the GIN index with the
-- whole created_at range of the window (11 ms for 16 h, seconds for months), and a rare word walks
-- back through many windows (the window resets to 1 h after every hit), so advanced searches for
-- rare words ran into the 9 s budget with partial results. At 10000 the stage host keeps 77 k words
-- (rarest 1.3e-5: an unknown word is ~1.8 k rows) and plans the GIN index alone: those searches
-- went from 4-9 s to 0.1-0.4 s (one 2.2 s), hashtag searches from 1-5 s to 0.5-0.8 s (cold).
-- Planning an advsearch window costs ~4 ms more (12 ms). The ANALYZE samples 3 M rows: 65 s on the
-- stage host; it takes a SHARE UPDATE EXCLUSIVE lock (reads and writes go on). Idempotent.
alter table advsearch_5_d7da6f551e alter column content_tsv set statistics 10000;
alter table advsearch_5_d7da6f551e alter column hashtag_tsv set statistics 10000;
analyze advsearch_5_d7da6f551e (content_tsv, hashtag_tsv);
