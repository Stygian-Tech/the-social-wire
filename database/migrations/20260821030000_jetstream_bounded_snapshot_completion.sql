-- Durable identity and terminal state for bounded Jetstream archive snapshots.

ALTER TABLE appview_jetstream_checkpoints
  ADD COLUMN IF NOT EXISTS replay_before_seq BIGINT;

ALTER TABLE appview_jetstream_checkpoints
  DROP CONSTRAINT IF EXISTS appview_jetstream_checkpoints_replay_state_check;

ALTER TABLE appview_jetstream_checkpoints
  ADD CONSTRAINT appview_jetstream_checkpoints_replay_state_check
  CHECK (replay_state IN (
    'idle', 'replaying', 'live', 'paused_budget', 'failed', 'snapshot_complete'
  ));

ALTER TABLE appview_jetstream_checkpoints
  ADD CONSTRAINT appview_jetstream_checkpoints_replay_before_seq_check
  CHECK (replay_before_seq IS NULL OR replay_before_seq >= 0);

ALTER TABLE appview_jetstream_checkpoints
  ADD CONSTRAINT appview_jetstream_checkpoints_replay_bounds_check
  CHECK (
    replay_before_seq IS NULL
    OR (
      replay_after_seq IS NOT NULL
      AND replay_after_seq < replay_before_seq
    )
  );

ALTER TABLE appview_jetstream_checkpoints
  ADD CONSTRAINT appview_jetstream_checkpoints_snapshot_complete_check
  CHECK (
    replay_state <> 'snapshot_complete'
    OR (
      replay_after_seq IS NOT NULL
      AND replay_before_seq IS NOT NULL
      AND replay_after_seq < replay_before_seq
      AND replay_sealed_seq = replay_before_seq
      AND (
        last_staged_seq IS NULL
        OR last_staged_seq <= replay_before_seq
      )
    )
  );

CREATE OR REPLACE FUNCTION appview_preserve_jetstream_snapshot_identity()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.replay_before_seq IS NOT NULL
     AND (
       NEW.replay_before_seq IS DISTINCT FROM OLD.replay_before_seq
       OR NEW.replay_after_seq IS DISTINCT FROM OLD.replay_after_seq
     ) THEN
    RAISE EXCEPTION
      'bounded Jetstream replay identity is immutable for source generation %',
      OLD.source_generation;
  END IF;

  IF OLD.replay_state = 'snapshot_complete'
     AND NEW.replay_state IS DISTINCT FROM OLD.replay_state THEN
    RAISE EXCEPTION
      'completed Jetstream snapshot is terminal for source generation %',
      OLD.source_generation;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS appview_preserve_jetstream_snapshot_identity_trigger
  ON appview_jetstream_checkpoints;

CREATE TRIGGER appview_preserve_jetstream_snapshot_identity_trigger
BEFORE UPDATE ON appview_jetstream_checkpoints
FOR EACH ROW
EXECUTE FUNCTION appview_preserve_jetstream_snapshot_identity();

COMMENT ON COLUMN appview_jetstream_checkpoints.replay_before_seq IS
  'Immutable inclusive upper sequence bound for a dedicated bounded snapshot source generation. Together with replay_after_seq it defines (after, before]. NULL for unbounded replay.';

COMMENT ON COLUMN appview_jetstream_checkpoints.last_staged_seq IS
  'Highest V2 sequence transactionally staged in the matching inbox. A completed bounded snapshot with no matching events legitimately leaves this NULL.';

COMMENT ON CONSTRAINT appview_jetstream_checkpoints_snapshot_complete_check
  ON appview_jetstream_checkpoints IS
  'A terminal bounded snapshot must retain exact lower and upper identity and provider proof that the upper bound was sealed.';
