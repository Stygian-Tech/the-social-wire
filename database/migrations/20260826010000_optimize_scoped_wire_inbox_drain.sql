-- socialwire:transaction=off

-- Scoped live-tail drains must probe ready rows inside their environment and
-- source generation. The previous indexes began with a timestamp, forcing each
-- scoped claim to walk unrelated generations and encouraging full-backlog
-- materialization when a replay had accumulated hundreds of thousands of rows.

SET lock_timeout = '5s';
SET statement_timeout = '30min';

SELECT EXISTS (
  SELECT 1 FROM pg_class index_relation
  JOIN pg_index index_state ON index_state.indexrelid = index_relation.oid
  WHERE index_relation.oid = to_regclass(
    'public.wire_ingestion_inbox_scoped_pending_retry_ready_idx'
  ) AND NOT index_state.indisvalid
) AS index_is_invalid \gset
\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS public.wire_ingestion_inbox_scoped_pending_retry_ready_idx;
\endif
CREATE INDEX CONCURRENTLY IF NOT EXISTS wire_ingestion_inbox_scoped_pending_retry_ready_idx
ON public.wire_ingestion_inbox (environment, source_generation, next_attempt_at, seq)
WHERE status IN ('pending', 'retry');

SELECT EXISTS (
  SELECT 1 FROM pg_class index_relation
  JOIN pg_index index_state ON index_state.indexrelid = index_relation.oid
  WHERE index_relation.oid = to_regclass(
    'public.wire_ingestion_inbox_scoped_expired_lease_idx'
  ) AND NOT index_state.indisvalid
) AS index_is_invalid \gset
\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS public.wire_ingestion_inbox_scoped_expired_lease_idx;
\endif
CREATE INDEX CONCURRENTLY IF NOT EXISTS wire_ingestion_inbox_scoped_expired_lease_idx
ON public.wire_ingestion_inbox (environment, source_generation, lease_expires_at, seq)
WHERE status = 'leased';

RESET statement_timeout;
RESET lock_timeout;
