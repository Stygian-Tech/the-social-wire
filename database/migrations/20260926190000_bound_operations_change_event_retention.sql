-- Preserve the exact cursor-ordered retention batch and atomic SSE watermark.
-- Candidate work is proportional to expired history, not retained payloads;
-- the number of deleted rows remains bounded by the existing batch limit.
SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '10s';

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

  -- Isolate the expiry range before sorting by cursor. A cursor-ordered scan
  -- can otherwise visit every retained payload to prove that fewer than a full
  -- batch has expired. The existing expiry index covers this cursor-only input.
  -- Keep the original cursor ordering: changing to expiry order can advance
  -- the SSE watermark past a different set of retained history.
  WITH expired AS MATERIALIZED (
    SELECT cursor FROM operations_change_events
    WHERE environment = target_environment AND expires_at <= cutoff
  ), doomed AS (
    SELECT cursor FROM expired ORDER BY cursor LIMIT bounded_batch
  ), deleted AS (
    DELETE FROM operations_change_events target USING doomed
    WHERE target.environment = target_environment AND target.cursor = doomed.cursor
    RETURNING target.cursor
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

REVOKE ALL ON FUNCTION operations_cleanup_expired(TEXT, TIMESTAMPTZ, INTEGER) FROM PUBLIC;
