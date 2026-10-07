package wireworkercore

const rollupUpdateSQL = `UPDATE wire_signal_rollups current
SET distinct_actors_1h = staged.distinct_actors_1h,
    distinct_actors_24h = staged.distinct_actors_24h,
    distinct_actors_7d = staged.distinct_actors_7d,
    signals_1h = staged.signals_1h,
    signals_24h = staged.signals_24h,
    signals_7d = staged.signals_7d,
    communities_24h = staged.communities_24h,
    primary_community_key_hash = staged.primary_community_key_hash,
    recommendations_24h = staged.recommendations_24h,
    positive_feedback_24h = staged.positive_feedback_24h,
    negative_feedback_24h = staged.negative_feedback_24h,
    shares_1h = staged.shares_1h,
    shares_24h = staged.shares_24h,
    distinct_likers_24h = staged.distinct_likers_24h,
    likes_1h = staged.likes_1h,
    likes_24h = staged.likes_24h,
    distinct_reposters_24h = staged.distinct_reposters_24h,
    reposts_1h = staged.reposts_1h,
    reposts_24h = staged.reposts_24h,
    baseline_last_signal_at = staged.baseline_last_signal_at,
    baseline_distinct_actors_1h = staged.baseline_distinct_actors_1h,
    baseline_distinct_actors_24h = staged.baseline_distinct_actors_24h,
    baseline_distinct_actors_7d = staged.baseline_distinct_actors_7d,
    baseline_signals_1h = staged.baseline_signals_1h,
    baseline_signals_24h = staged.baseline_signals_24h,
    baseline_signals_7d = staged.baseline_signals_7d,
    baseline_recommendations_24h = staged.baseline_recommendations_24h,
    baseline_shares_1h = staged.baseline_shares_1h,
    baseline_shares_24h = staged.baseline_shares_24h,
    baseline_distinct_likers_24h = staged.baseline_distinct_likers_24h,
    baseline_likes_1h = staged.baseline_likes_1h,
    baseline_likes_24h = staged.baseline_likes_24h,
    updated_at = staged.updated_at
FROM wire_signal_rollups_next staged
WHERE current.canonical_key = staged.canonical_key
  AND ROW(
  current.distinct_actors_1h,
  current.distinct_actors_24h,
  current.distinct_actors_7d,
  current.signals_1h,
  current.signals_24h,
  current.signals_7d,
  current.communities_24h,
  current.primary_community_key_hash,
  current.recommendations_24h,
  current.positive_feedback_24h,
  current.negative_feedback_24h,
  current.shares_1h,
  current.shares_24h,
  current.distinct_likers_24h,
  current.likes_1h,
  current.likes_24h,
  current.distinct_reposters_24h,
  current.reposts_1h,
  current.reposts_24h,
  current.baseline_last_signal_at,
  current.baseline_distinct_actors_1h,
  current.baseline_distinct_actors_24h,
  current.baseline_distinct_actors_7d,
  current.baseline_signals_1h,
  current.baseline_signals_24h,
  current.baseline_signals_7d,
  current.baseline_recommendations_24h,
  current.baseline_shares_1h,
  current.baseline_shares_24h,
  current.baseline_distinct_likers_24h,
  current.baseline_likes_1h,
  current.baseline_likes_24h
  ) IS DISTINCT FROM ROW(
  staged.distinct_actors_1h,
  staged.distinct_actors_24h,
  staged.distinct_actors_7d,
  staged.signals_1h,
  staged.signals_24h,
  staged.signals_7d,
  staged.communities_24h,
  staged.primary_community_key_hash,
  staged.recommendations_24h,
  staged.positive_feedback_24h,
  staged.negative_feedback_24h,
  staged.shares_1h,
  staged.shares_24h,
  staged.distinct_likers_24h,
  staged.likes_1h,
  staged.likes_24h,
  staged.distinct_reposters_24h,
  staged.reposts_1h,
  staged.reposts_24h,
  staged.baseline_last_signal_at,
  staged.baseline_distinct_actors_1h,
  staged.baseline_distinct_actors_24h,
  staged.baseline_distinct_actors_7d,
  staged.baseline_signals_1h,
  staged.baseline_signals_24h,
  staged.baseline_signals_7d,
  staged.baseline_recommendations_24h,
  staged.baseline_shares_1h,
  staged.baseline_shares_24h,
  staged.baseline_distinct_likers_24h,
  staged.baseline_likes_1h,
  staged.baseline_likes_24h
  )`

