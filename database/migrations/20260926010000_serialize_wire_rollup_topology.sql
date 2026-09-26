-- Match the repeatable-read refresh lock order before its first snapshot.
-- SHARE UPDATE EXCLUSIVE excludes partition topology changes while allowing
-- ordinary ROW EXCLUSIVE signal writes. NOWAIT makes a busy maintenance lane
-- an explicit retry instead of silently extending an operator's lock budget.
CREATE OR REPLACE FUNCTION wire_set_signal_rollup_tracking(enabled boolean) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  LOCK TABLE ONLY wire_signal_events IN SHARE UPDATE EXCLUSIVE MODE NOWAIT;
  PERFORM pg_advisory_xact_lock(hashtext('wire_signal_rollups_refresh')::bigint);
  IF enabled THEN
    ALTER TABLE wire_signal_events ENABLE TRIGGER wire_signal_rollup_signal_dirty;
    ALTER TABLE wire_article_feedback ENABLE TRIGGER wire_signal_rollup_feedback_dirty;
  ELSE
    ALTER TABLE wire_signal_events DISABLE TRIGGER wire_signal_rollup_signal_dirty;
    ALTER TABLE wire_article_feedback DISABLE TRIGGER wire_signal_rollup_feedback_dirty;
  END IF;
  UPDATE wire_signal_rollup_control SET tracking_enabled = enabled, last_as_of = NULL,
    postmaster_started_at = NULL, relation_signature = NULL WHERE singleton;
END $$;
