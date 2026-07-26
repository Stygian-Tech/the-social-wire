-- TSW-38: environment isolation, trustworthy lifecycle state, Tap parity, and bounded retention.

BEGIN;

-- Preserve colliding legacy service replicas when multiple former environment names collapse into
-- the single quarantine key used by the environment-scoped primary key.
ALTER TABLE operations_service_state ADD COLUMN IF NOT EXISTS environment TEXT;
UPDATE operations_service_state
SET instance_id = instance_id || ':legacy:' || LEFT(MD5(COALESCE(environment, 'null')), 8)
WHERE environment IS NULL OR environment NOT IN ('dev', 'prod', '__legacy_unscoped__');

DO $$
DECLARE
  table_name TEXT;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'operations_service_state', 'operations_metric_rollups', 'operations_trace_spans', 'operations_events',
    'operations_audit_events', 'appview_ingestion_stream_state',
    'appview_jetstream_endpoints', 'operations_commands', 'appview_ingestion_gaps',
    'appview_recovery_failures', 'appview_backfill_jobs', 'operations_alerts'
  ] LOOP
    EXECUTE format(
      'ALTER TABLE %I ADD COLUMN IF NOT EXISTS environment TEXT', table_name);
    EXECUTE format(
      'UPDATE %I SET environment = ''__legacy_unscoped__''
       WHERE environment IS NULL OR environment NOT IN (''dev'', ''prod'', ''__legacy_unscoped__'')',
      table_name);
    EXECUTE format(
      'ALTER TABLE %I ALTER COLUMN environment SET NOT NULL', table_name);
    EXECUTE format(
      'ALTER TABLE %I ALTER COLUMN environment DROP DEFAULT', table_name);
  END LOOP;
END $$;

ALTER TABLE appview_ingestion_checkpoints
  ADD COLUMN IF NOT EXISTS environment TEXT;
UPDATE appview_ingestion_checkpoints
  SET environment = '__legacy_unscoped__'
  WHERE environment IS NULL OR environment NOT IN ('dev', 'prod', '__legacy_unscoped__');
ALTER TABLE appview_ingestion_checkpoints
  ALTER COLUMN environment SET NOT NULL;
ALTER TABLE appview_ingestion_checkpoints
  ALTER COLUMN environment DROP DEFAULT;
ALTER TABLE appview_ingestion_checkpoints
  DROP CONSTRAINT IF EXISTS appview_ingestion_checkpoints_pkey;
ALTER TABLE appview_ingestion_checkpoints
  ADD CONSTRAINT appview_ingestion_checkpoints_pkey
  PRIMARY KEY (environment, source, repo_did, collection);
DROP INDEX IF EXISTS idx_appview_ingestion_checkpoints_observed;
CREATE INDEX idx_appview_ingestion_checkpoints_observed
  ON appview_ingestion_checkpoints (environment, observed_at DESC);

ALTER TABLE appview_ingestion_stream_state ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE appview_ingestion_stream_state ADD COLUMN IF NOT EXISTS queue_capacity INTEGER;
ALTER TABLE appview_ingestion_stream_state ADD COLUMN IF NOT EXISTS queue_overflow_total BIGINT;
ALTER TABLE appview_ingestion_stream_state ADD COLUMN IF NOT EXISTS queue_observed_at TIMESTAMPTZ;
ALTER TABLE appview_ingestion_stream_state ADD COLUMN IF NOT EXISTS transport_heartbeat_at TIMESTAMPTZ;
ALTER TABLE appview_ingestion_stream_state ADD COLUMN IF NOT EXISTS last_indexed_mutation_at TIMESTAMPTZ;
ALTER TABLE appview_ingestion_stream_state ADD COLUMN IF NOT EXISTS projection_watermark TEXT;
ALTER TABLE appview_ingestion_stream_state ADD COLUMN IF NOT EXISTS validation_watermark TEXT;
UPDATE appview_ingestion_stream_state SET queue_depth = GREATEST(queue_depth, 0);
UPDATE appview_ingestion_stream_state SET queue_capacity = NULL WHERE queue_capacity <= 0;
UPDATE appview_ingestion_stream_state
  SET queue_overflow_total = GREATEST(queue_overflow_total, 0)
  WHERE queue_overflow_total IS NOT NULL;
ALTER TABLE appview_ingestion_stream_state
  DROP CONSTRAINT IF EXISTS appview_ingestion_stream_state_queue_depth_check;
ALTER TABLE appview_ingestion_stream_state
  ADD CONSTRAINT appview_ingestion_stream_state_queue_depth_check CHECK (queue_depth >= 0);
ALTER TABLE appview_ingestion_stream_state
  DROP CONSTRAINT IF EXISTS appview_ingestion_stream_state_queue_capacity_check;
ALTER TABLE appview_ingestion_stream_state
  ADD CONSTRAINT appview_ingestion_stream_state_queue_capacity_check
  CHECK (queue_capacity IS NULL OR queue_capacity > 0);
ALTER TABLE appview_ingestion_stream_state
  DROP CONSTRAINT IF EXISTS appview_ingestion_stream_state_queue_overflow_check;
ALTER TABLE appview_ingestion_stream_state
  ADD CONSTRAINT appview_ingestion_stream_state_queue_overflow_check
  CHECK (queue_overflow_total IS NULL OR queue_overflow_total >= 0);
ALTER TABLE appview_jetstream_endpoints ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE operations_commands ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE appview_ingestion_gaps ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE appview_backfill_jobs ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE operations_alerts ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE operations_alerts ADD COLUMN IF NOT EXISTS condition_key TEXT;