const rollupInsertSQL = `INSERT INTO wire_signal_rollups
  (canonical_key,
   distinct_actors_1h,
   distinct_actors_24h,
   distinct_actors_7d,
   signals_1h,
   signals_24h,
   signals_7d,
   communities_24h,
   primary_community_key_hash,
   recommendations_24h,
   positive_feedback_24h,
   negative_feedback_24h,
   shares_1h,
   shares_24h,
   distinct_likers_24h,
   likes_1h,
   likes_24h,
   distinct_reposters_24h,
   reposts_1h,
   reposts_24h,
   baseline_last_signal_at,
   baseline_distinct_actors_1h,
   baseline_distinct_actors_24h,
   baseline_distinct_actors_7d,
   baseline_signals_1h,
   baseline_signals_24h,
   baseline_signals_7d,
   baseline_recommendations_24h,
   baseline_shares_1h,
   baseline_shares_24h,
   baseline_distinct_likers_24h,
   baseline_likes_1h,
   baseline_likes_24h,
   updated_at)
SELECT staged.canonical_key,
  staged.distinct_actors_1h,
  staged.distinct_actors_24h,
  staged.distinct_actors_7d,
  staged.signals_1h,
  staged.signals_24h,
  staged.signals_7d,
  staged.communities_24h,
  staged.primary_community_key_hash,
  staged.recommendations_24h,
  staged.positive_feedback_24h,
  staged.negative_feedback_24h,
  staged.shares_1h,
  staged.shares_24h,
  staged.distinct_likers_24h,
  staged.likes_1h,
  staged.likes_24h,
  staged.distinct_reposters_24h,
  staged.reposts_1h,
  staged.reposts_24h,
  staged.baseline_last_signal_at,
  staged.baseline_distinct_actors_1h,
  staged.baseline_distinct_actors_24h,
  staged.baseline_distinct_actors_7d,
  staged.baseline_signals_1h,
  staged.baseline_signals_24h,
  staged.baseline_signals_7d,
  staged.baseline_recommendations_24h,
  staged.baseline_shares_1h,
  staged.baseline_shares_24h,
  staged.baseline_distinct_likers_24h,
  staged.baseline_likes_1h,
  staged.baseline_likes_24h,
  staged.updated_at
FROM wire_signal_rollups_next staged
WHERE NOT EXISTS (
  SELECT 1 FROM wire_signal_rollups current
  WHERE current.canonical_key = staged.canonical_key
)`

const rollupDeleteFullSQL = `DELETE FROM wire_signal_rollups current
WHERE NOT EXISTS (
  SELECT 1 FROM wire_signal_rollups_next staged
  WHERE staged.canonical_key = current.canonical_key
)`

const rollupDeleteIncrementalSQL = `DELETE FROM wire_signal_rollups current
WHERE NOT EXISTS (
  SELECT 1 FROM wire_signal_rollups_next staged
  WHERE staged.canonical_key = current.canonical_key
)
AND current.canonical_key IN (SELECT canonical_key FROM wire_signal_rollup_keys)`

