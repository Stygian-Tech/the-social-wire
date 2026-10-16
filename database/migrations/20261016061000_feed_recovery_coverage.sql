-- Preserve the existing presentation-safe health shape and legacy recovery
-- semantics while including the independently checkpointed automatic repair lane.
CREATE INDEX IF NOT EXISTS ingestion_recovery_controllers_issue_idx
 ON ingestion_recovery_controllers(environment,status,updated_at)
 WHERE status <> 'healthy' OR gap_after_seq IS NOT NULL;

CREATE OR REPLACE VIEW wire_publication_recovery_health AS
SELECT (
 EXISTS (
  SELECT 1 FROM (
   SELECT DISTINCT ON (environment, source_generation) replay_completed_at
   FROM wire_publication_signal_recovery_jobs
   ORDER BY environment, source_generation, inbox_initialized_at DESC
  ) latest WHERE replay_completed_at IS NULL
 )
 OR EXISTS (
  SELECT 1 FROM ingestion_recovery_controllers
  WHERE status <> 'healthy' OR gap_after_seq IS NOT NULL
 )
 OR EXISTS (
  SELECT 1 FROM ingestion_recovery_jobs WHERE status <> 'complete'
 )
 OR EXISTS (
  SELECT 1 FROM ingestion_poison_records WHERE status <> 'repaired'
 )
) AS recovering;
