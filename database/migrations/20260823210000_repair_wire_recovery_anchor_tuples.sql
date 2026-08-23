-- Recovery anchors must preserve the provider-authored cursor/time tuple.
-- The initial UNLOGGED hot-path migration selected the lowest cursor and the
-- earliest event timestamp independently on conflict. Jetstream event times
-- are not guaranteed to be monotonic, so that could manufacture a tuple that
-- never appeared in the provider stream.
--
-- Production receives the corrected initial migration. This forward repair is
-- for environments that already applied the original form: retain only tuples
-- that can still be proven by actionable inbox rows or a durable checkpoint,
-- then materialize the lowest exact tuple for every recoverable generation.

SET LOCAL lock_timeout = '5s';

LOCK TABLE wire_ingestion_recovery_anchors IN ACCESS EXCLUSIVE MODE;
LOCK TABLE wire_ingestion_inbox IN SHARE MODE;

CREATE TEMP TABLE wire_anchor_evidence ON COMMIT DROP AS
SELECT environment, source_generation, seq, event_time
FROM wire_ingestion_inbox
WHERE status IN ('pending', 'leased', 'retry')
UNION ALL
SELECT
  environment,
  source_generation,
  last_staged_seq,
  last_staged_event_at
FROM appview_jetstream_checkpoints
WHERE source_generation LIKE 'wire-%'
  AND last_staged_seq IS NOT NULL
  AND last_staged_event_at IS NOT NULL;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM wire_anchor_evidence
    GROUP BY environment, source_generation, seq
    HAVING COUNT(DISTINCT event_time) > 1
  ) THEN
    RAISE EXCEPTION 'conflicting event times for one Wire provider cursor';
  END IF;
END $$;

WITH exact AS (
  SELECT environment, source_generation, seq, MIN(event_time) AS event_time
  FROM wire_anchor_evidence
  GROUP BY environment, source_generation, seq
)
UPDATE wire_ingestion_recovery_anchors anchor
SET checkpoint_event_time = exact.event_time
FROM exact
WHERE (anchor.environment, anchor.source_generation, anchor.checkpoint_seq) =
      (exact.environment, exact.source_generation, exact.seq);

DELETE FROM wire_ingestion_recovery_anchors anchor
WHERE NOT EXISTS (
  SELECT 1
  FROM wire_anchor_evidence evidence
  WHERE (evidence.environment, evidence.source_generation, evidence.seq,
         evidence.event_time) =
        (anchor.environment, anchor.source_generation, anchor.checkpoint_seq,
         anchor.checkpoint_event_time)
);

CREATE TEMP TABLE wire_anchor_floor ON COMMIT DROP AS
SELECT DISTINCT ON (environment, source_generation)
  environment,
  source_generation,
  seq,
  event_time
FROM wire_anchor_evidence
ORDER BY environment, source_generation, seq, event_time;

INSERT INTO wire_ingestion_recovery_anchors
  (environment, source_generation, anchor_bucket, checkpoint_seq,
   checkpoint_event_time, captured_at)
SELECT
  environment,
  source_generation,
  date_trunc('hour', NOW()),
  seq,
  event_time,
  NOW()
FROM wire_anchor_floor
ON CONFLICT (environment, source_generation, anchor_bucket) DO UPDATE
SET checkpoint_seq = EXCLUDED.checkpoint_seq,
    checkpoint_event_time = EXCLUDED.checkpoint_event_time,
    captured_at = EXCLUDED.captured_at;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM wire_ingestion_inbox_epochs epoch
    WHERE NOT EXISTS (
      SELECT 1
      FROM wire_ingestion_recovery_anchors anchor
      WHERE (anchor.environment, anchor.source_generation) =
            (epoch.environment, epoch.source_generation)
    )
  ) THEN
    RAISE EXCEPTION 'Wire epoch has no exact recovery anchor';
  END IF;
END $$;

COMMENT ON TABLE wire_ingestion_recovery_anchors IS
  'Logged hourly provider-authored cursor/time tuples used to rebuild the UNLOGGED Wire inbox after crash recovery.';