const rollupStageFullSQL = `INSERT INTO wire_signal_rollups_next
  (canonical_key, distinct_actors_1h, distinct_actors_24h, distinct_actors_7d,
   signals_1h, signals_24h, signals_7d, communities_24h,
   primary_community_key_hash, recommendations_24h,
   positive_feedback_24h, negative_feedback_24h,
   shares_1h, shares_24h, distinct_likers_24h, likes_1h, likes_24h,
   distinct_reposters_24h, reposts_1h, reposts_24h,
   baseline_last_signal_at,
   baseline_distinct_actors_1h, baseline_distinct_actors_24h,
   baseline_distinct_actors_7d, baseline_signals_1h, baseline_signals_24h,
   baseline_signals_7d, baseline_recommendations_24h,
   baseline_shares_1h, baseline_shares_24h,
   baseline_distinct_likers_24h, baseline_likes_1h, baseline_likes_24h,
   updated_at, next_due_at)

SELECT canonical_key,
  COUNT(DISTINCT actor_key_hash) FILTER (WHERE occurred_at >= $2),
  COUNT(DISTINCT actor_key_hash) FILTER (WHERE occurred_at >= $3),
  COUNT(DISTINCT actor_key_hash),
  COUNT(*) FILTER (WHERE occurred_at >= $2),
  COUNT(*) FILTER (WHERE occurred_at >= $3),
  COUNT(*),
  COUNT(DISTINCT community_key_hash) FILTER (
    WHERE occurred_at >= $3 AND community_key_hash IS NOT NULL),
  MODE() WITHIN GROUP (ORDER BY community_key_hash) FILTER (
    WHERE occurred_at >= $3 AND community_key_hash IS NOT NULL),
  COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'recommendation'
    AND occurred_at >= $3),
  CASE WHEN FALSE THEN 0 ELSE COALESCE((SELECT COUNT(*) FROM wire_article_feedback feedback
    WHERE feedback.canonical_key = wire_signal_events.canonical_key
      AND feedback.feedback_value = 'good'
      AND feedback.occurred_at >= $3
      AND feedback.expires_at > $1), 0) END,
  CASE WHEN FALSE THEN 0 ELSE COALESCE((SELECT COUNT(*) FROM wire_article_feedback feedback
    WHERE feedback.canonical_key = wire_signal_events.canonical_key
      AND feedback.feedback_value = 'not_good'
      AND feedback.occurred_at >= $3
      AND feedback.expires_at > $1), 0) END,
  COUNT(DISTINCT actor_key_hash) FILTER (
    WHERE signal_kind IN ('share','quote','recommendation','publication')
    AND occurred_at >= $2),
  COUNT(DISTINCT actor_key_hash) FILTER (
    WHERE signal_kind IN ('share','quote','recommendation','publication')
    AND occurred_at >= $3),
  COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'like'
    AND occurred_at >= $3),
  COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'like'
    AND occurred_at >= $2),
  COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'like'
    AND occurred_at >= $3),
  COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'repost'
    AND occurred_at >= $3),
  COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'repost'
    AND occurred_at >= $2),
  COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'repost'
    AND occurred_at >= $3),
  MAX(occurred_at) FILTER (
    WHERE source_collection NOT LIKE 'at.margin.%'
      AND source_collection NOT LIKE 'network.cosmik.%'),
  COUNT(DISTINCT actor_key_hash) FILTER (
    WHERE occurred_at >= $2
      AND source_collection NOT LIKE 'at.margin.%'
      AND source_collection NOT LIKE 'network.cosmik.%'),
  COUNT(DISTINCT actor_key_hash) FILTER (
    WHERE occurred_at >= $3
      AND source_collection NOT LIKE 'at.margin.%'
      AND source_collection NOT LIKE 'network.cosmik.%'),
  COUNT(DISTINCT actor_key_hash) FILTER (
    WHERE source_collection NOT LIKE 'at.margin.%'
      AND source_collection NOT LIKE 'network.cosmik.%'),
  COUNT(*) FILTER (
    WHERE occurred_at >= $2
      AND source_collection NOT LIKE 'at.margin.%'
      AND source_collection NOT LIKE 'network.cosmik.%'),
  COUNT(*) FILTER (
    WHERE occurred_at >= $3
      AND source_collection NOT LIKE 'at.margin.%'
      AND source_collection NOT LIKE 'network.cosmik.%'),
  COUNT(*) FILTER (
    WHERE source_collection NOT LIKE 'at.margin.%'
      AND source_collection NOT LIKE 'network.cosmik.%'),
  COUNT(DISTINCT actor_key_hash) FILTER (
    WHERE signal_kind = 'recommendation'
      AND occurred_at >= $3
      AND source_collection NOT LIKE 'at.margin.%'
      AND source_collection NOT LIKE 'network.cosmik.%'),
  COUNT(DISTINCT actor_key_hash) FILTER (
    WHERE signal_kind IN ('share','quote','recommendation','publication')
      AND occurred_at >= $2
      AND source_collection NOT LIKE 'at.margin.%'
      AND source_collection NOT LIKE 'network.cosmik.%'),
  COUNT(DISTINCT actor_key_hash) FILTER (
    WHERE signal_kind IN ('share','quote','recommendation','publication')
      AND occurred_at >= $3
      AND source_collection NOT LIKE 'at.margin.%'
      AND source_collection NOT LIKE 'network.cosmik.%'),
  COUNT(DISTINCT actor_key_hash) FILTER (
    WHERE signal_kind = 'like'
      AND occurred_at >= $3
      AND source_collection NOT LIKE 'at.margin.%'
      AND source_collection NOT LIKE 'network.cosmik.%'),
  COUNT(DISTINCT actor_key_hash) FILTER (
    WHERE signal_kind = 'like'
      AND occurred_at >= $2
      AND source_collection NOT LIKE 'at.margin.%'
      AND source_collection NOT LIKE 'network.cosmik.%'),
  COUNT(DISTINCT actor_key_hash) FILTER (
    WHERE signal_kind = 'like'
      AND occurred_at >= $3
      AND source_collection NOT LIKE 'at.margin.%'
      AND source_collection NOT LIKE 'network.cosmik.%'),
  $1,
  -- Inclusive event windows change one PostgreSQL microsecond after
  -- their boundary; expiry is exclusive and changes at expires_at.
  CASE WHEN FALSE THEN LEAST(
    MIN(expires_at),
    MIN(occurred_at) FILTER (WHERE occurred_at >= $2)
      + interval '1 hour 1 microsecond',
    MIN(occurred_at) FILTER (WHERE occurred_at >= $3)
      + interval '24 hours 1 microsecond',
    MIN(occurred_at) + interval '168 hours 1 microsecond'
  ) ELSE NULL END
FROM wire_signal_events
WHERE occurred_at >= $4 AND expires_at > $1

GROUP BY canonical_key`

