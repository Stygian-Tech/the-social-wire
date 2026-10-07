package thinappviewcore

// PostgreSQL statements mirror the authoritative Swift durable inbox store.

// Parameters: environment, sourceGeneration, at, authorCollections, viewerCollections, limit, workerId, leaseToken, leaseUntil
const inboxClaimSQL = `WITH candidates AS (
  SELECT i.environment, i.source_generation, i.seq
  FROM appview_ingestion_inbox i
  WHERE i.environment = $1 AND i.source_generation = $2
    AND ((i.status IN ('pending', 'retry') AND i.next_attempt_at <= $3)
      OR (i.status = 'leased' AND i.lease_expires_at <= $3))
    AND (
      (i.event_kind != 'commit' AND (
        EXISTS (
          SELECT 1 FROM appview_publication_scopes scope
          WHERE scope.author_did = i.repo_did OR scope.viewer_did = i.repo_did)
        OR EXISTS (
          SELECT 1 FROM appview_viewer_feeds feed
          WHERE feed.viewer_did = i.repo_did)))
      OR (i.collection = ANY($4) AND EXISTS (
        SELECT 1 FROM appview_publication_scopes scope
        WHERE scope.author_did = i.repo_did))
      OR (i.collection = ANY($5) AND (
        EXISTS (
          SELECT 1 FROM appview_viewer_feeds feed
          WHERE feed.viewer_did = i.repo_did)
        OR EXISTS (
          SELECT 1 FROM appview_publication_scopes scope
          WHERE scope.viewer_did = i.repo_did)
        OR (i.collection = 'app.thesocialwire.finance.selection' AND EXISTS (
          SELECT 1 FROM finance_selection_sync finance WHERE finance.viewer_did=i.repo_did))
            OR (i.collection='app.thesocialwire.sports.selection' AND EXISTS (SELECT 1 FROM sports_selection_sync sports WHERE sports.viewer_did=i.repo_did))))
    )
    AND NOT EXISTS (
      SELECT 1
      FROM appview_ingestion_inbox earlier
      WHERE earlier.environment = i.environment
        AND earlier.source_generation = i.source_generation
        AND earlier.repo_did = i.repo_did
        AND earlier.seq < i.seq
        AND earlier.status IN ('pending', 'retry', 'leased')
    )
    AND NOT EXISTS (
      SELECT 1
      FROM appview_ingestion_reconciliation_requests request
      WHERE request.environment = i.environment
        AND request.source_generation = i.source_generation
        AND request.repo_did = i.repo_did
        AND request.status IN ('pending', 'leased')
    )
  ORDER BY i.seq ASC
  FOR UPDATE SKIP LOCKED
  LIMIT $6
)
UPDATE appview_ingestion_inbox AS inbox
SET status = 'leased', lease_owner = $7, lease_token = $8,
    lease_expires_at = $9, updated_at = $3
FROM candidates
WHERE inbox.environment = candidates.environment
  AND inbox.source_generation = candidates.source_generation
  AND inbox.seq = candidates.seq
RETURNING inbox.seq, inbox.source_host, inbox.event_kind, inbox.repo_did,
          inbox.collection, inbox.operation, inbox.repo_rev, inbox.record_key,
          inbox.record_cid, inbox.payload::text, inbox.event_time, inbox.attempt_count`

