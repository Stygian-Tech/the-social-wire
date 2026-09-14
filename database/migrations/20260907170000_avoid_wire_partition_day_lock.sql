-- Existing signal partitions need no creation lock. Holding this day-wide lock
-- until the caller commits serializes unrelated repositories' signal writes.
CREATE OR REPLACE FUNCTION ensure_wire_signal_event_partition(event_day DATE)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  partition_name TEXT := 'wire_signal_events_' || to_char(event_day, 'YYYYMMDD');
  range_start TIMESTAMPTZ := event_day::TIMESTAMP AT TIME ZONE 'UTC';
  range_end TIMESTAMPTZ := (event_day + 1)::TIMESTAMP AT TIME ZONE 'UTC';
BEGIN
  IF to_regclass(partition_name) IS NOT NULL THEN
    RETURN;
  END IF;

  -- Concurrent creators must recheck after acquiring the same transaction lock.
  PERFORM pg_advisory_xact_lock(hashtext('wire_signal_events'), hashtext(event_day::TEXT));
  IF to_regclass(partition_name) IS NULL THEN
    EXECUTE format(
      'CREATE UNLOGGED TABLE %I PARTITION OF wire_signal_events FOR VALUES FROM (%L) TO (%L)',
      partition_name,
      range_start,
      range_end
    );
  END IF;
END;
$$;