ALTER TABLE operations_commands ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;
ALTER TABLE operations_commands ADD COLUMN IF NOT EXISTS lease_expires_at TIMESTAMPTZ;
ALTER TABLE appview_ingestion_gaps ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;
ALTER TABLE appview_backfill_jobs ADD COLUMN IF NOT EXISTS idempotency_key TEXT;
ALTER TABLE appview_backfill_jobs ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;
ALTER TABLE appview_backfill_jobs ADD COLUMN IF NOT EXISTS verification_status TEXT NOT NULL DEFAULT 'required';
ALTER TABLE appview_backfill_jobs ADD COLUMN IF NOT EXISTS verification_reason TEXT;
ALTER TABLE appview_backfill_jobs ADD COLUMN IF NOT EXISTS scope_truncated BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE appview_backfill_jobs ADD COLUMN IF NOT EXISTS validation_watermark TEXT;
ALTER TABLE appview_backfill_jobs ADD COLUMN IF NOT EXISTS request_fingerprint TEXT;
ALTER TABLE appview_backfill_jobs ADD COLUMN IF NOT EXISTS request_fingerprint_expires_at TIMESTAMPTZ;
ALTER TABLE appview_backfill_jobs ADD COLUMN IF NOT EXISTS normalized_request_hash TEXT;
ALTER TABLE appview_backfill_jobs ADD COLUMN IF NOT EXISTS author_results JSONB NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE operations_alerts ADD COLUMN IF NOT EXISTS next_delivery_at TIMESTAMPTZ;
ALTER TABLE operations_alerts ADD COLUMN IF NOT EXISTS delivery_dead_lettered_at TIMESTAMPTZ;
ALTER TABLE operations_alerts ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;
ALTER TABLE operations_audit_events ADD COLUMN IF NOT EXISTS idempotency_key TEXT;
ALTER TABLE operations_audit_events ADD COLUMN IF NOT EXISTS request_id TEXT;
ALTER TABLE operations_audit_events ADD COLUMN IF NOT EXISTS expected_version INTEGER;
ALTER TABLE operations_audit_events ADD COLUMN IF NOT EXISTS before_state JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE operations_audit_events ADD COLUMN IF NOT EXISTS after_state JSONB NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE operations_audit_events ADD COLUMN IF NOT EXISTS outcome TEXT NOT NULL DEFAULT 'recorded';

UPDATE operations_commands
SET expires_at = COALESCE(completed_at, updated_at, created_at) + INTERVAL '365 days'
WHERE status IN ('completed', 'failed');
UPDATE operations_commands SET expires_at = created_at + INTERVAL '365 days' WHERE expires_at IS NULL;
UPDATE appview_ingestion_gaps
SET expires_at = updated_at + INTERVAL '365 days' WHERE status IN ('resolved', 'ignored');
UPDATE appview_ingestion_gaps SET expires_at = detected_at + INTERVAL '365 days' WHERE expires_at IS NULL;
UPDATE appview_backfill_jobs
SET expires_at = COALESCE(completed_at, updated_at, created_at) + INTERVAL '365 days'
WHERE status IN ('completed', 'failed', 'cancelled');
UPDATE appview_backfill_jobs SET expires_at = created_at + INTERVAL '365 days' WHERE expires_at IS NULL;
UPDATE operations_alerts
SET expires_at = updated_at + INTERVAL '365 days' WHERE status = 'resolved';
UPDATE operations_alerts SET expires_at = opened_at + INTERVAL '365 days' WHERE expires_at IS NULL;
UPDATE operations_audit_events SET expires_at = occurred_at + INTERVAL '365 days';
-- A pre-migration running command has no provable lease owner/expiry. Return it to the queue
-- rather than allowing an unowned worker to complete it after the integrity cutover.
UPDATE operations_commands
SET status = 'queued', claimed_by = NULL, lease_expires_at = NULL,
    updated_at = NOW(), version = version + 1
WHERE status = 'running' AND (claimed_by IS NULL OR lease_expires_at IS NULL);
UPDATE operations_alerts SET condition_key = rule WHERE condition_key IS NULL;
ALTER TABLE operations_alerts ALTER COLUMN condition_key SET NOT NULL;
ALTER TABLE operations_commands ALTER COLUMN audit_note DROP NOT NULL;
ALTER TABLE appview_backfill_jobs ALTER COLUMN audit_note DROP NOT NULL;
ALTER TABLE operations_commands ALTER COLUMN expires_at SET DEFAULT (NOW() + INTERVAL '365 days');
ALTER TABLE appview_ingestion_gaps ALTER COLUMN expires_at SET DEFAULT (NOW() + INTERVAL '365 days');
ALTER TABLE appview_backfill_jobs ALTER COLUMN expires_at SET DEFAULT (NOW() + INTERVAL '365 days');
ALTER TABLE operations_alerts ALTER COLUMN expires_at SET DEFAULT (NOW() + INTERVAL '365 days');

-- Keep malformed legacy lifecycle rows out of every dev/prod query before introducing the
-- stronger constraints below. They remain available only in the explicit quarantine scope.
UPDATE operations_service_state
SET environment = '__legacy_unscoped__',
    instance_id = instance_id || ':invalid:' || environment
WHERE environment IN ('dev', 'prod') AND (
  liveness NOT IN ('healthy', 'degraded', 'unhealthy', 'unknown') OR
  readiness NOT IN ('healthy', 'degraded', 'unhealthy', 'unknown') OR
  freshness NOT IN ('healthy', 'degraded', 'unhealthy', 'unknown') OR
  completeness NOT IN ('healthy', 'degraded', 'unhealthy', 'unknown'));
UPDATE appview_ingestion_stream_state
SET environment = '__legacy_unscoped__'
WHERE environment IN ('dev', 'prod') AND (
  connection_state NOT IN ('connected', 'disconnected', 'reconnecting', 'unknown') OR
  version < 0 OR queue_depth < 0 OR
  (queue_capacity IS NOT NULL AND queue_capacity <= 0) OR
  (queue_overflow_total IS NOT NULL AND queue_overflow_total < 0));
UPDATE operations_commands
SET environment = '__legacy_unscoped__'
WHERE environment IN ('dev', 'prod') AND (
  action <> 'reconnect_jetstream' OR
  status NOT IN ('queued', 'running', 'completed', 'failed') OR version < 0);