// Parameters: environment, sourceGeneration, at, managedCollections, authorCollections, viewerCollections, limit, policy, expiresAt
const inboxFilterSQL = `WITH candidates AS (
  SELECT inbox.environment, inbox.source_generation, inbox.seq
  FROM appview_ingestion_inbox inbox
  WHERE inbox.environment = $1
    AND inbox.source_generation = $2
    AND ((inbox.status IN ('pending', 'retry') AND inbox.next_attempt_at <= $3)
      OR (inbox.status = 'leased' AND inbox.lease_expires_at <= $3))
    AND (
      (inbox.event_kind = 'commit' AND (
        inbox.collection IS NULL OR inbox.collection != ALL($4)
        OR (inbox.collection = ANY($5) AND NOT EXISTS (
          SELECT 1 FROM appview_publication_scopes scope
          WHERE scope.author_did = inbox.repo_did))
        OR (inbox.collection = ANY($6)
          AND NOT EXISTS (
            SELECT 1 FROM appview_viewer_feeds feed
            WHERE feed.viewer_did = inbox.repo_did)
          AND NOT EXISTS (
            SELECT 1 FROM appview_publication_scopes scope
            WHERE scope.viewer_did = inbox.repo_did)
          AND NOT (inbox.collection='app.thesocialwire.finance.selection' AND EXISTS (
            SELECT 1 FROM finance_selection_sync finance WHERE finance.viewer_did=inbox.repo_did))
            AND NOT (inbox.collection='app.thesocialwire.sports.selection' AND EXISTS (SELECT 1 FROM sports_selection_sync sports WHERE sports.viewer_did=inbox.repo_did)))))
      OR (inbox.event_kind != 'commit'
        AND NOT EXISTS (
          SELECT 1 FROM appview_publication_scopes scope
          WHERE scope.author_did = inbox.repo_did OR scope.viewer_did = inbox.repo_did)
        AND NOT EXISTS (
          SELECT 1 FROM appview_viewer_feeds feed
          WHERE feed.viewer_did = inbox.repo_did))
    )
  ORDER BY inbox.seq
  FOR UPDATE SKIP LOCKED
  LIMIT $7
)
UPDATE appview_ingestion_inbox inbox
SET status = 'filtered_scope', filtered_scope_policy = $8,
    filtered_scope_at = $3, applied_at = NULL, reconciled_at = NULL,
    lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL,
    failure_category = NULL, failure_reason = NULL,
    expires_at = $9, updated_at = $3
FROM candidates
WHERE inbox.environment = candidates.environment
  AND inbox.source_generation = candidates.source_generation
  AND inbox.seq = candidates.seq
RETURNING 1`

// Parameters: at, expiresAt, environment, sourceGeneration, sequence, workerId, leaseToken
const inboxAppliedSQL = `UPDATE appview_ingestion_inbox
SET status = 'applied', applied_at = $1, lease_owner = NULL, lease_token = NULL,
    lease_expires_at = NULL, failure_category = NULL, failure_reason = NULL,
    expires_at = $2, updated_at = $1
WHERE environment = $3 AND source_generation = $4
  AND seq = $5 AND status = 'leased'
  AND lease_owner = $6 AND lease_token = $7
RETURNING 1`

// Parameters: nextAttemptAt, failureCategory, failureReason, at, environment, sourceGeneration, sequence, workerId, leaseToken
const inboxRetrySQL = `UPDATE appview_ingestion_inbox
SET status = 'retry', attempt_count = attempt_count + 1,
    next_attempt_at = $1, lease_owner = NULL, lease_token = NULL,
    lease_expires_at = NULL, failure_category = $2,
    failure_reason = $3, updated_at = $4
WHERE environment = $5 AND source_generation = $6
  AND seq = $7 AND status = 'leased'
  AND lease_owner = $8 AND lease_token = $9
RETURNING 1`

// Parameters: leaseUntil, at, environment, sourceGeneration, sequence, workerId, leaseToken
const inboxRenewSQL = `UPDATE appview_ingestion_inbox
SET lease_expires_at = $1, updated_at = $2
WHERE environment = $3 AND source_generation = $4
  AND seq = $5 AND status = 'leased'
  AND lease_owner = $6 AND lease_token = $7
RETURNING 1`