const rollupStageIncrementalSQL = `INSERT INTO wire_signal_rollups_next
    (canonical_key, distinct_actors_1h, distinct_actors_24h, distinct_actors_7d,
     signals_1h, signals_24h, signals_7d, communities_24h,
     primary_community_key_hash, recommendations_24h,
     positive_feedback_24h, negative_feedback_24h,
     shares_1h, shares_24h, distinct_likers_24h, likes_1h, likes_24h,
     distinct_reposters_24h, reposts_1h, reposts_24h,
     baseline_last_signal_at,
     baseline_distinct_actors_1h, baseline_distinct_actors_24h,
     baseline_distinct_actors_7d, baseline_signals_1h, baseline_signals_24h,
     baseline_signals_7d, baseline_recommendations_24h,
     baseline_shares_1h, baseline_shares_24h,
     baseline_distinct_likers_24h, baseline_likes_1h, baseline_likes_24h,
     updated_at, next_due_at)

WITH signal_counts (
  canonical_key,
  distinct_actors_1h,
  distinct_actors_24h,
  distinct_actors_7d,
  signals_1h,
  signals_24h,
  signals_7d,
  communities_24h,
  primary_community_key_hash,
  recommendations_24h,
  positive_feedback_24h,
  negative_feedback_24h,
  shares_1h,
  shares_24h,
  distinct_likers_24h,
  likes_1h,
  likes_24h,
  distinct_reposters_24h,
  reposts_1h,
  reposts_24h,
  baseline_last_signal_at,
  baseline_distinct_actors_1h,
  baseline_distinct_actors_24h,
  baseline_distinct_actors_7d,
  baseline_signals_1h,
  baseline_signals_24h,
  baseline_signals_7d,
  baseline_recommendations_24h,
  baseline_shares_1h,
  baseline_shares_24h,
  baseline_distinct_likers_24h,
  baseline_likes_1h,
  baseline_likes_24h,
  updated_at,
  next_due_at) AS (

  SELECT canonical_key,
    COUNT(DISTINCT actor_key_hash) FILTER (WHERE occurred_at >= $2),
    COUNT(DISTINCT actor_key_hash) FILTER (WHERE occurred_at >= $3),
    COUNT(DISTINCT actor_key_hash),
    COUNT(*) FILTER (WHERE occurred_at >= $2),
    COUNT(*) FILTER (WHERE occurred_at >= $3),
    COUNT(*),
    COUNT(DISTINCT community_key_hash) FILTER (
      WHERE occurred_at >= $3 AND community_key_hash IS NOT NULL),
    MODE() WITHIN GROUP (ORDER BY community_key_hash) FILTER (
      WHERE occurred_at >= $3 AND community_key_hash IS NOT NULL),
    COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'recommendation'
      AND occurred_at >= $3),
    CASE WHEN TRUE THEN 0 ELSE COALESCE((SELECT COUNT(*) FROM wire_article_feedback feedback
      WHERE feedback.canonical_key = wire_signal_events.canonical_key
        AND feedback.feedback_value = 'good'
        AND feedback.occurred_at >= $3
        AND feedback.expires_at > $1), 0) END,
    CASE WHEN TRUE THEN 0 ELSE COALESCE((SELECT COUNT(*) FROM wire_article_feedback feedback
      WHERE feedback.canonical_key = wire_signal_events.canonical_key
        AND feedback.feedback_value = 'not_good'
        AND feedback.occurred_at >= $3
        AND feedback.expires_at > $1), 0) END,
    COUNT(DISTINCT actor_key_hash) FILTER (
      WHERE signal_kind IN ('share','quote','recommendation','publication')
      AND occurred_at >= $2),
    COUNT(DISTINCT actor_key_hash) FILTER (
      WHERE signal_kind IN ('share','quote','recommendation','publication')
      AND occurred_at >= $3),
    COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'like'
      AND occurred_at >= $3),
    COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'like'
      AND occurred_at >= $2),
    COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'like'
      AND occurred_at >= $3),
    COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'repost'
      AND occurred_at >= $3),
    COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'repost'
      AND occurred_at >= $2),
    COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'repost'
      AND occurred_at >= $3),
    MAX(occurred_at) FILTER (
      WHERE source_collection NOT LIKE 'at.margin.%'
        AND source_collection NOT LIKE 'network.cosmik.%'),
    COUNT(DISTINCT actor_key_hash) FILTER (
      WHERE occurred_at >= $2
        AND source_collection NOT LIKE 'at.margin.%'
        AND source_collection NOT LIKE 'network.cosmik.%'),
    COUNT(DISTINCT actor_key_hash) FILTER (
      WHERE occurred_at >= $3
        AND source_collection NOT LIKE 'at.margin.%'
        AND source_collection NOT LIKE 'network.cosmik.%'),
    COUNT(DISTINCT actor_key_hash) FILTER (
      WHERE source_collection NOT LIKE 'at.margin.%'
        AND source_collection NOT LIKE 'network.cosmik.%'),
    COUNT(*) FILTER (
      WHERE occurred_at >= $2
        AND source_collection NOT LIKE 'at.margin.%'
        AND source_collection NOT LIKE 'network.cosmik.%'),
    COUNT(*) FILTER (
      WHERE occurred_at >= $3
        AND source_collection NOT LIKE 'at.margin.%'
        AND source_collection NOT LIKE 'network.cosmik.%'),
    COUNT(*) FILTER (
      WHERE source_collection NOT LIKE 'at.margin.%'
        AND source_collection NOT LIKE 'network.cosmik.%'),
    COUNT(DISTINCT actor_key_hash) FILTER (
      WHERE signal_kind = 'recommendation'
        AND occurred_at >= $3
        AND source_collection NOT LIKE 'at.margin.%'
        AND source_collection NOT LIKE 'network.cosmik.%'),
    COUNT(DISTINCT actor_key_hash) FILTER (
      WHERE signal_kind IN ('share','quote','recommendation','publication')
        AND occurred_at >= $2
        AND source_collection NOT LIKE 'at.margin.%'
        AND source_collection NOT LIKE 'network.cosmik.%'),
    COUNT(DISTINCT actor_key_hash) FILTER (
      WHERE signal_kind IN ('share','quote','recommendation','publication')
        AND occurred_at >= $3
        AND source_collection NOT LIKE 'at.margin.%'
        AND source_collection NOT LIKE 'network.cosmik.%'),
    COUNT(DISTINCT actor_key_hash) FILTER (
      WHERE signal_kind = 'like'
        AND occurred_at >= $3
        AND source_collection NOT LIKE 'at.margin.%'
        AND source_collection NOT LIKE 'network.cosmik.%'),
    COUNT(DISTINCT actor_key_hash) FILTER (
      WHERE signal_kind = 'like'
        AND occurred_at >= $2
        AND source_collection NOT LIKE 'at.margin.%'
        AND source_collection NOT LIKE 'network.cosmik.%'),
    COUNT(DISTINCT actor_key_hash) FILTER (
      WHERE signal_kind = 'like'
        AND occurred_at >= $3
        AND source_collection NOT LIKE 'at.margin.%'
        AND source_collection NOT LIKE 'network.cosmik.%'),
    $1,
    -- Inclusive event windows change one PostgreSQL microsecond after
    -- their boundary; expiry is exclusive and changes at expires_at.
    CASE WHEN TRUE THEN LEAST(
      MIN(expires_at),
      MIN(occurred_at) FILTER (WHERE occurred_at >= $2)
        + interval '1 hour 1 microsecond',
      MIN(occurred_at) FILTER (WHERE occurred_at >= $3)
        + interval '24 hours 1 microsecond',
      MIN(occurred_at) + interval '168 hours 1 microsecond'
    ) ELSE NULL END
  FROM wire_signal_events
  WHERE occurred_at >= $4 AND expires_at > $1
  AND canonical_key IN (SELECT canonical_key FROM wire_signal_rollup_batch)
  GROUP BY canonical_key

), feedback_counts AS (
  SELECT feedback.canonical_key,
    COUNT(*) FILTER (WHERE feedback.feedback_value = 'good') AS positive_feedback_24h,
    COUNT(*) FILTER (WHERE feedback.feedback_value = 'not_good') AS negative_feedback_24h,
    LEAST(MIN(feedback.expires_at),
      MIN(feedback.occurred_at) + interval '24 hours 1 microsecond') AS next_due_at
  FROM wire_article_feedback feedback
  JOIN signal_counts signals ON signals.canonical_key = feedback.canonical_key
  WHERE feedback.occurred_at >= signals.updated_at - interval '24 hours'
    AND feedback.expires_at > signals.updated_at
  GROUP BY feedback.canonical_key
)
SELECT
  signals.canonical_key,
  signals.distinct_actors_1h,
  signals.distinct_actors_24h,
  signals.distinct_actors_7d,
  signals.signals_1h,
  signals.signals_24h,
  signals.signals_7d,
  signals.communities_24h,
  signals.primary_community_key_hash,
  signals.recommendations_24h,
  COALESCE(feedback.positive_feedback_24h, 0),
  COALESCE(feedback.negative_feedback_24h, 0),
  signals.shares_1h,
  signals.shares_24h,
  signals.distinct_likers_24h,
  signals.likes_1h,
  signals.likes_24h,
  signals.distinct_reposters_24h,
  signals.reposts_1h,
  signals.reposts_24h,
  signals.baseline_last_signal_at,
  signals.baseline_distinct_actors_1h,
  signals.baseline_distinct_actors_24h,
  signals.baseline_distinct_actors_7d,
  signals.baseline_signals_1h,
  signals.baseline_signals_24h,
  signals.baseline_signals_7d,
  signals.baseline_recommendations_24h,
  signals.baseline_shares_1h,
  signals.baseline_shares_24h,
  signals.baseline_distinct_likers_24h,
  signals.baseline_likes_1h,
  signals.baseline_likes_24h,
  signals.updated_at,
  LEAST(signals.next_due_at, feedback.next_due_at)
FROM signal_counts signals LEFT JOIN feedback_counts feedback USING (canonical_key)`