UPDATE appview_ingestion_gaps
SET environment = '__legacy_unscoped__'
WHERE environment IN ('dev', 'prod') AND (
  status NOT IN ('suspected', 'confirmed', 'backfill_queued', 'backfilling',
    'verification_required', 'resolved', 'ignored') OR
  version < 0 OR discovered_count < 0 OR processed_count < 0 OR failed_count < 0 OR
  reconciled_count < 0 OR failed_count > processed_count OR
  reconciled_count > processed_count OR
  (start_cursor IS NOT NULL AND end_cursor IS NOT NULL AND start_cursor >= end_cursor));
UPDATE appview_backfill_jobs
SET environment = '__legacy_unscoped__'
WHERE environment IN ('dev', 'prod') AND (
  status NOT IN ('queued', 'running', 'paused', 'completed', 'failed', 'cancelled') OR
  source_mode NOT IN ('tap_verified_resync', 'jetstream_replay', 'pds_reconciliation') OR
  verification_status NOT IN ('pending', 'required', 'verified', 'failed') OR
  version < 0 OR estimated_count < 0 OR processed_count < 0 OR failed_count < 0 OR
  reconciled_count < 0 OR failed_count > processed_count OR
  reconciled_count > processed_count OR batch_size NOT BETWEEN 1 AND 10000 OR
  rate_limit NOT BETWEEN 1 AND 5000 OR max_concurrency NOT BETWEEN 1 AND 16 OR
  (source_mode <> 'pds_reconciliation' AND max_concurrency <> 1) OR
  (source_mode = 'jetstream_replay' AND
    (start_cursor IS NULL OR end_cursor IS NULL OR start_cursor >= end_cursor)) OR
  (start_cursor IS NOT NULL AND end_cursor IS NOT NULL AND start_cursor >= end_cursor) OR
  (checkpoint_cursor IS NOT NULL AND
    ((start_cursor IS NOT NULL AND checkpoint_cursor < start_cursor) OR
     (end_cursor IS NOT NULL AND checkpoint_cursor > end_cursor))));
UPDATE operations_alerts
SET environment = '__legacy_unscoped__'
WHERE environment IN ('dev', 'prod') AND (
  status NOT IN ('open', 'acknowledged', 'resolved') OR version < 0 OR
  delivery_attempts < 0);
UPDATE appview_backfill_jobs job
SET environment = '__legacy_unscoped__'
FROM appview_ingestion_gaps gap
WHERE job.gap_id = gap.id AND gap.environment = '__legacy_unscoped__';
UPDATE appview_ingestion_gaps gap
SET environment = '__legacy_unscoped__'
FROM appview_backfill_jobs job
WHERE gap.backfill_job_id = job.id AND job.environment = '__legacy_unscoped__';

ALTER TABLE operations_metric_rollups DROP CONSTRAINT IF EXISTS operations_metric_rollups_pkey;
ALTER TABLE operations_metric_rollups
  ADD CONSTRAINT operations_metric_rollups_pkey
  PRIMARY KEY (environment, bucket_start, metric_name, dimensions_hash);
ALTER TABLE appview_ingestion_stream_state DROP CONSTRAINT IF EXISTS appview_ingestion_stream_state_pkey;
ALTER TABLE appview_ingestion_stream_state
  ADD CONSTRAINT appview_ingestion_stream_state_pkey PRIMARY KEY (environment, source);
ALTER TABLE appview_jetstream_endpoints DROP CONSTRAINT IF EXISTS appview_jetstream_endpoints_pkey;
ALTER TABLE appview_jetstream_endpoints
  ADD CONSTRAINT appview_jetstream_endpoints_pkey PRIMARY KEY (environment, id);

ALTER TABLE appview_backfill_jobs DROP CONSTRAINT IF EXISTS appview_backfill_jobs_gap_id_fkey;
ALTER TABLE appview_ingestion_gaps DROP CONSTRAINT IF EXISTS appview_ingestion_gaps_backfill_fk;
ALTER TABLE operations_trace_spans DROP CONSTRAINT IF EXISTS operations_trace_spans_pkey;
ALTER TABLE operations_trace_spans
  ADD CONSTRAINT operations_trace_spans_pkey PRIMARY KEY (environment, id);
ALTER TABLE operations_events DROP CONSTRAINT IF EXISTS operations_events_pkey;
ALTER TABLE operations_events
  ADD CONSTRAINT operations_events_pkey PRIMARY KEY (environment, id);
ALTER TABLE operations_audit_events DROP CONSTRAINT IF EXISTS operations_audit_events_pkey;
ALTER TABLE operations_audit_events
  ADD CONSTRAINT operations_audit_events_pkey PRIMARY KEY (environment, id);
ALTER TABLE operations_commands DROP CONSTRAINT IF EXISTS operations_commands_pkey;
ALTER TABLE operations_commands
  ADD CONSTRAINT operations_commands_pkey PRIMARY KEY (environment, id);
ALTER TABLE appview_ingestion_gaps DROP CONSTRAINT IF EXISTS appview_ingestion_gaps_pkey;
ALTER TABLE appview_ingestion_gaps
  ADD CONSTRAINT appview_ingestion_gaps_pkey PRIMARY KEY (environment, id);
ALTER TABLE appview_recovery_failures DROP CONSTRAINT IF EXISTS appview_recovery_failures_pkey;
ALTER TABLE appview_recovery_failures
  ADD CONSTRAINT appview_recovery_failures_pkey PRIMARY KEY (environment, id);
ALTER TABLE appview_backfill_jobs DROP CONSTRAINT IF EXISTS appview_backfill_jobs_pkey;
ALTER TABLE appview_backfill_jobs
  ADD CONSTRAINT appview_backfill_jobs_pkey PRIMARY KEY (environment, id);
ALTER TABLE operations_alerts DROP CONSTRAINT IF EXISTS operations_alerts_pkey;
ALTER TABLE operations_alerts
  ADD CONSTRAINT operations_alerts_pkey PRIMARY KEY (environment, id);