// Parameters: environment, sourceGeneration, at
const inboxWatermarkSQL = `WITH barrier AS (
  SELECT MIN(seq) AS first_nonterminal_seq
  FROM appview_ingestion_inbox
  WHERE environment = $1 AND source_generation = $2
    AND status NOT IN ('applied', 'filtered_scope') AND reconciled_at IS NULL
), candidate AS (
  SELECT CASE
    WHEN barrier.first_nonterminal_seq IS NULL THEN checkpoint.last_staged_seq
    ELSE (
      SELECT MAX(inbox.seq)
      FROM appview_ingestion_inbox inbox
      WHERE inbox.environment = checkpoint.environment
        AND inbox.source_generation = checkpoint.source_generation
        AND inbox.seq < barrier.first_nonterminal_seq
        AND (inbox.status IN ('applied', 'filtered_scope')
          OR inbox.reconciled_at IS NOT NULL)
    )
  END AS seq
  FROM appview_jetstream_checkpoints checkpoint
  CROSS JOIN barrier
  WHERE checkpoint.environment = $1
    AND checkpoint.source_generation = $2
), candidate_with_time AS (
  SELECT candidate.seq,
    COALESCE(
      (SELECT event_time FROM appview_ingestion_inbox
       WHERE environment = $1 AND source_generation = $2
         AND seq = candidate.seq),
      checkpoint.last_staged_event_at
    ) AS event_at
  FROM candidate
  JOIN appview_jetstream_checkpoints checkpoint
    ON checkpoint.environment = $1
   AND checkpoint.source_generation = $2
)
UPDATE appview_jetstream_checkpoints checkpoint
SET last_applied_seq = candidate.seq,
    last_applied_event_at = candidate.event_at,
    last_applied_at = $3,
    updated_at = $3
FROM candidate_with_time candidate
WHERE checkpoint.environment = $1
  AND checkpoint.source_generation = $2
  AND candidate.seq IS NOT NULL
  AND (checkpoint.last_applied_seq IS NULL OR checkpoint.last_applied_seq < candidate.seq)`

// Parameters: at, failureCategory, failureReason, expiresAt, environment, sourceGeneration, sequence, workerId, leaseToken
const inboxDeadLetterSQL = `UPDATE appview_ingestion_inbox
SET status = 'dead_letter', attempt_count = attempt_count + 1,
    next_attempt_at = $1, lease_owner = NULL, lease_token = NULL,
    lease_expires_at = NULL, failure_category = $2,
    failure_reason = $3, dead_lettered_at = $1,
    expires_at = $4, updated_at = $1
WHERE environment = $5 AND source_generation = $6
  AND seq = $7 AND status = 'leased'
  AND lease_owner = $8 AND lease_token = $9
RETURNING 1`

// Parameters: environment, requestId, sourceGeneration, repoDid, failureCategory, sequence, at
const inboxScheduleReconciliationSQL = `INSERT INTO appview_ingestion_reconciliation_requests
  (environment, id, source_generation, repo_did, reason, trigger_seq, status,
   attempt_count, next_attempt_at, created_at, updated_at)
VALUES
  ($1, $2, $3, $4, $5,
   $6, 'pending', 0, $7, $7, $7)
ON CONFLICT (environment, source_generation, repo_did, trigger_seq, reason) DO NOTHING`

// Parameters: environment, sourceGeneration, at, limit, workerId, leaseToken, leaseUntil
const inboxReconciliationClaim0SQL = `WITH candidates AS (
  SELECT request.environment, request.id
  FROM appview_ingestion_reconciliation_requests request
  WHERE request.environment = $1
    AND request.source_generation = $2
    AND ((request.status = 'pending' AND request.next_attempt_at <= $3)
      OR (request.status = 'leased' AND request.lease_expires_at <= $3))
    AND NOT EXISTS (
      SELECT 1 FROM appview_ingestion_reconciliation_requests earlier
      WHERE earlier.environment = request.environment
        AND earlier.source_generation = request.source_generation
        AND earlier.repo_did = request.repo_did
        AND earlier.trigger_seq < request.trigger_seq
        AND earlier.status IN ('pending', 'leased'))
    AND NOT EXISTS (
      SELECT 1 FROM appview_ingestion_inbox inbox
      WHERE inbox.environment = request.environment
        AND inbox.source_generation = request.source_generation
        AND inbox.repo_did = request.repo_did
        AND inbox.status = 'leased'
        AND inbox.lease_expires_at > $3)
  ORDER BY request.trigger_seq, request.id
  FOR UPDATE SKIP LOCKED
  LIMIT $4
)
UPDATE appview_ingestion_reconciliation_requests request
SET status = 'leased', lease_owner = $5, lease_token = $6,
    lease_expires_at = $7, updated_at = $3
FROM candidates
WHERE request.environment = candidates.environment AND request.id = candidates.id
RETURNING request.id, request.repo_did, request.reason, request.trigger_seq,
          request.attempt_count`