const rollupLockRelationsSQL = `LOCK TABLE wire_signal_events, wire_article_feedback, wire_signal_rollups,
  wire_signal_rollup_dirty, wire_signal_rollup_schedule IN ACCESS SHARE MODE`

const rollupRefreshStateSQL = `CREATE TEMP TABLE wire_signal_rollup_refresh_state ON COMMIT DROP AS
WITH identity AS (
  SELECT wire_signal_rollup_relation_signature() AS signature
)
SELECT identity.signature,
  (control.last_as_of IS NULL OR control.last_as_of > $1
   OR control.postmaster_started_at IS DISTINCT FROM pg_postmaster_start_time()
   OR control.relation_signature IS DISTINCT FROM identity.signature) AS rebuild
FROM wire_signal_rollup_control control CROSS JOIN identity WHERE control.singleton`

const rollupClaimedSQL = `CREATE TEMP TABLE wire_signal_rollup_claimed ON COMMIT DROP AS
SELECT canonical_key, revision FROM wire_signal_rollup_dirty`

const rollupKeysTableSQL = `CREATE TEMP TABLE wire_signal_rollup_keys (canonical_key text PRIMARY KEY) ON COMMIT DROP`

const rollupSelectKeysSQL = `INSERT INTO wire_signal_rollup_keys
SELECT canonical_key FROM wire_signal_rollup_claimed
UNION SELECT canonical_key FROM wire_signal_rollup_schedule WHERE next_due_at <= $1
UNION SELECT canonical_key FROM wire_signal_events
  WHERE (SELECT rebuild FROM wire_signal_rollup_refresh_state)
    AND occurred_at >= $2 AND expires_at > $1
UNION SELECT canonical_key FROM wire_signal_rollups
  WHERE (SELECT rebuild FROM wire_signal_rollup_refresh_state)
UNION SELECT canonical_key FROM wire_signal_rollup_schedule
  WHERE (SELECT rebuild FROM wire_signal_rollup_refresh_state)`