CREATE UNIQUE INDEX IF NOT EXISTS idx_operations_commands_environment_id
  ON operations_commands (environment, id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_operations_gaps_environment_id
  ON appview_ingestion_gaps (environment, id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_operations_backfills_environment_id
  ON appview_backfill_jobs (environment, id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_operations_alerts_environment_id
  ON operations_alerts (environment, id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_operations_traces_environment_id
  ON operations_trace_spans (environment, id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_operations_events_environment_id
  ON operations_events (environment, id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_operations_audits_environment_id
  ON operations_audit_events (environment, id);

ALTER TABLE appview_backfill_jobs
  ADD CONSTRAINT appview_backfill_jobs_environment_gap_fk
  FOREIGN KEY (environment, gap_id)
  REFERENCES appview_ingestion_gaps(environment, id) ON DELETE SET NULL (gap_id);
ALTER TABLE appview_ingestion_gaps
  ADD CONSTRAINT appview_ingestion_gaps_environment_backfill_fk
  FOREIGN KEY (environment, backfill_job_id)
  REFERENCES appview_backfill_jobs(environment, id) ON DELETE SET NULL (backfill_job_id);

DROP INDEX IF EXISTS idx_operations_commands_one_active_action;
CREATE UNIQUE INDEX IF NOT EXISTS idx_operations_commands_one_active_action_env
  ON operations_commands (environment, action)
  WHERE environment <> '__legacy_unscoped__' AND status IN ('queued', 'running');
DROP INDEX IF EXISTS idx_operations_audit_idempotency;
CREATE UNIQUE INDEX IF NOT EXISTS idx_operations_backfill_idempotency
  ON appview_backfill_jobs (environment, idempotency_key)
  WHERE environment <> '__legacy_unscoped__' AND idempotency_key IS NOT NULL;
DROP INDEX IF EXISTS idx_operations_alert_open_rule;
CREATE UNIQUE INDEX IF NOT EXISTS idx_operations_alert_open_condition
  ON operations_alerts (environment, condition_key)
  WHERE environment <> '__legacy_unscoped__' AND status != 'resolved';
CREATE INDEX IF NOT EXISTS idx_operations_active_gaps
  ON appview_ingestion_gaps (environment, detected_at DESC, id DESC)
  WHERE status NOT IN ('resolved', 'ignored');
CREATE INDEX IF NOT EXISTS idx_operations_gap_history
  ON appview_ingestion_gaps (environment, detected_at DESC, id DESC)
  WHERE status IN ('resolved', 'ignored');
CREATE INDEX IF NOT EXISTS idx_operations_active_backfills
  ON appview_backfill_jobs (environment, created_at DESC, id DESC)
  WHERE status IN ('queued', 'running', 'paused');
CREATE INDEX IF NOT EXISTS idx_operations_attention_backfills
  ON appview_backfill_jobs (environment, created_at DESC, id DESC)
  WHERE status IN ('failed', 'cancelled');
CREATE INDEX IF NOT EXISTS idx_operations_backfill_history
  ON appview_backfill_jobs (environment, created_at DESC, id DESC)
  WHERE status = 'completed';
CREATE INDEX IF NOT EXISTS idx_operations_alert_delivery
  ON operations_alerts (environment, next_delivery_at)
  WHERE status != 'resolved' AND delivery_dead_lettered_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_operations_service_state_active
  ON operations_service_state (environment, heartbeat_at DESC, service);

-- Idempotency results are durable operational state, separate from the append-only audit log.
-- A key is bound to one action and target; rejected attempts never reserve the key.
CREATE TABLE IF NOT EXISTS operations_idempotency_records (
  environment TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  action TEXT NOT NULL,
  target_type TEXT NOT NULL,
  target_id TEXT,
  outcome TEXT NOT NULL CHECK (outcome IN ('queued', 'succeeded')),
  request_fingerprint TEXT NOT NULL,
  result_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '365 days'),
  PRIMARY KEY (environment, idempotency_key)
);
ALTER TABLE operations_idempotency_records
  ADD COLUMN IF NOT EXISTS request_fingerprint TEXT;
ALTER TABLE operations_idempotency_records
  ADD COLUMN IF NOT EXISTS result_payload JSONB NOT NULL DEFAULT '{}'::jsonb;
UPDATE operations_idempotency_records
SET request_fingerprint = 'legacy-unverifiable',
    result_payload = jsonb_build_object(
      'targetId', COALESCE(target_id, ''), 'outcome', outcome)
WHERE request_fingerprint IS NULL;
ALTER TABLE operations_idempotency_records ALTER COLUMN request_fingerprint SET NOT NULL;
WITH terminal_targets AS (
  SELECT environment, 'command'::text AS target_type, id AS target_id,
    COALESCE(completed_at, updated_at, created_at) AS terminal_at
  FROM operations_commands WHERE status IN ('completed', 'failed')
  UNION ALL
  SELECT environment, 'gap', id, updated_at
  FROM appview_ingestion_gaps WHERE status IN ('resolved', 'ignored')
  UNION ALL
  SELECT environment, 'backfill', id, COALESCE(completed_at, updated_at, created_at)
  FROM appview_backfill_jobs WHERE status IN ('completed', 'failed', 'cancelled')
  UNION ALL
  SELECT environment, 'alert', id, updated_at
  FROM operations_alerts WHERE status = 'resolved'
)
UPDATE operations_audit_events AS audit
SET expires_at = target.terminal_at + INTERVAL '365 days'
FROM terminal_targets AS target
WHERE audit.environment = target.environment
  AND audit.target_type = target.target_type AND audit.target_id = target.target_id;
WITH terminal_targets AS (
  SELECT environment, 'command'::text AS target_type, id AS target_id,
    COALESCE(completed_at, updated_at, created_at) AS terminal_at
  FROM operations_commands WHERE status IN ('completed', 'failed')
  UNION ALL
  SELECT environment, 'gap', id, updated_at
  FROM appview_ingestion_gaps WHERE status IN ('resolved', 'ignored')
  UNION ALL
  SELECT environment, 'backfill', id, COALESCE(completed_at, updated_at, created_at)
  FROM appview_backfill_jobs WHERE status IN ('completed', 'failed', 'cancelled')
  UNION ALL
  SELECT environment, 'alert', id, updated_at
  FROM operations_alerts WHERE status = 'resolved'
)
UPDATE operations_idempotency_records AS idempotency
SET expires_at = target.terminal_at + INTERVAL '365 days'
FROM terminal_targets AS target
WHERE idempotency.environment = target.environment
  AND idempotency.target_type = target.target_type
  AND idempotency.target_id = target.target_id;
CREATE INDEX IF NOT EXISTS idx_operations_idempotency_expiry
  ON operations_idempotency_records (environment, expires_at);

CREATE TABLE IF NOT EXISTS operations_change_event_watermarks (
  environment TEXT PRIMARY KEY,
  latest_cursor BIGINT NOT NULL DEFAULT 0 CHECK (latest_cursor >= 0),
  earliest_available_cursor BIGINT NOT NULL DEFAULT 1 CHECK (earliest_available_cursor >= 1),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS operations_change_events (
  environment TEXT NOT NULL,
  cursor BIGINT NOT NULL CHECK (cursor > 0),
  event_type TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id TEXT,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '30 days'),
  PRIMARY KEY (environment, cursor)
);
CREATE INDEX IF NOT EXISTS idx_operations_change_events_replay
  ON operations_change_events (environment, cursor);
CREATE INDEX IF NOT EXISTS idx_operations_change_events_expiry
  ON operations_change_events (environment, expires_at, cursor);

CREATE OR REPLACE FUNCTION operations_append_change_event(
  target_environment TEXT,
  target_event_type TEXT,
  target_entity_type TEXT,
  target_entity_id TEXT,
  target_payload JSONB,
  target_occurred_at TIMESTAMPTZ DEFAULT NOW()
) RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE next_cursor BIGINT;
BEGIN
  IF target_environment IS NULL OR target_environment = '__legacy_unscoped__' THEN
    RETURN 0;
  END IF;
  INSERT INTO operations_change_event_watermarks (environment)
    VALUES (target_environment) ON CONFLICT (environment) DO NOTHING;
  UPDATE operations_change_event_watermarks
    SET latest_cursor = latest_cursor + 1, updated_at = target_occurred_at
    WHERE environment = target_environment
    RETURNING latest_cursor INTO next_cursor;
  INSERT INTO operations_change_events
    (environment, cursor, event_type, entity_type, entity_id, payload, occurred_at, expires_at)
  VALUES
    (target_environment, next_cursor, LEFT(target_event_type, 160),
     LEFT(target_entity_type, 64), target_entity_id, COALESCE(target_payload, '{}'::jsonb),
     target_occurred_at, target_occurred_at + INTERVAL '30 days');
  RETURN next_cursor;
END;
$$;

CREATE OR REPLACE FUNCTION operations_capture_change_event() RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  row_data JSONB := to_jsonb(NEW);
  target_environment TEXT := row_data->>'environment';
  target_id TEXT := COALESCE(
    row_data->>'id', row_data->>'source', row_data->>'service', row_data->>'condition_key');
  target_payload JSONB;
BEGIN
  target_payload := jsonb_strip_nulls(jsonb_build_object(
    'status', row_data->>'status',
    'version', row_data->>'version',
    'connectionState', row_data->>'connection_state',
    'liveness', row_data->>'liveness',
    'readiness', row_data->>'readiness',
    'freshness', row_data->>'freshness',
    'completeness', row_data->>'completeness',
    'updatedAt', COALESCE(row_data->>'updated_at', row_data->>'heartbeat_at')
  ));
  PERFORM operations_append_change_event(
    target_environment, TG_ARGV[0] || '.' || lower(TG_OP), TG_ARGV[0],
    target_id, target_payload, NOW());
  RETURN NEW;
END;
$$;

DO $$
DECLARE definition RECORD;
BEGIN
  -- Heartbeats and per-event ingestion checkpoints are coalesced by the Operations
  -- monitor. Row triggers here would create unbounded event volume.
  DROP TRIGGER IF EXISTS operations_change_event_trigger ON operations_service_state;
  DROP TRIGGER IF EXISTS operations_change_event_trigger ON appview_ingestion_stream_state;
  FOR definition IN SELECT * FROM (VALUES
    ('appview_jetstream_endpoints', 'endpoint'),
    ('operations_commands', 'command'),
    ('appview_ingestion_gaps', 'gap'),
    ('appview_backfill_jobs', 'job'),
    ('operations_alerts', 'alert')
  ) AS targets(table_name, entity_type)
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS operations_change_event_trigger ON %I',
      definition.table_name);
    EXECUTE format(
      'CREATE TRIGGER operations_change_event_trigger AFTER INSERT OR UPDATE ON %I
       FOR EACH ROW EXECUTE FUNCTION operations_capture_change_event(%L)',
      definition.table_name, definition.entity_type);
  END LOOP;
END $$;

DO $$ BEGIN
  ALTER TABLE appview_ingestion_gaps ADD CONSTRAINT appview_ingestion_gaps_status_check
    CHECK (status IN ('suspected', 'confirmed', 'backfill_queued', 'backfilling',
      'verification_required', 'resolved', 'ignored')) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE appview_ingestion_gaps ADD CONSTRAINT appview_ingestion_gaps_version_check
    CHECK (version >= 0) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE appview_ingestion_gaps ADD CONSTRAINT appview_ingestion_gaps_bounds_check
    CHECK (start_cursor IS NULL OR end_cursor IS NULL OR start_cursor < end_cursor) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE appview_ingestion_gaps ADD CONSTRAINT appview_ingestion_gaps_progress_check
    CHECK (discovered_count >= 0 AND processed_count >= 0 AND failed_count >= 0
      AND reconciled_count >= 0 AND failed_count <= processed_count
      AND reconciled_count <= processed_count) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE appview_backfill_jobs ADD CONSTRAINT appview_backfill_jobs_status_check
    CHECK (status IN ('queued', 'running', 'paused', 'completed', 'failed', 'cancelled')) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE appview_backfill_jobs ADD CONSTRAINT appview_backfill_jobs_source_mode_check
    CHECK (source_mode IN ('tap_verified_resync', 'jetstream_replay', 'pds_reconciliation')) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE appview_backfill_jobs ADD CONSTRAINT appview_backfill_jobs_verification_status_check
    CHECK (verification_status IN ('pending', 'required', 'verified', 'failed')) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE appview_backfill_jobs ADD CONSTRAINT appview_backfill_jobs_version_check
    CHECK (version >= 0) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE appview_backfill_jobs ADD CONSTRAINT appview_backfill_jobs_progress_check
    CHECK (estimated_count >= 0 AND processed_count >= 0 AND failed_count >= 0
      AND reconciled_count >= 0
      AND failed_count <= processed_count AND reconciled_count <= processed_count) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE appview_backfill_jobs ADD CONSTRAINT appview_backfill_jobs_bounds_check
    CHECK (batch_size BETWEEN 1 AND 10000 AND rate_limit BETWEEN 1 AND 5000
      AND max_concurrency BETWEEN 1 AND 16
      AND (source_mode = 'pds_reconciliation' OR max_concurrency = 1)
      AND (source_mode <> 'jetstream_replay' OR
        (start_cursor IS NOT NULL AND end_cursor IS NOT NULL AND start_cursor < end_cursor))
      AND (start_cursor IS NULL OR end_cursor IS NULL OR start_cursor < end_cursor)
      AND (checkpoint_cursor IS NULL OR
        ((start_cursor IS NULL OR checkpoint_cursor >= start_cursor)
          AND (end_cursor IS NULL OR checkpoint_cursor <= end_cursor)))) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE appview_backfill_jobs ADD CONSTRAINT appview_backfill_jobs_author_results_check
    CHECK (jsonb_typeof(author_results) = 'array') NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE appview_jetstream_endpoints ADD CONSTRAINT appview_jetstream_endpoints_version_check
    CHECK (version >= 0 AND connection_attempts >= 0 AND failover_count >= 0) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE operations_commands ADD CONSTRAINT operations_commands_version_check
    CHECK (version >= 0) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE operations_commands ADD CONSTRAINT operations_commands_status_check
    CHECK (status IN ('queued', 'running', 'completed', 'failed')) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE operations_commands ADD CONSTRAINT operations_commands_running_lease_check
    CHECK (status <> 'running' OR (claimed_by IS NOT NULL AND lease_expires_at IS NOT NULL))
    NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE operations_commands ADD CONSTRAINT operations_commands_action_check
    CHECK (action = 'reconnect_jetstream') NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE appview_ingestion_stream_state
    ADD CONSTRAINT appview_ingestion_stream_state_connection_check
    CHECK (connection_state IN ('connected', 'disconnected', 'reconnecting', 'unknown')) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE appview_ingestion_stream_state
    ADD CONSTRAINT appview_ingestion_stream_state_version_check
    CHECK (version >= 0) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE operations_service_state ADD CONSTRAINT operations_service_state_health_check
    CHECK (liveness IN ('healthy', 'degraded', 'unhealthy', 'unknown')
      AND readiness IN ('healthy', 'degraded', 'unhealthy', 'unknown')
      AND freshness IN ('healthy', 'degraded', 'unhealthy', 'unknown')
      AND completeness IN ('healthy', 'degraded', 'unhealthy', 'unknown')) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE operations_metric_rollups ADD CONSTRAINT operations_metric_rollups_values_check
    CHECK (sample_count >= 0
      AND (value_min IS NULL OR value_max IS NULL OR value_min <= value_max)
      AND (sample_count > 0 OR (value_min IS NULL AND value_max IS NULL))) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE operations_alerts ADD CONSTRAINT operations_alerts_status_check
    CHECK (status IN ('open', 'acknowledged', 'resolved')) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE operations_alerts ADD CONSTRAINT operations_alerts_version_check
    CHECK (version >= 0 AND delivery_attempts >= 0) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS appview_tap_repo_state (
  environment TEXT NOT NULL,
  repo_did TEXT NOT NULL,
  repo_rev TEXT,
  account_status TEXT NOT NULL DEFAULT 'active'
    CHECK (account_status IN ('active', 'takendown', 'suspended', 'deactivated', 'deleted')),
  pds_base TEXT,
  last_event_id BIGINT,
  last_event_live BOOLEAN NOT NULL DEFAULT FALSE,
  parity_status TEXT NOT NULL DEFAULT 'pending'
    CHECK (parity_status IN ('pending', 'matched', 'mismatch', 'lifecycle_observed', 'authoritative')),
  matched_event_count BIGINT NOT NULL DEFAULT 0 CHECK (matched_event_count >= 0),
  mismatched_event_count BIGINT NOT NULL DEFAULT 0 CHECK (mismatched_event_count >= 0),
  last_mismatch TEXT,
  last_indexed_at TIMESTAMPTZ,
  last_validated_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (environment, repo_did)
);
CREATE INDEX IF NOT EXISTS idx_appview_tap_repo_parity
  ON appview_tap_repo_state (environment, parity_status, updated_at DESC);

CREATE TABLE IF NOT EXISTS appview_tap_repository_registrations (
  environment TEXT NOT NULL,
  repo_did TEXT NOT NULL,
  is_registered BOOLEAN NOT NULL DEFAULT TRUE,
  registered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  removed_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (environment, repo_did)
);
CREATE INDEX IF NOT EXISTS idx_appview_tap_repository_registrations_active
  ON appview_tap_repository_registrations (environment, updated_at DESC, repo_did)
  WHERE is_registered = TRUE;

CREATE TABLE IF NOT EXISTS appview_tap_event_receipts (
  environment TEXT NOT NULL,
  event_id BIGINT NOT NULL,
  repo_did TEXT NOT NULL,
  event_type TEXT NOT NULL,
  processed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '30 days'),
  PRIMARY KEY (environment, event_id)
);
CREATE INDEX IF NOT EXISTS idx_appview_tap_event_receipts_expiry
  ON appview_tap_event_receipts (environment, expires_at);

CREATE TABLE IF NOT EXISTS appview_tap_parity_discrepancies (
  environment TEXT NOT NULL,
  event_id BIGINT NOT NULL,
  repo_did TEXT NOT NULL,
  uri TEXT NOT NULL,
  collection TEXT NOT NULL,
  mismatch_kind TEXT NOT NULL,
  expected_cid TEXT,
  observed_cid TEXT,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved')),
  opened_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at TIMESTAMPTZ,
  resolution_event_id BIGINT,
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '365 days'),
  PRIMARY KEY (environment, event_id)
);
CREATE INDEX IF NOT EXISTS idx_appview_tap_parity_discrepancies_open
  ON appview_tap_parity_discrepancies (environment, repo_did, uri, opened_at)
  WHERE status = 'open';

CREATE TABLE IF NOT EXISTS appview_projection_repair_outbox (
  id TEXT NOT NULL,
  environment TEXT NOT NULL,
  event_id BIGINT NOT NULL,
  uri TEXT NOT NULL,
  author_did TEXT NOT NULL,
  publication_site TEXT,
  action TEXT NOT NULL CHECK (action IN ('upsert', 'delete')),
  status TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'running', 'failed')),
  attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  lease_owner TEXT,
  lease_until TIMESTAMPTZ,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '30 days'),
  PRIMARY KEY (environment, id),
  UNIQUE (environment, event_id)
);
CREATE INDEX IF NOT EXISTS idx_appview_projection_repair_claim
  ON appview_projection_repair_outbox
    (environment, status, next_attempt_at, lease_until, created_at);
