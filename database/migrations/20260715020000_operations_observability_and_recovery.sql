-- TSW-25: durable operational telemetry, health, gap, backfill, alert, and audit state.

CREATE TABLE IF NOT EXISTS operations_service_state (
  service TEXT NOT NULL,
  environment TEXT NOT NULL,
  instance_id TEXT NOT NULL,
  liveness TEXT NOT NULL,
  readiness TEXT NOT NULL,
  freshness TEXT NOT NULL,
  completeness TEXT NOT NULL,
  dependency_state JSONB NOT NULL DEFAULT '{}'::jsonb,
  version TEXT,
  started_at TIMESTAMPTZ NOT NULL,
  heartbeat_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (service, environment, instance_id)
);
CREATE INDEX IF NOT EXISTS idx_operations_service_state_heartbeat ON operations_service_state (heartbeat_at DESC);

CREATE TABLE IF NOT EXISTS operations_metric_rollups (
  bucket_start TIMESTAMPTZ NOT NULL,
  metric_name TEXT NOT NULL,
  dimensions_hash TEXT NOT NULL,
  dimensions JSONB NOT NULL DEFAULT '{}'::jsonb,
  sample_count BIGINT NOT NULL DEFAULT 0,
  value_sum DOUBLE PRECISION NOT NULL DEFAULT 0,
  value_min DOUBLE PRECISION,
  value_max DOUBLE PRECISION,
  histogram_buckets JSONB NOT NULL DEFAULT '{}'::jsonb,
  expires_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (bucket_start, metric_name, dimensions_hash)
);
CREATE INDEX IF NOT EXISTS idx_operations_metric_rollups_lookup ON operations_metric_rollups (metric_name, bucket_start DESC);
CREATE INDEX IF NOT EXISTS idx_operations_metric_rollups_expiry ON operations_metric_rollups (expires_at);