// Parameters: leaseUntil, at, environment, requestId, workerId, leaseToken
const inboxReconciliationRenew0SQL = `UPDATE appview_ingestion_reconciliation_requests
SET lease_expires_at = $1, updated_at = $2
WHERE environment = $3 AND id = $4 AND status = 'leased'
  AND lease_owner = $5 AND lease_token = $6
RETURNING 1`

// Parameters: nextAttemptAt, failureReason, at, environment, requestId, workerId, leaseToken
const inboxReconciliationRetry0SQL = `UPDATE appview_ingestion_reconciliation_requests
SET status = CASE WHEN attempt_count + 1 >= 10 THEN 'failed' ELSE 'pending' END,
    attempt_count = attempt_count + 1, next_attempt_at = $1,
    lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL,
    reason = CASE WHEN attempt_count + 1 >= 10
      THEN reason || ':reconciliation_failed:' || $2
      ELSE reason END,
    updated_at = $3
WHERE environment = $4 AND id = $5 AND status = 'leased'
  AND lease_owner = $6 AND lease_token = $7
RETURNING 1`

// Parameters: at, environment, requestId, workerId, leaseToken
const inboxReconciliationComplete0SQL = `UPDATE appview_ingestion_reconciliation_requests
SET status = 'completed', completed_at = $1, updated_at = $1,
    lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL
WHERE environment = $2 AND id = $3 AND status = 'leased'
  AND lease_owner = $4 AND lease_token = $5
RETURNING 1`

// Parameters: at, expiresAt, environment, sourceGeneration, triggerSequence, repoDid
const inboxReconciliationComplete1SQL = `UPDATE appview_ingestion_inbox
SET reconciled_at = $1, expires_at = $2, updated_at = $1
WHERE environment = $3 AND source_generation = $4
  AND seq = $5 AND repo_did = $6 AND status = 'dead_letter'
RETURNING 1`

// Parameters: at, environment, sourceGeneration, triggerSequence
const inboxReconciliationComplete2SQL = `UPDATE appview_jetstream_checkpoints checkpoint
SET last_reconciled_repo_rev = COALESCE(inbox.repo_rev, checkpoint.last_reconciled_repo_rev),
    last_reconciled_at = $1, updated_at = $1
FROM appview_ingestion_inbox inbox
WHERE checkpoint.environment = $2
  AND checkpoint.source_generation = $3
  AND inbox.environment = checkpoint.environment
  AND inbox.source_generation = checkpoint.source_generation
  AND inbox.seq = $4`

// Parameters: at, expiresAt, environment, sourceGeneration, sequence, repoDid, workerId, leaseToken
const inboxReconciled0SQL = `UPDATE appview_ingestion_inbox
SET reconciled_at = $1, expires_at = $2,
    updated_at = $1
WHERE environment = $3 AND source_generation = $4
  AND seq = $5 AND repo_did = $6
  AND status = 'leased' AND lease_owner = $7 AND lease_token = $8
RETURNING 1`

// Parameters: repoRev, at, environment, sourceGeneration
const inboxReconciled1SQL = `UPDATE appview_jetstream_checkpoints
SET last_reconciled_repo_rev = $1, last_reconciled_at = $2, updated_at = $2
WHERE environment = $3 AND source_generation = $4`