CREATE INDEX IF NOT EXISTS idx_appview_projection_repair_cleanup
  ON appview_projection_repair_outbox (environment, status, expires_at, id);

CREATE INDEX IF NOT EXISTS idx_read_marks_cleanup
  ON read_marks (created_at, viewer_did, subject_uri);
CREATE INDEX IF NOT EXISTS idx_unread_counts_cache_cleanup
  ON unread_counts_cache (expires_at, viewer_did, publication_id);
CREATE INDEX IF NOT EXISTS idx_first_page_cache_cleanup
  ON first_page_cache (expires_at, viewer_did, publication_id);

DO $$
DECLARE table_name TEXT;
DECLARE constraint_name TEXT;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'operations_service_state', 'operations_metric_rollups', 'operations_trace_spans',
    'operations_events', 'operations_audit_events', 'operations_idempotency_records',
    'appview_ingestion_stream_state', 'appview_jetstream_endpoints',
    'operations_commands', 'appview_ingestion_gaps', 'appview_recovery_failures',
    'appview_backfill_jobs', 'operations_alerts', 'appview_tap_repo_state',
    'appview_tap_event_receipts', 'appview_tap_repository_registrations',
    'appview_tap_parity_discrepancies', 'appview_projection_repair_outbox',
    'operations_change_event_watermarks', 'operations_change_events',
    'appview_ingestion_checkpoints'
  ] LOOP
    constraint_name := table_name || '_environment_check';
    EXECUTE format('ALTER TABLE %I DROP CONSTRAINT IF EXISTS %I', table_name, constraint_name);
    EXECUTE format(
      'ALTER TABLE %I ADD CONSTRAINT %I
       CHECK (environment IN (''dev'', ''prod'', ''__legacy_unscoped__''))',
      table_name, constraint_name);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION operations_cleanup_expired(
  target_environment TEXT,
  cutoff TIMESTAMPTZ,
  requested_batch_size INTEGER DEFAULT 1000
) RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  bounded_batch INTEGER := GREATEST(1, LEAST(requested_batch_size, 10000));
  affected BIGINT := 0;
  row_count BIGINT;
  expired_change_cursor BIGINT;