CREATE TABLE IF NOT EXISTS operations_trace_spans (
  id TEXT PRIMARY KEY,
  trace_id TEXT NOT NULL,
  parent_span_id TEXT,
  service TEXT NOT NULL,
  name TEXT NOT NULL,
  started_at TIMESTAMPTZ NOT NULL,
  duration_ms DOUBLE PRECISION NOT NULL,
  status TEXT NOT NULL,
  attributes JSONB NOT NULL DEFAULT '{}'::jsonb,
  expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_operations_trace_spans_trace ON operations_trace_spans (trace_id, started_at);
CREATE INDEX IF NOT EXISTS idx_operations_trace_spans_recent ON operations_trace_spans (started_at DESC);

CREATE TABLE IF NOT EXISTS operations_events (
  id TEXT PRIMARY KEY,
  service TEXT NOT NULL,
  environment TEXT NOT NULL,
  instance_id TEXT NOT NULL,
  event_name TEXT NOT NULL,
  occurred_at TIMESTAMPTZ NOT NULL,
  request_id TEXT,
  trace_id TEXT,
  attributes JSONB NOT NULL DEFAULT '{}'::jsonb,
  expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_operations_events_name_time ON operations_events (event_name, occurred_at DESC);

CREATE TABLE IF NOT EXISTS operations_audit_events (
  id TEXT PRIMARY KEY,
  operator_did TEXT NOT NULL,
  action TEXT NOT NULL,
  target_type TEXT NOT NULL,
  target_id TEXT,
  note TEXT,
  occurred_at TIMESTAMPTZ NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_operations_audit_events_time ON operations_audit_events (occurred_at DESC);

CREATE TABLE IF NOT EXISTS appview_ingestion_stream_state (
  source TEXT PRIMARY KEY,
  connection_state TEXT NOT NULL DEFAULT 'unknown',
  connected_at TIMESTAMPTZ,
  last_disconnect_at TIMESTAMPTZ,
  last_disconnect_reason TEXT,
  last_received_cursor BIGINT,
  last_received_event_at TIMESTAMPTZ,
  last_received_at TIMESTAMPTZ,
  last_committed_cursor BIGINT,
  last_committed_event_at TIMESTAMPTZ,
  last_committed_at TIMESTAMPTZ,
  queue_depth INTEGER NOT NULL DEFAULT 0,
  heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS appview_ingestion_gaps (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  start_cursor BIGINT,
  end_cursor BIGINT,
  start_time TIMESTAMPTZ,
  end_time TIMESTAMPTZ,
  reason TEXT NOT NULL,
  status TEXT NOT NULL,
  collections JSONB NOT NULL DEFAULT '[]'::jsonb,
  detected_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  backfill_job_id TEXT,
  discovered_count INTEGER NOT NULL DEFAULT 0,
  processed_count INTEGER NOT NULL DEFAULT 0,
  failed_count INTEGER NOT NULL DEFAULT 0,
  reconciled_count INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_appview_ingestion_gaps_status ON appview_ingestion_gaps (status, detected_at DESC);

CREATE TABLE IF NOT EXISTS appview_recovery_failures (
  id TEXT PRIMARY KEY,
  job_id TEXT,
  source TEXT NOT NULL,
  record_identifier_hash TEXT NOT NULL,
  collection TEXT,
  operation TEXT,
  cursor BIGINT,
  error_type TEXT NOT NULL,
  retry_count INTEGER NOT NULL DEFAULT 0,
  first_failed_at TIMESTAMPTZ NOT NULL,
  last_failed_at TIMESTAMPTZ NOT NULL,
  resolved_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_appview_recovery_failures_open ON appview_recovery_failures (resolved_at, last_failed_at DESC);

CREATE TABLE IF NOT EXISTS appview_backfill_jobs (
  id TEXT PRIMARY KEY,
  gap_id TEXT REFERENCES appview_ingestion_gaps(id) ON DELETE SET NULL,
  source_mode TEXT NOT NULL,
  status TEXT NOT NULL,
  start_cursor BIGINT,
  end_cursor BIGINT,
  checkpoint_cursor BIGINT,
  collections JSONB NOT NULL DEFAULT '[]'::jsonb,
  author_dids JSONB NOT NULL DEFAULT '[]'::jsonb,
  batch_size INTEGER NOT NULL,
  rate_limit INTEGER NOT NULL,
  max_concurrency INTEGER NOT NULL,
  estimated_count INTEGER NOT NULL DEFAULT 0,
  processed_count INTEGER NOT NULL DEFAULT 0,
  failed_count INTEGER NOT NULL DEFAULT 0,
  reconciled_count INTEGER NOT NULL DEFAULT 0,
  requested_by_did TEXT NOT NULL,
  audit_note TEXT NOT NULL,
  lease_owner TEXT,
  lease_expires_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  completed_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_appview_backfill_jobs_claim ON appview_backfill_jobs (status, lease_expires_at, created_at);

ALTER TABLE appview_ingestion_gaps
  ADD CONSTRAINT appview_ingestion_gaps_backfill_fk
  FOREIGN KEY (backfill_job_id) REFERENCES appview_backfill_jobs(id) ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS operations_alerts (
  id TEXT PRIMARY KEY,
  rule TEXT NOT NULL,
  severity TEXT NOT NULL,
  status TEXT NOT NULL,
  summary TEXT NOT NULL,
  evidence JSONB NOT NULL DEFAULT '{}'::jsonb,
  runbook_slug TEXT NOT NULL,
  opened_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  acknowledged_by_did TEXT,
  resolved_by_did TEXT,
  delivery_attempts INTEGER NOT NULL DEFAULT 0,
  last_delivery_error TEXT
);
CREATE INDEX IF NOT EXISTS idx_operations_alerts_status ON operations_alerts (status, opened_at DESC);

-- Seed the global cursor conservatively from the latest legacy event timestamp. The worker
-- rewinds another 30 seconds on the first upgraded connection, so replay overlap is idempotent.
INSERT INTO appview_ingestion_stream_state (
  source,
  connection_state,
  last_received_cursor,
  last_received_event_at,
  last_received_at,
  heartbeat_at
)
SELECT
  'jetstream',
  'unknown',
  (EXTRACT(EPOCH FROM MAX(event_time)) * 1000000)::BIGINT,
  MAX(event_time),
  MAX(observed_at),
  now()
FROM appview_ingestion_checkpoints
WHERE source = 'jetstream' AND event_time IS NOT NULL
HAVING MAX(event_time) IS NOT NULL
ON CONFLICT (source) DO NOTHING;

COMMENT ON TABLE appview_ingestion_stream_state IS 'Durable received and committed Jetstream time_us cursors; committed cursor is the replay authority.';
COMMENT ON TABLE operations_audit_events IS 'Immutable operator control-plane audit history. Never stores credentials or record bodies.';