// Parameters: at, environment, sourceGeneration, repoDid, sequence
const inboxReconciled2SQL = `UPDATE appview_ingestion_reconciliation_requests
SET status = 'completed', completed_at = $1, updated_at = $1,
    lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL
WHERE environment = $2 AND source_generation = $3
  AND repo_did = $4 AND trigger_seq = $5 AND status != 'completed'`

// Parameters: at, environment, sourceGeneration
const inboxResolveRecoveredSQL = `UPDATE appview_ingestion_incidents incident
SET status = 'resolved', replay_state = 'live',
    replay_sealed_seq = checkpoint.replay_sealed_seq,
    recovered_through_cursor = checkpoint.last_applied_seq,
    verification_evidence = incident.verification_evidence || jsonb_build_object(
      'recovery', 'terminal_prefix_reached',
      'sealedSequence', checkpoint.replay_sealed_seq::text,
      'terminalPrefixSequence', checkpoint.last_applied_seq::text,
      'allStagedRowsThroughSealedTerminal', true),
    resolved_at = $1, updated_at = $1, version = incident.version + 1
FROM appview_jetstream_checkpoints checkpoint
WHERE checkpoint.environment = $2
  AND checkpoint.source_generation = $3
  AND checkpoint.replay_state = 'live'
  AND checkpoint.replay_sealed_seq IS NOT NULL
  AND checkpoint.last_applied_seq >= checkpoint.replay_sealed_seq
  AND incident.environment = checkpoint.environment
  AND incident.source_generation = checkpoint.source_generation
  AND incident.source = 'jetstream-v2'
  AND incident.cursor_kind = 'jetstream_v2_seq'
  AND incident.category IN (
    'transport_error', 'consumer_too_slow', 'cursor_too_old', 'replay_budget',
    'no_progress_24h')
  AND incident.status IN ('open', 'recovering')
  AND NOT EXISTS (
    SELECT 1 FROM appview_ingestion_inbox inbox
    WHERE inbox.environment = checkpoint.environment
      AND inbox.source_generation = checkpoint.source_generation
      AND inbox.seq <= checkpoint.replay_sealed_seq
      AND inbox.status NOT IN ('applied', 'filtered_scope')
      AND inbox.reconciled_at IS NULL)
RETURNING 1`

