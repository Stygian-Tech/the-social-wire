\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout = '10s';
SELECT now() AS captured_at, current_database(), version();
SELECT name, setting, unit FROM pg_settings WHERE name IN (
  'shared_buffers', 'work_mem', 'max_connections', 'wal_compression', 'max_wal_size',
  'checkpoint_timeout', 'checkpoint_completion_target', 'archive_mode', 'archive_timeout',
  'fsync', 'full_page_writes', 'shared_preload_libraries');
SELECT * FROM pg_stat_wal;
SELECT * FROM pg_stat_checkpointer;
SELECT * FROM pg_stat_archiver;
SELECT datname, stats_reset, xact_commit, xact_rollback, blks_read, blks_hit,
  temp_files, temp_bytes, deadlocks FROM pg_stat_database WHERE datname = current_database();
SELECT s.relname, c.relpersistence, pg_total_relation_size(s.relid) AS total_bytes,
  pg_indexes_size(s.relid) AS index_bytes, s.n_live_tup, s.n_dead_tup,
  s.n_tup_ins, s.n_tup_upd, s.n_tup_hot_upd, s.n_tup_del, s.last_autovacuum
FROM pg_stat_user_tables s JOIN pg_class c ON c.oid = s.relid
ORDER BY pg_total_relation_size(s.relid) DESC LIMIT 25;
SELECT application_name, state, wait_event_type, wait_event, count(*)
FROM pg_stat_activity WHERE datname = current_database()
GROUP BY 1, 2, 3, 4 ORDER BY count(*) DESC;
SELECT language_bucket, config_version, count(*) AS generations,
  min(generated_at), max(generated_at), min(expires_at), max(expires_at)
FROM wire_rank_generations GROUP BY 1, 2 ORDER BY 1, 2;
SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements')
  AND current_setting('shared_preload_libraries') LIKE '%pg_stat_statements%'
  AS statements_available \gset
\if :statements_available
SELECT dealloc, stats_reset FROM pg_stat_statements_info;
-- Query IDs identify statements without exporting user values or SQL text.
SELECT queryid, calls, total_exec_time, mean_exec_time, rows, wal_bytes,
  shared_blks_read, shared_blks_hit, temp_blks_written
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY total_exec_time DESC LIMIT 20;
SELECT queryid, calls, total_exec_time, wal_bytes, temp_blks_written
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY wal_bytes DESC LIMIT 20;
\endif
COMMIT;
