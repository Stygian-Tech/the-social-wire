-- Durable page checkpoints must survive worker and database restarts.
SET LOCAL lock_timeout = '5s';
ALTER TABLE appview_ingestion_inbox ADD COLUMN IF NOT EXISTS recovery_state TEXT;
ALTER TABLE appview_ingestion_reconciliation_requests ADD COLUMN IF NOT EXISTS recovery_state TEXT;
CREATE TABLE IF NOT EXISTS appview_repository_recovery_records (
  environment TEXT NOT NULL,
  source_generation TEXT NOT NULL,
  recovery_key TEXT NOT NULL,
  sync_sequence BIGINT,
  request_id TEXT,
  uri TEXT NOT NULL,
  PRIMARY KEY (environment, source_generation, recovery_key, uri),
  CHECK ((sync_sequence IS NULL) <> (request_id IS NULL)),
  FOREIGN KEY (environment, source_generation, sync_sequence)
    REFERENCES appview_ingestion_inbox (environment, source_generation, seq) ON DELETE CASCADE,
  FOREIGN KEY (environment, request_id)
    REFERENCES appview_ingestion_reconciliation_requests (environment, id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS appview_repository_recovery_request_idx
  ON appview_repository_recovery_records (environment, request_id, source_generation, recovery_key, uri) WHERE request_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS appview_repository_recovery_sync_idx
  ON appview_repository_recovery_records (environment, source_generation, sync_sequence, recovery_key, uri)
  WHERE sync_sequence IS NOT NULL;