// Parameters: activeLeaseName, at, environment, activeSourceGeneration
const inboxResolveRetiredSQL = `WITH successor AS (
  SELECT checkpoint.source_generation, checkpoint.source_host,
         checkpoint.stream_nsid, checkpoint.cursor_kind,
         checkpoint.replay_after_seq, checkpoint.last_staged_seq,
         checkpoint.updated_at AS checkpoint_observed_at,
         lease.updated_at AS lease_observed_at
  FROM appview_jetstream_checkpoints checkpoint
  JOIN LATERAL (
    SELECT candidate.updated_at
    FROM appview_ingestion_leases candidate
    WHERE candidate.environment = checkpoint.environment
      AND candidate.source_generation = checkpoint.source_generation
      AND candidate.lease_name = $1
      AND candidate.released_at IS NULL
      AND candidate.lease_expires_at >= $2
    ORDER BY candidate.updated_at DESC
    LIMIT 1
  ) lease ON TRUE
  WHERE checkpoint.environment = $3
    AND checkpoint.source_generation = $4
    AND checkpoint.replay_state = 'live'
), retired_candidates AS MATERIALIZED (
  -- Empty polls must not scan retained inbox history without an incident to resolve.
  SELECT checkpoint.environment, checkpoint.source_generation, checkpoint.last_staged_seq,
         checkpoint.last_applied_seq
  FROM appview_jetstream_checkpoints checkpoint
  CROSS JOIN successor
  WHERE checkpoint.environment = $3
    AND checkpoint.source_generation != successor.source_generation
    AND checkpoint.source_host = successor.source_host
    AND checkpoint.stream_nsid = successor.stream_nsid
    AND checkpoint.cursor_kind = successor.cursor_kind
    AND successor.replay_after_seq < checkpoint.last_staged_seq
    AND successor.last_staged_seq >= checkpoint.last_staged_seq
    AND checkpoint.replay_state = 'live'
    AND checkpoint.last_staged_seq IS NOT NULL
    AND checkpoint.last_applied_seq IS NOT NULL
    AND checkpoint.last_applied_seq >= checkpoint.last_staged_seq
    AND EXISTS (
      SELECT 1 FROM appview_ingestion_incidents incident
      WHERE incident.environment = checkpoint.environment
        AND incident.source_generation = checkpoint.source_generation
        AND incident.source = 'jetstream-v2'
        AND incident.cursor_kind = 'jetstream_v2_seq'
        AND incident.category = 'fatal_stream'
        AND incident.status IN ('open', 'recovering')
        AND (incident.start_cursor IS NULL
          OR incident.start_cursor <= checkpoint.last_applied_seq)
        AND (incident.end_cursor IS NULL
          OR incident.end_cursor <= checkpoint.last_applied_seq))
), retired AS (
  SELECT checkpoint.source_generation, checkpoint.last_staged_seq,
         checkpoint.last_applied_seq
  FROM retired_candidates checkpoint
  WHERE NOT EXISTS (
      SELECT 1 FROM appview_ingestion_leases retired_lease
      WHERE retired_lease.environment = checkpoint.environment
        AND retired_lease.source_generation = checkpoint.source_generation
        AND retired_lease.released_at IS NULL
        AND retired_lease.lease_expires_at >= $2)
    AND NOT EXISTS (
      SELECT 1 FROM appview_ingestion_inbox inbox
      WHERE inbox.environment = checkpoint.environment
        AND inbox.source_generation = checkpoint.source_generation
        AND (inbox.seq > checkpoint.last_staged_seq
          OR NOT (
            inbox.status IN ('applied', 'filtered_scope')
            OR (inbox.status = 'dead_letter' AND inbox.reconciled_at IS NOT NULL))))
    AND NOT EXISTS (
      SELECT 1 FROM appview_ingestion_reconciliation_requests request
      WHERE request.environment = checkpoint.environment
        AND request.source_generation = checkpoint.source_generation
        AND request.status IN ('pending', 'leased', 'failed'))
)
UPDATE appview_ingestion_incidents incident
SET status = 'resolved', replay_state = 'live',
    recovered_through_cursor = retired.last_applied_seq,
    verification_evidence = incident.verification_evidence || jsonb_build_object(
      'recovery', 'retired_generation_terminal',
      'resolutionPolicy', 'retired-generation-terminal-v1',
      'retiredSourceGeneration', retired.source_generation,
      'successorSourceGeneration', successor.source_generation,
      'successorLeaseName', $1,
      'successorReplayAfterSequence', successor.replay_after_seq::text,
      'successorLastStagedSequence', successor.last_staged_seq::text,
      'identityAndInclusiveOverlapVerified', true,
      'retiredLastStagedSequence', retired.last_staged_seq::text,
      'retiredTerminalPrefixSequence', retired.last_applied_seq::text,
      'allRetiredRowsTerminal', true,
      'successorCheckpointObservedAt', successor.checkpoint_observed_at,
      'successorLeaseObservedAt', successor.lease_observed_at),
    resolved_at = $2, updated_at = $2, version = incident.version + 1
FROM retired CROSS JOIN successor
WHERE incident.environment = $3
  AND incident.source_generation = retired.source_generation
  AND incident.source = 'jetstream-v2'
  AND incident.cursor_kind = 'jetstream_v2_seq'
  AND incident.category = 'fatal_stream'
  AND incident.status IN ('open', 'recovering')
  AND (incident.start_cursor IS NULL
    OR incident.start_cursor <= retired.last_applied_seq)
  AND (incident.end_cursor IS NULL
    OR incident.end_cursor <= retired.last_applied_seq)
RETURNING 1`
