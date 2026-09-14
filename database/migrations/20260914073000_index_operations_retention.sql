-- socialwire:transaction=off
-- A small expiration batch must not require scanning retained telemetry payloads.
-- Preserve completed builds when retrying an interrupted migration; rebuild only
-- invalid artifacts left by a failed concurrent index build.
SET lock_timeout = '5s';
SET statement_timeout = '30min';

SELECT EXISTS (
  SELECT 1 FROM pg_index
  WHERE indexrelid = to_regclass('public.idx_operations_events_expiry')
    AND NOT indisvalid
) AS index_is_invalid \gset
\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS public.idx_operations_events_expiry;
\endif
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_operations_events_expiry
  ON public.operations_events (environment, expires_at);

SELECT EXISTS (
  SELECT 1 FROM pg_index
  WHERE indexrelid = to_regclass('public.idx_operations_trace_spans_expiry')
    AND NOT indisvalid
) AS index_is_invalid \gset
\if :index_is_invalid
DROP INDEX CONCURRENTLY IF EXISTS public.idx_operations_trace_spans_expiry;
\endif
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_operations_trace_spans_expiry
  ON public.operations_trace_spans (environment, expires_at);

DO $$
BEGIN
  IF (SELECT count(*) FROM pg_index
      WHERE indexrelid IN (
        to_regclass('public.idx_operations_events_expiry'),
        to_regclass('public.idx_operations_trace_spans_expiry')
      ) AND indisvalid AND indisready) <> 2 THEN
    RAISE EXCEPTION 'valid Operations retention indexes are required';
  END IF;
END $$;

RESET statement_timeout;
RESET lock_timeout;
