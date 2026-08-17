-- socialwire:transaction=off
-- Query-specific indexes for the Jetstream V2 rolling drain.
--
-- Each build is concurrent so active ingestion and cache writes can continue.
-- A failed concurrent build can leave an invalid index behind; remove only that
-- invalid artifact before retrying, while preserving a valid index from a prior
-- successful-but-unrecorded attempt.

SELECT EXISTS (
  SELECT 1 FROM pg_class index_relation
  JOIN pg_index index_state ON index_state.indexrelid = index_relation.oid
  WHERE index_relation.oid = to_regclass('public.idx_appview_ingestion_inbox_ready')
    AND NOT index_state.indisvalid
) AS index_is_invalid \gset
\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS public.idx_appview_ingestion_inbox_ready;
\endif
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_appview_ingestion_inbox_ready
  ON appview_ingestion_inbox
    (environment, source_generation, next_attempt_at, seq)
  INCLUDE (repo_did)
  WHERE status IN ('pending', 'retry');

SELECT EXISTS (
  SELECT 1 FROM pg_class index_relation
  JOIN pg_index index_state ON index_state.indexrelid = index_relation.oid
  WHERE index_relation.oid = to_regclass('public.idx_appview_ingestion_inbox_expired_lease')
    AND NOT index_state.indisvalid
) AS index_is_invalid \gset
\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS public.idx_appview_ingestion_inbox_expired_lease;
\endif
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_appview_ingestion_inbox_expired_lease
  ON appview_ingestion_inbox
    (environment, source_generation, lease_expires_at, seq)
  INCLUDE (repo_did)
  WHERE status = 'leased';

SELECT EXISTS (
  SELECT 1 FROM pg_class index_relation
  JOIN pg_index index_state ON index_state.indexrelid = index_relation.oid
  WHERE index_relation.oid = to_regclass('public.idx_appview_ingestion_reconciliation_ready')
    AND NOT index_state.indisvalid
) AS index_is_invalid \gset
\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS public.idx_appview_ingestion_reconciliation_ready;
\endif
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_appview_ingestion_reconciliation_ready
  ON appview_ingestion_reconciliation_requests
    (environment, source_generation, next_attempt_at, trigger_seq, id)
  INCLUDE (repo_did)
  WHERE status = 'pending';

SELECT EXISTS (
  SELECT 1 FROM pg_class index_relation
  JOIN pg_index index_state ON index_state.indexrelid = index_relation.oid
  WHERE index_relation.oid = to_regclass('public.idx_appview_ingestion_reconciliation_expired_lease')
    AND NOT index_state.indisvalid
) AS index_is_invalid \gset
\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS public.idx_appview_ingestion_reconciliation_expired_lease;
\endif
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_appview_ingestion_reconciliation_expired_lease
  ON appview_ingestion_reconciliation_requests
    (environment, source_generation, lease_expires_at, trigger_seq, id)
  INCLUDE (repo_did)
  WHERE status = 'leased';

SELECT EXISTS (
  SELECT 1 FROM pg_class index_relation
  JOIN pg_index index_state ON index_state.indexrelid = index_relation.oid
  WHERE index_relation.oid = to_regclass('public.idx_appview_ingestion_reconciliation_active_repo')
    AND NOT index_state.indisvalid
) AS index_is_invalid \gset
\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS public.idx_appview_ingestion_reconciliation_active_repo;
\endif
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_appview_ingestion_reconciliation_active_repo
  ON appview_ingestion_reconciliation_requests
    (environment, source_generation, repo_did, trigger_seq)
  WHERE status IN ('pending', 'leased');

SELECT EXISTS (
  SELECT 1 FROM pg_class index_relation
  JOIN pg_index index_state ON index_state.indexrelid = index_relation.oid
  WHERE index_relation.oid = to_regclass('public.idx_appview_ingestion_inbox_terminal_barrier')
    AND NOT index_state.indisvalid
) AS index_is_invalid \gset
\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS public.idx_appview_ingestion_inbox_terminal_barrier;
\endif
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_appview_ingestion_inbox_terminal_barrier
  ON appview_ingestion_inbox (environment, source_generation, seq)
  WHERE status != 'applied' AND reconciled_at IS NULL;

SELECT EXISTS (
  SELECT 1 FROM pg_class index_relation
  JOIN pg_index index_state ON index_state.indexrelid = index_relation.oid
  WHERE index_relation.oid = to_regclass('public.idx_first_page_cache_publication_viewer')
    AND NOT index_state.indisvalid
) AS index_is_invalid \gset
\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS public.idx_first_page_cache_publication_viewer;
\endif
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_first_page_cache_publication_viewer
  ON first_page_cache (publication_id, viewer_did);

DO $$
DECLARE
  invalid_indexes TEXT;
BEGIN
  SELECT string_agg(index_relation.relname, ', ' ORDER BY index_relation.relname)
  INTO invalid_indexes
  FROM pg_class index_relation
  JOIN pg_index index_state ON index_state.indexrelid = index_relation.oid
  WHERE index_relation.relnamespace = 'public'::regnamespace
    AND index_relation.relname = ANY(ARRAY[
    'idx_appview_ingestion_inbox_ready',
    'idx_appview_ingestion_inbox_expired_lease',
    'idx_appview_ingestion_reconciliation_ready',
    'idx_appview_ingestion_reconciliation_expired_lease',
    'idx_appview_ingestion_reconciliation_active_repo',
    'idx_appview_ingestion_inbox_terminal_barrier',
    'idx_first_page_cache_publication_viewer'
  ])
    AND NOT index_state.indisvalid;

  IF invalid_indexes IS NOT NULL THEN
    RAISE EXCEPTION 'invalid Jetstream V2 drain indexes remain: %', invalid_indexes;
  END IF;
END
$$;