BEGIN
  WITH doomed AS (
    SELECT ctid FROM operations_service_state
    WHERE environment = target_environment AND heartbeat_at <= cutoff - INTERVAL '1 day'
    LIMIT bounded_batch)
  DELETE FROM operations_service_state target USING doomed WHERE target.ctid = doomed.ctid;
  GET DIAGNOSTICS row_count = ROW_COUNT; affected := affected + row_count;

  WITH doomed AS (
    SELECT ctid FROM operations_metric_rollups
    WHERE environment = target_environment AND expires_at <= cutoff LIMIT bounded_batch)
  DELETE FROM operations_metric_rollups target USING doomed WHERE target.ctid = doomed.ctid;
  GET DIAGNOSTICS row_count = ROW_COUNT; affected := affected + row_count;

  WITH doomed AS (
    SELECT ctid FROM operations_trace_spans
    WHERE environment = target_environment AND expires_at <= cutoff LIMIT bounded_batch)
  DELETE FROM operations_trace_spans target USING doomed WHERE target.ctid = doomed.ctid;
  GET DIAGNOSTICS row_count = ROW_COUNT; affected := affected + row_count;

  WITH doomed AS (
    SELECT ctid FROM operations_events
    WHERE environment = target_environment AND expires_at <= cutoff LIMIT bounded_batch)
  DELETE FROM operations_events target USING doomed WHERE target.ctid = doomed.ctid;
  GET DIAGNOSTICS row_count = ROW_COUNT; affected := affected + row_count;

  WITH doomed AS (
    SELECT ctid, cursor FROM operations_change_events
    WHERE environment = target_environment AND expires_at <= cutoff
    ORDER BY cursor LIMIT bounded_batch
  ), deleted AS (
    DELETE FROM operations_change_events target USING doomed
    WHERE target.ctid = doomed.ctid RETURNING target.cursor
  )
  SELECT COUNT(*), MAX(cursor) INTO row_count, expired_change_cursor FROM deleted;
  affected := affected + row_count;
  IF expired_change_cursor IS NOT NULL THEN
    UPDATE operations_change_event_watermarks
      SET earliest_available_cursor = GREATEST(
        earliest_available_cursor, expired_change_cursor + 1),
        updated_at = cutoff
      WHERE environment = target_environment;
  END IF;

  WITH doomed AS (
    SELECT ctid FROM operations_audit_events
    WHERE environment = target_environment AND expires_at <= cutoff LIMIT bounded_batch)
  DELETE FROM operations_audit_events target USING doomed WHERE target.ctid = doomed.ctid;
  GET DIAGNOSTICS row_count = ROW_COUNT; affected := affected + row_count;

  WITH doomed AS (
    SELECT ctid FROM operations_idempotency_records
    WHERE environment = target_environment AND expires_at <= cutoff LIMIT bounded_batch)
  DELETE FROM operations_idempotency_records target USING doomed WHERE target.ctid = doomed.ctid;
  GET DIAGNOSTICS row_count = ROW_COUNT; affected := affected + row_count;

  WITH doomed AS (
    SELECT ctid FROM appview_recovery_failures
    WHERE environment = target_environment AND expires_at <= cutoff LIMIT bounded_batch)
  DELETE FROM appview_recovery_failures target USING doomed WHERE target.ctid = doomed.ctid;
  GET DIAGNOSTICS row_count = ROW_COUNT; affected := affected + row_count;

  WITH doomed AS (
    SELECT ctid FROM appview_tap_event_receipts
    WHERE environment = target_environment AND expires_at <= cutoff LIMIT bounded_batch)
  DELETE FROM appview_tap_event_receipts target USING doomed WHERE target.ctid = doomed.ctid;
  GET DIAGNOSTICS row_count = ROW_COUNT; affected := affected + row_count;

  WITH doomed AS (
    SELECT ctid FROM appview_tap_parity_discrepancies
    WHERE environment = target_environment AND status = 'resolved' AND expires_at <= cutoff
    LIMIT bounded_batch)
  DELETE FROM appview_tap_parity_discrepancies target USING doomed
    WHERE target.ctid = doomed.ctid;
  GET DIAGNOSTICS row_count = ROW_COUNT; affected := affected + row_count;

  WITH doomed AS (
    SELECT ctid FROM appview_projection_repair_outbox
    WHERE environment = target_environment AND status = 'failed' AND expires_at <= cutoff
    LIMIT bounded_batch)
  DELETE FROM appview_projection_repair_outbox target USING doomed WHERE target.ctid = doomed.ctid;
  GET DIAGNOSTICS row_count = ROW_COUNT; affected := affected + row_count;

  WITH doomed AS (
    SELECT ctid FROM operations_commands
    WHERE environment = target_environment
      AND status IN ('completed', 'failed') AND expires_at <= cutoff
    LIMIT bounded_batch)
  DELETE FROM operations_commands target USING doomed WHERE target.ctid = doomed.ctid;
  GET DIAGNOSTICS row_count = ROW_COUNT; affected := affected + row_count;
  WITH doomed AS (
    SELECT ctid FROM operations_alerts
    WHERE environment = target_environment AND status = 'resolved' AND expires_at <= cutoff
    LIMIT bounded_batch)
  DELETE FROM operations_alerts target USING doomed WHERE target.ctid = doomed.ctid;
  GET DIAGNOSTICS row_count = ROW_COUNT; affected := affected + row_count;
  WITH doomed AS (
    SELECT ctid FROM appview_backfill_jobs
    WHERE environment = target_environment
      AND status IN ('completed', 'failed', 'cancelled') AND expires_at <= cutoff
    LIMIT bounded_batch)
  DELETE FROM appview_backfill_jobs target USING doomed WHERE target.ctid = doomed.ctid;
  GET DIAGNOSTICS row_count = ROW_COUNT; affected := affected + row_count;
  WITH doomed AS (
    SELECT ctid FROM appview_ingestion_gaps
    WHERE environment = target_environment
      AND status IN ('resolved', 'ignored') AND expires_at <= cutoff
    LIMIT bounded_batch)
  DELETE FROM appview_ingestion_gaps target USING doomed WHERE target.ctid = doomed.ctid;
  GET DIAGNOSTICS row_count = ROW_COUNT; affected := affected + row_count;

  RETURN affected;
