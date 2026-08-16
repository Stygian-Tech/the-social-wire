-- socialwire:transaction=off
-- Records an explicit terminal disposition for commits outside the current AppView scope.

ALTER TABLE appview_ingestion_inbox
  ADD COLUMN IF NOT EXISTS filtered_scope_policy TEXT,
  ADD COLUMN IF NOT EXISTS filtered_scope_at TIMESTAMPTZ;

ALTER TABLE appview_ingestion_inbox
  DROP CONSTRAINT IF EXISTS appview_ingestion_inbox_status_check;
ALTER TABLE appview_ingestion_inbox
  ADD CONSTRAINT appview_ingestion_inbox_status_check
  CHECK (status IN ('pending', 'leased', 'retry', 'applied', 'dead_letter', 'filtered_scope'))
  NOT VALID;
ALTER TABLE appview_ingestion_inbox
  VALIDATE CONSTRAINT appview_ingestion_inbox_status_check;

ALTER TABLE appview_ingestion_inbox
  DROP CONSTRAINT IF EXISTS appview_ingestion_inbox_filtered_scope_evidence_check;
ALTER TABLE appview_ingestion_inbox
  ADD CONSTRAINT appview_ingestion_inbox_filtered_scope_evidence_check
  CHECK (
    (status = 'filtered_scope'
      AND filtered_scope_policy IS NOT NULL
      AND char_length(filtered_scope_policy) BETWEEN 1 AND 128
      AND filtered_scope_at IS NOT NULL
      AND applied_at IS NULL
      AND reconciled_at IS NULL)
    OR
    (status != 'filtered_scope'
      AND filtered_scope_policy IS NULL
      AND filtered_scope_at IS NULL)
  )
  NOT VALID;
ALTER TABLE appview_ingestion_inbox
  VALIDATE CONSTRAINT appview_ingestion_inbox_filtered_scope_evidence_check;

COMMENT ON COLUMN appview_ingestion_inbox.filtered_scope_policy IS
  'Stable role-aware scope policy that classified this commit outside the desired projection scope.';
COMMENT ON COLUMN appview_ingestion_inbox.filtered_scope_at IS
  'Time the DB-current scope decision terminalized this row without applying or reconciling it.';

COMMENT ON COLUMN appview_jetstream_checkpoints.last_staged_seq IS
  'Highest V2 sequence durably examined and admission-decided. The sequence may have been staged in the inbox or intentionally omitted by the current scope policy.';

-- The previous terminal-barrier index remains until every worker understands
-- filtered_scope. Dropping it in this migration would make the old query shape
-- full-scan during the rolling deployment window.
SELECT EXISTS (
  SELECT 1 FROM pg_class index_relation
  JOIN pg_index index_state ON index_state.indexrelid = index_relation.oid
  WHERE index_relation.oid = to_regclass('public.idx_appview_ingestion_inbox_terminal_barrier_v2')
    AND NOT index_state.indisvalid
) AS index_is_invalid \gset
\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS public.idx_appview_ingestion_inbox_terminal_barrier_v2;
\endif
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_appview_ingestion_inbox_terminal_barrier_v2
  ON appview_ingestion_inbox (environment, source_generation, seq)
  WHERE status NOT IN ('applied', 'filtered_scope') AND reconciled_at IS NULL;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_class index_relation
    JOIN pg_index index_state ON index_state.indexrelid = index_relation.oid
    WHERE index_relation.oid = to_regclass('public.idx_appview_ingestion_inbox_terminal_barrier_v2')
      AND NOT index_state.indisvalid
  ) THEN
    RAISE EXCEPTION 'invalid Jetstream V2 filtered terminal-barrier index remains';
  END IF;
END;
$$;
