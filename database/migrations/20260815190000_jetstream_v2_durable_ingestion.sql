-- Durable Jetstream V2 intake, replay, projection, and incident state.
--
-- `appview_ingestion_checkpoints` is intentionally not reused here. It is the
-- per-repository/per-collection reconciliation checkpoint table. A Jetstream V2
-- sequence is scoped to an exact host, method, filter set, and source generation.

CREATE TABLE IF NOT EXISTS appview_jetstream_checkpoints (
  environment TEXT NOT NULL,
  source_generation TEXT NOT NULL,
  source_host TEXT NOT NULL,
  stream_nsid TEXT NOT NULL,
  filter_fingerprint TEXT NOT NULL,
  cursor_kind TEXT NOT NULL CHECK (cursor_kind IN ('jetstream_v2_seq')),
  last_staged_seq BIGINT,
  last_staged_event_at TIMESTAMPTZ,
  last_staged_at TIMESTAMPTZ,
  last_applied_seq BIGINT,
  last_applied_event_at TIMESTAMPTZ,
  last_applied_at TIMESTAMPTZ,
  last_reconciled_repo_rev TEXT,
  last_reconciled_at TIMESTAMPTZ,
  replay_state TEXT NOT NULL DEFAULT 'idle'
    CHECK (replay_state IN ('idle', 'replaying', 'live', 'paused_budget', 'failed')),
  replay_after_seq BIGINT,
  replay_sealed_seq BIGINT,
  replay_bytes_downloaded BIGINT NOT NULL DEFAULT 0,
  replay_retry_count INTEGER NOT NULL DEFAULT 0,
  replay_range_resume_count INTEGER NOT NULL DEFAULT 0,
  replay_last_progress_at TIMESTAMPTZ,
  replay_etag TEXT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (environment, source_generation),
  CHECK (last_staged_seq IS NULL OR last_staged_seq >= 0),
  CHECK (last_applied_seq IS NULL OR last_applied_seq >= 0),
  CHECK (last_applied_seq IS NULL OR last_staged_seq IS NULL OR last_applied_seq <= last_staged_seq),
  CHECK (replay_after_seq IS NULL OR replay_after_seq >= 0),
  CHECK (replay_sealed_seq IS NULL OR replay_sealed_seq >= 0),
  CHECK (replay_bytes_downloaded >= 0),
  CHECK (replay_retry_count >= 0),
  CHECK (replay_range_resume_count >= 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_appview_jetstream_checkpoint_identity
  ON appview_jetstream_checkpoints
    (environment, source_host, stream_nsid, filter_fingerprint, cursor_kind, source_generation);
CREATE INDEX IF NOT EXISTS idx_appview_jetstream_checkpoint_updated
  ON appview_jetstream_checkpoints (environment, updated_at DESC);

COMMENT ON TABLE appview_jetstream_checkpoints IS
  'Global Jetstream V2 durability checkpoints. A source generation is bound to one host, NSID, filter fingerprint, and cursor kind.';
COMMENT ON COLUMN appview_jetstream_checkpoints.last_staged_seq IS
  'Highest V2 sequence transactionally staged in appview_ingestion_inbox; this is the live/replay resume authority.';
COMMENT ON COLUMN appview_jetstream_checkpoints.last_applied_seq IS
  'Terminal-prefix watermark: the highest staged event below which every retained event is applied or otherwise terminal. Jetstream sequences are sparse.';

CREATE TABLE IF NOT EXISTS appview_ingestion_inbox (
  environment TEXT NOT NULL,
  source_generation TEXT NOT NULL,
  seq BIGINT NOT NULL,
  source_host TEXT NOT NULL,
  cursor_kind TEXT NOT NULL CHECK (cursor_kind IN ('jetstream_v2_seq')),
  event_kind TEXT NOT NULL,
  repo_did TEXT NOT NULL,
  collection TEXT,
  operation TEXT,
  repo_rev TEXT,
  record_key TEXT,
  record_cid TEXT,
  payload JSONB NOT NULL,
  event_time TIMESTAMPTZ NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'leased', 'retry', 'applied', 'dead_letter')),
  attempt_count INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  lease_owner TEXT,
  lease_token TEXT,
  lease_expires_at TIMESTAMPTZ,
  failure_category TEXT,
  failure_reason TEXT,
  staged_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  applied_at TIMESTAMPTZ,
  dead_lettered_at TIMESTAMPTZ,
  reconciled_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,
  PRIMARY KEY (environment, source_generation, seq),
  CHECK (seq >= 0),
  CHECK (attempt_count >= 0),
  CHECK (
    (status = 'leased' AND lease_owner IS NOT NULL AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)
    OR status != 'leased'
  ),
  CHECK (status != 'applied' OR applied_at IS NOT NULL),
  CHECK (status != 'dead_letter' OR dead_lettered_at IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_appview_ingestion_inbox_claim
  ON appview_ingestion_inbox
    (environment, source_generation, status, next_attempt_at, seq)
  WHERE status IN ('pending', 'leased', 'retry');
CREATE INDEX IF NOT EXISTS idx_appview_ingestion_inbox_repo_fifo
  ON appview_ingestion_inbox
    (environment, source_generation, repo_did, seq)
  WHERE status IN ('pending', 'leased', 'retry');
CREATE INDEX IF NOT EXISTS idx_appview_ingestion_inbox_expiry
  ON appview_ingestion_inbox (environment, expires_at)
  WHERE expires_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_appview_ingestion_inbox_dead_letter
  ON appview_ingestion_inbox (environment, dead_lettered_at DESC)
  WHERE status = 'dead_letter';

COMMENT ON TABLE appview_ingestion_inbox IS
  'Idempotent Jetstream V2 event inbox. Inclusive replay duplicates conflict on environment, source generation, and sequence.';

CREATE TABLE IF NOT EXISTS appview_ingestion_replay_usage (
  environment TEXT NOT NULL,
  source_generation TEXT NOT NULL,
  bucket_started_at TIMESTAMPTZ NOT NULL,
  bytes_downloaded BIGINT NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (environment, source_generation, bucket_started_at),
  CHECK (bytes_downloaded >= 0),
  CHECK (bucket_started_at = date_trunc('minute', bucket_started_at))
);
CREATE INDEX IF NOT EXISTS idx_appview_ingestion_replay_usage_window
  ON appview_ingestion_replay_usage (environment, bucket_started_at DESC);

COMMENT ON TABLE appview_ingestion_replay_usage IS
  'Durable minute archive-download usage buckets used to enforce exact rolling replay budgets across restarts.';

CREATE TABLE IF NOT EXISTS appview_ingestion_incidents (
  environment TEXT NOT NULL,
  id TEXT NOT NULL,
  source_generation TEXT,
  source_host TEXT,
  source TEXT NOT NULL,
  cursor_kind TEXT NOT NULL,
  start_cursor BIGINT,
  end_cursor BIGINT,
  category TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'recovering', 'verification_required', 'resolved', 'ignored')),
  occurrence_count BIGINT NOT NULL DEFAULT 1,
  first_detected_at TIMESTAMPTZ NOT NULL,
  last_detected_at TIMESTAMPTZ NOT NULL,
  last_error TEXT,
  replay_state TEXT,
  replay_bytes_downloaded BIGINT NOT NULL DEFAULT 0,
  replay_retry_count INTEGER NOT NULL DEFAULT 0,
  replay_range_resume_count INTEGER NOT NULL DEFAULT 0,
  replay_sealed_seq BIGINT,
  recovered_through_cursor BIGINT,
  verification_evidence JSONB NOT NULL DEFAULT '{}'::jsonb,
  resolved_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL,
  version INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (environment, id),
  CHECK (start_cursor IS NULL OR start_cursor >= 0),
  CHECK (end_cursor IS NULL OR end_cursor >= 0),
  CHECK (start_cursor IS NULL OR end_cursor IS NULL OR start_cursor <= end_cursor),
  CHECK (occurrence_count > 0),
  CHECK (replay_bytes_downloaded >= 0),
  CHECK (replay_retry_count >= 0),
  CHECK (replay_range_resume_count >= 0),
  CHECK (version >= 0),
  CHECK (status NOT IN ('resolved', 'ignored') OR resolved_at IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_appview_ingestion_incidents_active
  ON appview_ingestion_incidents
    (environment, source, source_generation, source_host, cursor_kind, category, last_detected_at DESC)
  WHERE status IN ('open', 'recovering', 'verification_required');
CREATE INDEX IF NOT EXISTS idx_appview_ingestion_incidents_recent
  ON appview_ingestion_incidents (environment, last_detected_at DESC, id DESC);

CREATE TABLE IF NOT EXISTS appview_ingestion_incident_gaps (
  environment TEXT NOT NULL,
  incident_id TEXT NOT NULL,
  gap_id TEXT NOT NULL,
  linked_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (environment, incident_id, gap_id),
  FOREIGN KEY (environment, incident_id)
    REFERENCES appview_ingestion_incidents(environment, id) ON DELETE CASCADE,
  FOREIGN KEY (environment, gap_id)
    REFERENCES appview_ingestion_gaps(environment, id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS idx_appview_ingestion_incident_gaps_gap
  ON appview_ingestion_incident_gaps (environment, gap_id);

COMMENT ON TABLE appview_ingestion_incident_gaps IS
  'Links consolidated incidents to immutable legacy gap signals; legacy gap rows are never deleted during consolidation.';

-- Existing lifecycle cleanup may delete expired gap rows. A linked legacy signal is audit
-- evidence and must survive cleanup without causing the entire cleanup transaction to fail.
CREATE OR REPLACE FUNCTION appview_preserve_linked_ingestion_gap()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM appview_ingestion_incident_gaps
    WHERE environment = OLD.environment AND gap_id = OLD.id
  ) THEN
    RETURN NULL;
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS appview_preserve_linked_ingestion_gap_trigger
  ON appview_ingestion_gaps;
CREATE TRIGGER appview_preserve_linked_ingestion_gap_trigger
BEFORE DELETE ON appview_ingestion_gaps
FOR EACH ROW EXECUTE FUNCTION appview_preserve_linked_ingestion_gap();

CREATE TABLE IF NOT EXISTS appview_ingestion_leases (
  environment TEXT NOT NULL,
  lease_name TEXT NOT NULL,
  source_generation TEXT NOT NULL,
  owner_id TEXT NOT NULL,
  fencing_token BIGINT NOT NULL,
  acquired_at TIMESTAMPTZ NOT NULL,
  lease_expires_at TIMESTAMPTZ NOT NULL,
  released_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (environment, lease_name),
  CHECK (fencing_token > 0),
  CHECK (lease_expires_at > acquired_at)
);
CREATE INDEX IF NOT EXISTS idx_appview_ingestion_leases_expiry
  ON appview_ingestion_leases (environment, lease_expires_at);

COMMENT ON TABLE appview_ingestion_leases IS
  'Single-writer leases with monotonically increasing fencing tokens. Writers must include the current token in protected updates.';

CREATE TABLE IF NOT EXISTS appview_ingestion_reconciliation_requests (
  environment TEXT NOT NULL,
  id TEXT NOT NULL,
  source_generation TEXT NOT NULL,
  repo_did TEXT NOT NULL,
  reason TEXT NOT NULL,
  trigger_seq BIGINT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'leased', 'completed', 'failed')),
  attempt_count INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  lease_owner TEXT,
  lease_token TEXT,
  lease_expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  completed_at TIMESTAMPTZ,
  PRIMARY KEY (environment, id),
  UNIQUE (environment, source_generation, repo_did, trigger_seq, reason),
  CHECK (trigger_seq >= 0),
  CHECK (attempt_count >= 0),
  CHECK (
    (status = 'leased' AND lease_owner IS NOT NULL AND lease_token IS NOT NULL AND lease_expires_at IS NOT NULL)
    OR status != 'leased'
  )
);
CREATE INDEX IF NOT EXISTS idx_appview_ingestion_reconciliation_claim
  ON appview_ingestion_reconciliation_requests
    (environment, status, next_attempt_at, trigger_seq)
  WHERE status IN ('pending', 'leased');

-- Incident transitions are low-volume and should wake the Operations SSE consumers. Inbox and
-- checkpoint writes are deliberately excluded because they are high-frequency telemetry.
DROP TRIGGER IF EXISTS operations_change_event_trigger ON appview_ingestion_incidents;
CREATE TRIGGER operations_change_event_trigger
AFTER INSERT OR UPDATE ON appview_ingestion_incidents
FOR EACH ROW EXECUTE FUNCTION operations_capture_change_event('ingestion_incident');

DO $$
DECLARE table_name TEXT;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'appview_jetstream_checkpoints', 'appview_ingestion_inbox',
    'appview_ingestion_replay_usage', 'appview_ingestion_incidents',
    'appview_ingestion_incident_gaps', 'appview_ingestion_leases',
    'appview_ingestion_reconciliation_requests'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', table_name);
    EXECUTE format('REVOKE ALL ON TABLE %I FROM anon, authenticated', table_name);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE %I TO service_role', table_name);
  END LOOP;
END $$;

REVOKE ALL ON FUNCTION appview_preserve_linked_ingestion_gap() FROM PUBLIC;