const rollupNextBatchSQL = `INSERT INTO wire_signal_rollup_batch (canonical_key)
SELECT canonical_key FROM wire_signal_rollup_keys
WHERE ($1::text IS NULL OR canonical_key > $1)
ORDER BY canonical_key LIMIT 1000`

const rollupScheduleSQL = `INSERT INTO wire_signal_rollup_schedule (canonical_key, next_due_at)
SELECT canonical_key, next_due_at FROM wire_signal_rollups_next
WHERE next_due_at IS NOT NULL
ON CONFLICT (canonical_key) DO UPDATE SET next_due_at = EXCLUDED.next_due_at
  WHERE wire_signal_rollup_schedule.next_due_at IS DISTINCT FROM EXCLUDED.next_due_at`

const rollupDeleteScheduleSQL = `DELETE FROM wire_signal_rollup_schedule schedule
USING wire_signal_rollup_keys work
WHERE schedule.canonical_key = work.canonical_key AND NOT EXISTS (
  SELECT 1 FROM wire_signal_rollups_next staged
  WHERE staged.canonical_key = schedule.canonical_key
)`

const rollupAcknowledgeSQL = `WITH acknowledged AS MATERIALIZED (
  SELECT dirty.canonical_key, dirty.revision
  FROM wire_signal_rollup_dirty dirty
  JOIN wire_signal_rollup_claimed claimed USING (canonical_key, revision)
  ORDER BY dirty.canonical_key FOR UPDATE OF dirty SKIP LOCKED
)
DELETE FROM wire_signal_rollup_dirty dirty USING acknowledged
WHERE dirty.canonical_key = acknowledged.canonical_key
  AND dirty.revision = acknowledged.revision`

const rollupControlSQL = `UPDATE wire_signal_rollup_control SET last_as_of = $1,
  postmaster_started_at = pg_postmaster_start_time(),
  relation_signature = (SELECT signature FROM wire_signal_rollup_refresh_state)
WHERE singleton`
