\set ON_ERROR_STOP on

-- V1 start_cursor/end_cursor values are microsecond timestamps. Bounded rows are grouped by
-- overlap; unbounded rows use deterministic source/reason/UTC-day clusters. Neither is ever
-- converted to or compared with V2 sequences.
CREATE TEMP TABLE legacy_gap_members AS
WITH ordered AS (
  SELECT
    environment, id AS gap_id, source, reason, status, start_cursor, end_cursor,
    detected_at, updated_at,
    MAX(end_cursor) OVER (
      PARTITION BY environment, source, reason
      ORDER BY start_cursor, end_cursor, detected_at, id
      ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
    ) AS prior_max_end
  FROM appview_ingestion_gaps
  WHERE environment = :'target_environment'
    AND status NOT IN ('resolved', 'ignored')
    AND start_cursor IS NOT NULL
    AND end_cursor IS NOT NULL
), marked AS (
  SELECT *, CASE WHEN prior_max_end IS NULL OR start_cursor > prior_max_end THEN 1 ELSE 0 END
    AS starts_cluster
  FROM ordered
), grouped AS (
  SELECT *, SUM(starts_cluster) OVER (
    PARTITION BY environment, source, reason
    ORDER BY start_cursor, end_cursor, detected_at, gap_id
  ) AS cluster_number
  FROM marked
)
SELECT grouped.*, 'range-' || cluster_number::text AS cluster_key
FROM grouped
UNION ALL
SELECT
  environment, id AS gap_id, source, reason, status, start_cursor, end_cursor,
  detected_at, updated_at, NULL::bigint AS prior_max_end, 1 AS starts_cluster,
  NULL::bigint AS cluster_number,
  'unbounded-' || TO_CHAR(DATE_TRUNC('day', detected_at AT TIME ZONE 'UTC'), 'YYYYMMDD')
    AS cluster_key
FROM appview_ingestion_gaps
WHERE environment = :'target_environment'
  AND status NOT IN ('resolved', 'ignored')
  AND (start_cursor IS NULL OR end_cursor IS NULL);

CREATE TEMP TABLE legacy_gap_clusters AS
SELECT
  environment, source, reason, cluster_key,
  MIN(start_cursor) AS start_cursor,
  MAX(end_cursor) AS end_cursor,
  COUNT(*)::bigint AS occurrence_count,
  MIN(detected_at) AS first_detected_at,
  MAX(detected_at) AS last_detected_at,
  'legacy-v1-' || SUBSTRING(MD5(
    environment || '|' || source || '|' || reason || '|' || cluster_key || '|'
      || COALESCE(MIN(start_cursor)::text, 'unbounded') || '|'
      || COALESCE(MAX(end_cursor)::text, 'unbounded')
  ), 1, 24) AS incident_id
FROM legacy_gap_members
GROUP BY environment, source, reason, cluster_key;

\echo 'Legacy gap distribution by status, reason, and UTC day'
SELECT status, reason, DATE_TRUNC('day', detected_at) AS detected_day_utc, COUNT(*) AS gap_signals
FROM appview_ingestion_gaps
WHERE environment = :'target_environment'
GROUP BY status, reason, DATE_TRUNC('day', detected_at)
ORDER BY detected_day_utc DESC, status, gap_signals DESC;

\echo 'Active legacy V1 overlap clusters (timestamp microseconds, never V2 sequences)'
SELECT source, reason, start_cursor, end_cursor, occurrence_count,
  first_detected_at, last_detected_at, incident_id
FROM legacy_gap_clusters
WHERE start_cursor IS NOT NULL AND end_cursor IS NOT NULL
ORDER BY occurrence_count DESC, first_detected_at, source, reason;

\echo 'Deterministic unbounded legacy clusters (grouped by source, reason, and UTC day)'
SELECT source, reason, occurrence_count, first_detected_at, last_detected_at, incident_id
FROM legacy_gap_clusters
WHERE start_cursor IS NULL OR end_cursor IS NULL
ORDER BY occurrence_count DESC, first_detected_at, source, reason;

\if :apply_mode
BEGIN;

INSERT INTO appview_ingestion_incidents (
  environment, id, source_generation, source_host, source, cursor_kind, start_cursor, end_cursor,
  category, status, occurrence_count, first_detected_at, last_detected_at,
  verification_evidence, updated_at, version
)
SELECT
  environment, incident_id, 'legacy-v1', NULL, source, 'jetstream_v1_time_us',
  start_cursor, end_cursor, reason, 'verification_required', occurrence_count,
  first_detected_at, last_detected_at,
  jsonb_build_object(
    'source', 'legacy_gap_consolidation',
    'cursorSemantics', 'timestamp_microseconds',
    'requiresRepositoryReconciliation', 'true'
  ), NOW(), 0
FROM legacy_gap_clusters
ON CONFLICT (environment, id) DO UPDATE SET
  occurrence_count = EXCLUDED.occurrence_count,
  first_detected_at = LEAST(appview_ingestion_incidents.first_detected_at, EXCLUDED.first_detected_at),
  last_detected_at = GREATEST(appview_ingestion_incidents.last_detected_at, EXCLUDED.last_detected_at),
  updated_at = NOW(), version = appview_ingestion_incidents.version + 1;

INSERT INTO appview_ingestion_incident_gaps (environment, incident_id, gap_id, linked_at)
SELECT member.environment, cluster.incident_id, member.gap_id, NOW()
FROM legacy_gap_members member
JOIN legacy_gap_clusters cluster
  ON cluster.environment = member.environment
  AND cluster.source = member.source
  AND cluster.reason = member.reason
  AND cluster.cluster_key = member.cluster_key
ON CONFLICT DO NOTHING;

INSERT INTO operations_audit_events (
  environment, id, operator_did, action, target_type, target_id, note,
  before_state, after_state, outcome, occurred_at, expires_at
)
SELECT
  environment,
  'legacy-gap-audit-' || SUBSTRING(MD5(environment || '|' || incident_id || '|' || NOW()::text), 1, 24),
  :'operator_did', 'legacy_gap.consolidated',
  'ingestion_incident', incident_id,
  'Linked immutable V1 gap signals; no gap rows deleted and no V2 sequence conversion performed.',
  '{}'::jsonb,
  jsonb_build_object('legacyGapSignals', occurrence_count, 'cursorKind', 'jetstream_v1_time_us'),
  'succeeded', NOW(), NOW() + INTERVAL '365 days'
FROM legacy_gap_clusters;

COMMIT;

\echo 'Applied consolidation. Legacy gap rows were retained and linked.'
\else
\echo 'Report only. Re-run with --apply plus explicit environment confirmation to link incidents.'
\endif
