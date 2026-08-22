\set ON_ERROR_STOP on

DO $$
DECLARE
  pending_retry_valid BOOLEAN;
  pending_retry_definition TEXT;
  leased_valid BOOLEAN;
  leased_definition TEXT;
BEGIN
  SELECT index_state.indisvalid, pg_get_indexdef(index_state.indexrelid)
  INTO pending_retry_valid, pending_retry_definition
  FROM pg_index index_state
  WHERE index_state.indexrelid =
    to_regclass('public.wire_ingestion_inbox_pending_retry_ready_idx');

  IF pending_retry_valid IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'pending/retry Wire inbox claim index is missing or invalid';
  END IF;
  IF pending_retry_definition NOT LIKE '%(next_attempt_at, seq)%'
      OR pending_retry_definition NOT LIKE '%pending%'
      OR pending_retry_definition NOT LIKE '%retry%' THEN
    RAISE EXCEPTION 'unexpected pending/retry Wire inbox claim index: %',
      pending_retry_definition;
  END IF;

  SELECT index_state.indisvalid, pg_get_indexdef(index_state.indexrelid)
  INTO leased_valid, leased_definition
  FROM pg_index index_state
  WHERE index_state.indexrelid =
    to_regclass('public.wire_ingestion_inbox_expired_lease_idx');

  IF leased_valid IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'expired-lease Wire inbox claim index is missing or invalid';
  END IF;
  IF leased_definition NOT LIKE '%(lease_expires_at, seq)%'
      OR leased_definition NOT LIKE '%leased%' THEN
    RAISE EXCEPTION 'unexpected expired-lease Wire inbox claim index: %', leased_definition;
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION pg_temp.assert_plan_uses_all(
  expected_indexes TEXT[],
  query TEXT
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  expected_index TEXT;
  plan_line TEXT;
  plan_text TEXT := '';
BEGIN
  FOR plan_line IN EXECUTE 'EXPLAIN (COSTS OFF) ' || query LOOP
    plan_text := plan_text || E'\n' || plan_line;
  END LOOP;

  FOREACH expected_index IN ARRAY expected_indexes LOOP
    IF STRPOS(plan_text, expected_index) = 0 THEN
      RAISE EXCEPTION 'expected plan to use %, got:%', expected_index, plan_text;
    END IF;
  END LOOP;
END
$$;

BEGIN;

INSERT INTO wire_ingestion_inbox (
  environment, source_generation, seq, source_host, cursor_kind, event_kind,
  repo_did, payload, event_time, status, applied_at
)
SELECT
  'wire-plan-dev', 'wire-plan-generation-a', seq,
  'https://jetstream.example.invalid', 'jetstream_v2_seq', 'commit',
  'did:example:terminal-' || seq, '{}'::jsonb, NOW(), 'applied', NOW()
FROM generate_series(1, 20000) AS seq;

-- A large active but ineligible set ensures the pending/retry branch seeks by
-- eligibility timestamp instead of walking every active row.
INSERT INTO wire_ingestion_inbox (
  environment, source_generation, seq, source_host, cursor_kind, event_kind,
  repo_did, payload, event_time, status, next_attempt_at
)
SELECT
  CASE WHEN seq % 2 = 0 THEN 'wire-plan-dev' ELSE 'wire-plan-prod' END,
  CASE WHEN seq % 3 = 0 THEN 'wire-plan-generation-a' ELSE 'wire-plan-generation-b' END,
  seq, 'https://jetstream.example.invalid', 'jetstream_v2_seq', 'commit',
  'did:example:future-' || seq, '{}'::jsonb, NOW(), 'pending',
  NOW() + INTERVAL '1 day'
FROM generate_series(30001, 50000) AS seq;

INSERT INTO wire_ingestion_inbox (
  environment, source_generation, seq, source_host, cursor_kind, event_kind,
  repo_did, payload, event_time, status, next_attempt_at
)
SELECT
  CASE WHEN seq % 2 = 0 THEN 'wire-plan-dev' ELSE 'wire-plan-prod' END,
  CASE WHEN seq % 3 = 0 THEN 'wire-plan-generation-a' ELSE 'wire-plan-generation-b' END,
  seq, 'https://jetstream.example.invalid', 'jetstream_v2_seq', 'identity',
  'did:example:ready-' || seq, '{}'::jsonb, NOW(),
  CASE WHEN seq % 2 = 0 THEN 'pending' ELSE 'retry' END,
  NOW() - INTERVAL '1 minute'
FROM generate_series(50001, 50024) AS seq;

INSERT INTO wire_ingestion_inbox (
  environment, source_generation, seq, source_host, cursor_kind, event_kind,
  repo_did, payload, event_time, status, lease_owner, lease_token,
  lease_expires_at
)
SELECT
  CASE WHEN seq % 2 = 0 THEN 'wire-plan-dev' ELSE 'wire-plan-prod' END,
  CASE WHEN seq % 3 = 0 THEN 'wire-plan-generation-a' ELSE 'wire-plan-generation-b' END,
  seq, 'https://jetstream.example.invalid', 'jetstream_v2_seq', 'identity',
  'did:example:expired-' || seq, '{}'::jsonb, NOW(), 'leased',
  'ci-worker', 'ci-lease-' || seq, NOW() - INTERVAL '30 seconds'
FROM generate_series(50025, 50032) AS seq;

-- A later row in the same repo proves the correlated FIFO barrier remains in
-- the representative plan even when that later row is otherwise eligible.
INSERT INTO wire_ingestion_inbox (
  environment, source_generation, seq, source_host, cursor_kind, event_kind,
  repo_did, payload, event_time, status, next_attempt_at
) VALUES (
  'wire-plan-dev', 'wire-plan-generation-a', 50033,
  'https://jetstream.example.invalid', 'jetstream_v2_seq', 'identity',
  'did:example:ready-50001', '{}'::jsonb, NOW(), 'pending',
  NOW() - INTERVAL '2 minutes'
);

ANALYZE wire_ingestion_inbox;
SET LOCAL enable_seqscan = off;

SELECT pg_temp.assert_plan_uses_all(
  ARRAY[
    'wire_ingestion_inbox_pending_retry_ready_idx',
    'wire_ingestion_inbox_expired_lease_idx',
    'wire_ingestion_inbox_repo_fifo_idx'
  ],
  $query$
    WITH pending_retry_candidates AS (
      SELECT environment, source_generation, seq, next_attempt_at AS eligible_at
      FROM wire_ingestion_inbox candidate
      WHERE candidate.status IN ('pending', 'retry')
        AND candidate.next_attempt_at <= NOW()
        AND NOT EXISTS (
          SELECT 1 FROM wire_ingestion_inbox earlier
          WHERE earlier.environment = candidate.environment
            AND earlier.source_generation = candidate.source_generation
            AND earlier.repo_did = candidate.repo_did
            AND earlier.seq < candidate.seq
            AND earlier.status IN ('pending', 'leased', 'retry')
        )
      ORDER BY candidate.next_attempt_at, candidate.seq,
               candidate.environment, candidate.source_generation
      FOR UPDATE SKIP LOCKED
      LIMIT 32
    ),
    expired_lease_candidates AS (
      SELECT environment, source_generation, seq, lease_expires_at AS eligible_at
      FROM wire_ingestion_inbox candidate
      WHERE candidate.status = 'leased'
        AND candidate.lease_expires_at <= NOW()
        AND NOT EXISTS (
          SELECT 1 FROM wire_ingestion_inbox earlier
          WHERE earlier.environment = candidate.environment
            AND earlier.source_generation = candidate.source_generation
            AND earlier.repo_did = candidate.repo_did
            AND earlier.seq < candidate.seq
            AND earlier.status IN ('pending', 'leased', 'retry')
        )
      ORDER BY candidate.lease_expires_at, candidate.seq,
               candidate.environment, candidate.source_generation
      FOR UPDATE SKIP LOCKED
      LIMIT 32
    )
    SELECT environment, source_generation, seq, eligible_at
    FROM pending_retry_candidates
    UNION ALL
    SELECT environment, source_generation, seq, eligible_at
    FROM expired_lease_candidates
    ORDER BY eligible_at, seq, environment, source_generation
    LIMIT 32
  $query$
);

ROLLBACK;
