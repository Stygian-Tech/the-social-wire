\set ON_ERROR_STOP on
-- Database-wide, identifier-free snapshot. This does not acquire claim locks.
-- At most 65 rows per due branch and 128 indexed FIFO predecessor probes.
BEGIN READ ONLY;
SET LOCAL statement_timeout = '3s';
SET LOCAL lock_timeout = '500ms';
-- BEGIN DIAGNOSTIC QUERY
WITH pending_due AS MATERIALIZED (
  SELECT environment, source_generation, repo_did, seq, staged_at,
         next_attempt_at AS due_at
  FROM wire_ingestion_inbox
  WHERE status IN ('pending', 'retry') AND next_attempt_at <= statement_timestamp()
  ORDER BY next_attempt_at, seq LIMIT 65
), leased_due AS MATERIALIZED (
  SELECT environment, source_generation, repo_did, seq, staged_at,
         lease_expires_at AS due_at
  FROM wire_ingestion_inbox
  WHERE status = 'leased' AND lease_expires_at <= statement_timestamp()
  ORDER BY lease_expires_at, seq LIMIT 65
), sampled AS MATERIALIZED (
  (SELECT * FROM pending_due ORDER BY due_at, seq LIMIT 64)
  UNION ALL
  (SELECT * FROM leased_due ORDER BY due_at, seq LIMIT 64)
), classified AS MATERIALIZED (
  SELECT sampled.due_at, sampled.staged_at, predecessor.seq IS NULL AS fifo_eligible
  FROM sampled
  LEFT JOIN LATERAL (
    SELECT earlier.seq FROM wire_ingestion_inbox earlier
    WHERE earlier.environment = sampled.environment
      AND earlier.source_generation = sampled.source_generation
      AND earlier.repo_did = sampled.repo_did AND earlier.seq < sampled.seq
      AND earlier.status IN ('pending', 'leased', 'retry')
    ORDER BY earlier.seq LIMIT 1
  ) predecessor ON TRUE
)
SELECT json_build_object(
  'observedAt', statement_timestamp(),
  'scope', 'database',
  'sampleLimitPerDueBranch', 64,
  'pendingRetrySampleTruncated', (SELECT COUNT(*) > 64 FROM pending_due),
  'expiredLeaseSampleTruncated', (SELECT COUNT(*) > 64 FROM leased_due),
  'duePresent', COUNT(*) > 0,
  'sampledDueRows', COUNT(*),
  'sampledFIFOEligibleHeads', COUNT(*) FILTER (WHERE fifo_eligible),
  'sampledFIFOBlockedRows', COUNT(*) FILTER (WHERE NOT fifo_eligible),
  'sampledOldestDueAgeLowerBoundSeconds',
    EXTRACT(EPOCH FROM statement_timestamp() - MIN(due_at)),
  'sampledOldestStagedAgeLowerBoundSeconds',
    EXTRACT(EPOCH FROM statement_timestamp() - MIN(staged_at)),
  'sampledOldestFIFOEligibleStagedAgeLowerBoundSeconds',
    EXTRACT(EPOCH FROM statement_timestamp() - MIN(staged_at) FILTER (WHERE fifo_eligible))
) AS wire_inbox_readiness
FROM classified;
-- END DIAGNOSTIC QUERY
ROLLBACK;
