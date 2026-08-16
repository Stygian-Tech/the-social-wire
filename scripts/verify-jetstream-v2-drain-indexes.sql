\set ON_ERROR_STOP on

DO $$
DECLARE
  missing_indexes TEXT;
BEGIN
  SELECT string_agg(expected.index_name, ', ' ORDER BY expected.index_name)
  INTO missing_indexes
  FROM (
    VALUES
      ('idx_appview_ingestion_inbox_ready'),
      ('idx_appview_ingestion_inbox_expired_lease'),
      ('idx_appview_ingestion_reconciliation_ready'),
      ('idx_appview_ingestion_reconciliation_expired_lease'),
      ('idx_appview_ingestion_reconciliation_active_repo'),
      ('idx_appview_ingestion_inbox_terminal_barrier'),
      ('idx_appview_ingestion_inbox_terminal_barrier_v2'),
      ('idx_first_page_cache_publication_viewer')
  ) AS expected(index_name)
  WHERE to_regclass('public.' || expected.index_name) IS NULL;

  IF missing_indexes IS NOT NULL THEN
    RAISE EXCEPTION 'missing Jetstream V2 drain indexes: %', missing_indexes;
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION pg_temp.assert_plan_uses(
  expected_index TEXT,
  query TEXT
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  plan_line TEXT;
  plan_text TEXT := '';
BEGIN
  FOR plan_line IN EXECUTE 'EXPLAIN (COSTS OFF) ' || query LOOP
    plan_text := plan_text || E'\n' || plan_line;
  END LOOP;

  IF STRPOS(plan_text, expected_index) = 0 THEN
    RAISE EXCEPTION 'expected plan to use %, got:%', expected_index, plan_text;
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
      RAISE EXCEPTION 'expected combined plan to use %, got:%', expected_index, plan_text;
    END IF;
  END LOOP;
END
$$;

BEGIN;

-- Model the sparse-ready phase where a sequence-ordered primary-key scan would
-- walk a large terminal prefix. This is the phase the partial indexes target.
INSERT INTO appview_ingestion_inbox (
  environment, source_generation, seq, source_host, cursor_kind, event_kind,
  repo_did, payload, event_time, status, applied_at
)
SELECT
  'ci-index-verification', 'ci-generation', seq,
  'https://jetstream.example.invalid', 'jetstream_v2_seq', 'commit',
  'did:example:terminal-' || seq, '{}'::jsonb, NOW(), 'applied', NOW()
FROM generate_series(1, 20000) AS seq;

INSERT INTO appview_ingestion_inbox (
  environment, source_generation, seq, source_host, cursor_kind, event_kind,
  repo_did, payload, event_time, status, next_attempt_at
)
SELECT
  'ci-index-verification', 'ci-generation', seq,
  'https://jetstream.example.invalid', 'jetstream_v2_seq', 'commit',
  'did:example:ready-' || seq, '{}'::jsonb, NOW(),
  CASE WHEN seq <= 20008 THEN 'pending' ELSE 'retry' END,
  NOW() - INTERVAL '1 minute'
FROM generate_series(20001, 20016) AS seq;

INSERT INTO appview_ingestion_inbox (
  environment, source_generation, seq, source_host, cursor_kind, event_kind,
  repo_did, payload, event_time, status, lease_owner, lease_token,
  lease_expires_at
)
SELECT
  'ci-index-verification', 'ci-generation', seq,
  'https://jetstream.example.invalid', 'jetstream_v2_seq', 'commit',
  'did:example:expired-' || seq, '{}'::jsonb, NOW(), 'leased',
  'ci-worker', 'ci-lease-' || seq, NOW() - INTERVAL '1 minute'
FROM generate_series(20017, 20024) AS seq;

INSERT INTO appview_ingestion_reconciliation_requests (
  environment, id, source_generation, repo_did, reason, trigger_seq,
  status, next_attempt_at, created_at, updated_at, completed_at
)
SELECT
  'ci-index-verification', 'ci-completed-' || seq, 'ci-generation',
  'did:example:completed-' || seq, 'ci-plan-verification', seq,
  'completed', NOW(), NOW(), NOW(), NOW()
FROM generate_series(1, 5000) AS seq;

-- Keep a large active-but-not-ready set so the combined claim plan must use
-- the time-selective ready/expired indexes rather than scanning all active repos.
INSERT INTO appview_ingestion_reconciliation_requests (
  environment, id, source_generation, repo_did, reason, trigger_seq,
  status, next_attempt_at, created_at, updated_at
)
SELECT
  'ci-index-verification', 'ci-future-pending-' || seq, 'ci-generation',
  'did:example:future-pending-' || seq, 'ci-plan-verification', seq,
  'pending', NOW() + INTERVAL '1 day', NOW(), NOW()
FROM generate_series(30001, 40000) AS seq;

INSERT INTO appview_ingestion_reconciliation_requests (
  environment, id, source_generation, repo_did, reason, trigger_seq,
  status, next_attempt_at, created_at, updated_at
)
SELECT
  'ci-index-verification', 'ci-other-generation-' || seq, 'ci-other-generation',
  'did:example:other-generation-' || seq, 'ci-plan-verification', seq,
  'pending', NOW() - INTERVAL '1 minute', NOW(), NOW()
FROM generate_series(50001, 60000) AS seq;

INSERT INTO appview_ingestion_reconciliation_requests (
  environment, id, source_generation, repo_did, reason, trigger_seq,
  status, next_attempt_at, lease_owner, lease_token, lease_expires_at,
  created_at, updated_at
)
SELECT
  'ci-index-verification', 'ci-future-leased-' || seq, 'ci-generation',
  'did:example:future-leased-' || seq, 'ci-plan-verification', seq,
  'leased', NOW(), 'ci-worker', 'ci-future-lease-' || seq,
  NOW() + INTERVAL '1 day', NOW(), NOW()
FROM generate_series(40001, 50000) AS seq;

INSERT INTO appview_ingestion_reconciliation_requests (
  environment, id, source_generation, repo_did, reason, trigger_seq,
  status, next_attempt_at, created_at, updated_at
) VALUES (
  'ci-index-verification', 'ci-reconciliation', 'ci-generation',
  'did:example:ci', 'ci-plan-verification', 20025,
  'pending', NOW(), NOW(), NOW()
);

INSERT INTO appview_ingestion_reconciliation_requests (
  environment, id, source_generation, repo_did, reason, trigger_seq,
  status, next_attempt_at, lease_owner, lease_token, lease_expires_at,
  created_at, updated_at
) VALUES (
  'ci-index-verification', 'ci-reconciliation-expired', 'ci-generation',
  'did:example:ci-expired', 'ci-plan-verification', 20026,
  'leased', NOW(), 'ci-worker', 'ci-reconciliation-lease',
  NOW() - INTERVAL '1 minute', NOW(), NOW()
);

ANALYZE appview_ingestion_inbox;
ANALYZE appview_ingestion_reconciliation_requests;

-- Exercise a representative copy of PostgresThinAppViewStore.claimIngestionInbox.
-- Source-contract tests guard its critical predicates; component checks below
-- make planner failures diagnostic.
SELECT pg_temp.assert_plan_uses_all(
  ARRAY[
    'idx_appview_ingestion_inbox_ready',
    'idx_appview_ingestion_inbox_expired_lease',
    'idx_appview_ingestion_inbox_repo_fifo'
  ],
  $query$
    SELECT i.environment, i.source_generation, i.seq
    FROM appview_ingestion_inbox i
    WHERE i.environment = 'ci-index-verification'
      AND i.source_generation = 'ci-generation'
      AND ((i.status IN ('pending', 'retry') AND i.next_attempt_at <= NOW())
        OR (i.status = 'leased' AND i.lease_expires_at <= NOW()))
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
    LIMIT 32
  $query$
);

-- Exercise the corresponding representative reconciliation claim shape.
-- Exact index eligibility is asserted independently below because PostgreSQL
-- may prefer an active-repo or sequential scan for a particular data mix.
EXPLAIN (COSTS OFF)
    SELECT request.environment, request.id
    FROM appview_ingestion_reconciliation_requests request
    WHERE request.environment = 'ci-index-verification'
      AND request.source_generation = 'ci-generation'
      AND ((request.status = 'pending' AND request.next_attempt_at <= NOW())
        OR (request.status = 'leased' AND request.lease_expires_at <= NOW()))
      AND NOT EXISTS (
        SELECT 1
        FROM appview_ingestion_reconciliation_requests earlier
        WHERE earlier.environment = request.environment
          AND earlier.source_generation = request.source_generation
          AND earlier.repo_did = request.repo_did
          AND earlier.trigger_seq < request.trigger_seq
          AND earlier.status IN ('pending', 'leased')
      )
      AND NOT EXISTS (
        SELECT 1
        FROM appview_ingestion_inbox inbox
        WHERE inbox.environment = request.environment
          AND inbox.source_generation = request.source_generation
          AND inbox.repo_did = request.repo_did
          AND inbox.status = 'leased'
          AND inbox.lease_expires_at > NOW()
      )
    ORDER BY request.trigger_seq, request.id
    FOR UPDATE SKIP LOCKED
    LIMIT 2;

-- The remaining assertions prove individual index eligibility even on tables
-- too small for PostgreSQL's cost model to prefer an index naturally.
SET enable_seqscan = off;

SELECT pg_temp.assert_plan_uses(
  'idx_appview_ingestion_inbox_ready',
  $query$
    SELECT seq, repo_did
    FROM appview_ingestion_inbox
    WHERE environment = 'ci-index-verification'
      AND source_generation = 'ci-generation'
      AND status IN ('pending', 'retry')
      AND next_attempt_at <= NOW()
    ORDER BY next_attempt_at, seq
    LIMIT 32
  $query$
);

SELECT pg_temp.assert_plan_uses(
  'idx_appview_ingestion_inbox_expired_lease',
  $query$
    SELECT seq, repo_did
    FROM appview_ingestion_inbox
    WHERE environment = 'ci-index-verification'
      AND source_generation = 'ci-generation'
      AND status = 'leased'
      AND lease_expires_at <= NOW()
    ORDER BY lease_expires_at, seq
    LIMIT 32
  $query$
);

SELECT pg_temp.assert_plan_uses(
  'idx_appview_ingestion_reconciliation_ready',
  $query$
    SELECT trigger_seq, id, repo_did
    FROM appview_ingestion_reconciliation_requests
    WHERE environment = 'ci-index-verification'
      AND source_generation = 'ci-generation'
      AND status = 'pending'
      AND next_attempt_at <= NOW()
    ORDER BY next_attempt_at, trigger_seq, id
    LIMIT 2
  $query$
);

SELECT pg_temp.assert_plan_uses(
  'idx_appview_ingestion_reconciliation_expired_lease',
  $query$
    SELECT trigger_seq, id, repo_did
    FROM appview_ingestion_reconciliation_requests
    WHERE environment = 'ci-index-verification'
      AND source_generation = 'ci-generation'
      AND status = 'leased'
      AND lease_expires_at <= NOW()
    ORDER BY lease_expires_at, trigger_seq, id
    LIMIT 2
  $query$
);

SELECT pg_temp.assert_plan_uses(
  'idx_appview_ingestion_reconciliation_active_repo',
  $query$
    SELECT trigger_seq
    FROM appview_ingestion_reconciliation_requests
    WHERE environment = 'ci-index-verification'
      AND source_generation = 'ci-generation'
      AND repo_did = 'did:example:ci'
      AND status IN ('pending', 'leased')
    ORDER BY trigger_seq
    LIMIT 1
  $query$
);

SELECT pg_temp.assert_plan_uses(
  'idx_appview_ingestion_inbox_terminal_barrier_v2',
  $query$
    SELECT MIN(seq)
    FROM appview_ingestion_inbox
    WHERE environment = 'ci-index-verification'
      AND source_generation = 'ci-generation'
      AND status NOT IN ('applied', 'filtered_scope')
      AND reconciled_at IS NULL
  $query$
);

SELECT pg_temp.assert_plan_uses(
  'idx_first_page_cache_publication_viewer',
  $query$
    DELETE FROM first_page_cache
    WHERE publication_id = 'at://did:example:ci/site.standard.publication/index'
  $query$
);

ROLLBACK;