END;
$$;

DO $$
DECLARE table_name TEXT;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'operations_service_state', 'operations_metric_rollups', 'operations_trace_spans',
    'operations_events', 'operations_audit_events', 'operations_idempotency_records',
    'appview_ingestion_stream_state',
    'appview_jetstream_endpoints', 'operations_commands', 'appview_ingestion_gaps',
    'appview_recovery_failures', 'appview_backfill_jobs', 'operations_alerts',
    'appview_tap_repo_state', 'appview_tap_event_receipts',
    'appview_tap_repository_registrations',
    'appview_tap_parity_discrepancies',
    'appview_projection_repair_outbox', 'operations_change_event_watermarks',
    'operations_change_events', 'appview_ingestion_checkpoints'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', table_name);
    EXECUTE format('REVOKE ALL ON TABLE %I FROM anon, authenticated', table_name);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE %I TO service_role', table_name);
  END LOOP;
END $$;

REVOKE ALL ON FUNCTION operations_cleanup_expired(TEXT, TIMESTAMPTZ, INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION operations_cleanup_expired(TEXT, TIMESTAMPTZ, INTEGER) TO service_role;
REVOKE ALL ON FUNCTION operations_append_change_event(
  TEXT, TEXT, TEXT, TEXT, JSONB, TIMESTAMPTZ) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION operations_append_change_event(
  TEXT, TEXT, TEXT, TEXT, JSONB, TIMESTAMPTZ) TO service_role;

COMMENT ON COLUMN operations_metric_rollups.environment IS
  'Rows with __legacy_unscoped__ are quarantined and must never be served by an environment-scoped store.';

COMMIT;
