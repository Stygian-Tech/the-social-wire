import Foundation
import Logging
import PostgresNIO

struct PostgresWireSignalRollupStore: Sendable {
  let pool: PostgresClient
  let logger: Logger
  var incrementalEnabled = false

  func refresh(asOf: Date) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        "SELECT pg_advisory_xact_lock(hashtext('wire_signal_rollups_refresh')::bigint)",
        logger: logger
      )
      let incremental = incrementalEnabled
        ? try await prepareIncrementalRefresh(connection: connection, asOf: asOf) : false
      // SQL fragments are fixed literals, never caller input.
      let keyFilter = incremental
        ? "AND canonical_key IN (SELECT canonical_key FROM wire_signal_rollup_keys)" : ""
      let deleteFilter = incremental
        ? "AND current.canonical_key IN (SELECT canonical_key FROM wire_signal_rollup_keys)" : ""
      // Build one exact rolling-window snapshot without holding an exclusive
      // lock on the serving table. Temporary staging produces no table WAL.
      try await connection.query(
        """
        CREATE TEMP TABLE wire_signal_rollups_next
          (LIKE wire_signal_rollups INCLUDING DEFAULTS, next_due_at timestamptz) ON COMMIT DROP
        """,
        logger: logger
      )
      try await connection.query(
        """
        INSERT INTO wire_signal_rollups_next
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
        \(unescaped: incremental ? Self.incrementalSignalPrefix : "")
        SELECT canonical_key,
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE occurred_at >= \(asOf.addingTimeInterval(-3_600))),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          COUNT(DISTINCT actor_key_hash),
          COUNT(*) FILTER (WHERE occurred_at >= \(asOf.addingTimeInterval(-3_600))),
          COUNT(*) FILTER (WHERE occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          COUNT(*),
          COUNT(DISTINCT community_key_hash) FILTER (
            WHERE occurred_at >= \(asOf.addingTimeInterval(-86_400)) AND community_key_hash IS NOT NULL),
          MODE() WITHIN GROUP (ORDER BY community_key_hash) FILTER (
            WHERE occurred_at >= \(asOf.addingTimeInterval(-86_400)) AND community_key_hash IS NOT NULL),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'recommendation'
            AND occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          CASE WHEN \(incremental) THEN 0 ELSE COALESCE((SELECT COUNT(*) FROM wire_article_feedback feedback
            WHERE feedback.canonical_key = wire_signal_events.canonical_key
              AND feedback.feedback_value = 'good'
              AND feedback.occurred_at >= \(asOf.addingTimeInterval(-86_400))
              AND feedback.expires_at > \(asOf)), 0) END,
          CASE WHEN \(incremental) THEN 0 ELSE COALESCE((SELECT COUNT(*) FROM wire_article_feedback feedback
            WHERE feedback.canonical_key = wire_signal_events.canonical_key
              AND feedback.feedback_value = 'not_good'
              AND feedback.occurred_at >= \(asOf.addingTimeInterval(-86_400))
              AND feedback.expires_at > \(asOf)), 0) END,
          COUNT(DISTINCT actor_key_hash) FILTER (
            WHERE signal_kind IN ('share','quote','recommendation','publication')
            AND occurred_at >= \(asOf.addingTimeInterval(-3_600))),
          COUNT(DISTINCT actor_key_hash) FILTER (
            WHERE signal_kind IN ('share','quote','recommendation','publication')
            AND occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'like'
            AND occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'like'
            AND occurred_at >= \(asOf.addingTimeInterval(-3_600))),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'like'
            AND occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'repost'
            AND occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'repost'
            AND occurred_at >= \(asOf.addingTimeInterval(-3_600))),
          COUNT(DISTINCT actor_key_hash) FILTER (WHERE signal_kind = 'repost'
            AND occurred_at >= \(asOf.addingTimeInterval(-86_400))),
          MAX(occurred_at) FILTER (
            WHERE source_collection NOT LIKE 'at.margin.%'
              AND source_collection NOT LIKE 'network.cosmik.%'),
          COUNT(DISTINCT actor_key_hash) FILTER (
            WHERE occurred_at >= \(asOf.addingTimeInterval(-3_600))
              AND source_collection NOT LIKE 'at.margin.%'
              AND source_collection NOT LIKE 'network.cosmik.%'),
          COUNT(DISTINCT actor_key_hash) FILTER (
            WHERE occurred_at >= \(asOf.addingTimeInterval(-86_400))
              AND source_collection NOT LIKE 'at.margin.%'
              AND source_collection NOT LIKE 'network.cosmik.%'),
          COUNT(DISTINCT actor_key_hash) FILTER (
            WHERE source_collection NOT LIKE 'at.margin.%'
              AND source_collection NOT LIKE 'network.cosmik.%'),
          COUNT(*) FILTER (
            WHERE occurred_at >= \(asOf.addingTimeInterval(-3_600))
              AND source_collection NOT LIKE 'at.margin.%'
              AND source_collection NOT LIKE 'network.cosmik.%'),
          COUNT(*) FILTER (
            WHERE occurred_at >= \(asOf.addingTimeInterval(-86_400))
              AND source_collection NOT LIKE 'at.margin.%'
              AND source_collection NOT LIKE 'network.cosmik.%'),
          COUNT(*) FILTER (
            WHERE source_collection NOT LIKE 'at.margin.%'
              AND source_collection NOT LIKE 'network.cosmik.%'),
          COUNT(DISTINCT actor_key_hash) FILTER (
            WHERE signal_kind = 'recommendation'
              AND occurred_at >= \(asOf.addingTimeInterval(-86_400))
              AND source_collection NOT LIKE 'at.margin.%'
              AND source_collection NOT LIKE 'network.cosmik.%'),
          COUNT(DISTINCT actor_key_hash) FILTER (
            WHERE signal_kind IN ('share','quote','recommendation','publication')
              AND occurred_at >= \(asOf.addingTimeInterval(-3_600))
              AND source_collection NOT LIKE 'at.margin.%'
              AND source_collection NOT LIKE 'network.cosmik.%'),
          COUNT(DISTINCT actor_key_hash) FILTER (
            WHERE signal_kind IN ('share','quote','recommendation','publication')
              AND occurred_at >= \(asOf.addingTimeInterval(-86_400))
              AND source_collection NOT LIKE 'at.margin.%'
              AND source_collection NOT LIKE 'network.cosmik.%'),
          COUNT(DISTINCT actor_key_hash) FILTER (
            WHERE signal_kind = 'like'
              AND occurred_at >= \(asOf.addingTimeInterval(-86_400))
              AND source_collection NOT LIKE 'at.margin.%'
              AND source_collection NOT LIKE 'network.cosmik.%'),
          COUNT(DISTINCT actor_key_hash) FILTER (
            WHERE signal_kind = 'like'
              AND occurred_at >= \(asOf.addingTimeInterval(-3_600))
              AND source_collection NOT LIKE 'at.margin.%'
              AND source_collection NOT LIKE 'network.cosmik.%'),
          COUNT(DISTINCT actor_key_hash) FILTER (
            WHERE signal_kind = 'like'
              AND occurred_at >= \(asOf.addingTimeInterval(-86_400))
              AND source_collection NOT LIKE 'at.margin.%'
              AND source_collection NOT LIKE 'network.cosmik.%'),
          \(asOf),
          -- Inclusive event windows change one PostgreSQL microsecond after
          -- their boundary; expiry is exclusive and changes at expires_at.
          CASE WHEN \(incremental) THEN LEAST(
            MIN(expires_at),
            MIN(occurred_at) FILTER (WHERE occurred_at >= \(asOf.addingTimeInterval(-3_600)))
              + interval '1 hour 1 microsecond',
            MIN(occurred_at) FILTER (WHERE occurred_at >= \(asOf.addingTimeInterval(-86_400)))
              + interval '24 hours 1 microsecond',
            MIN(occurred_at) + interval '168 hours 1 microsecond'
          ) ELSE NULL END
        FROM wire_signal_events
        WHERE occurred_at >= \(asOf.addingTimeInterval(-7 * 86_400)) AND expires_at > \(asOf)
        \(unescaped: keyFilter)
        GROUP BY canonical_key
        \(unescaped: incremental ? Self.incrementalFeedbackSuffix : "")
        """,
        logger: logger
      )
      try await connection.query(
        "ALTER TABLE wire_signal_rollups_next ADD PRIMARY KEY (canonical_key)",
        logger: logger
      )
      try await connection.query(
        "ANALYZE wire_signal_rollups_next (canonical_key)",
        logger: logger
      )
      // Unchanged rows keep their tuple and timestamp. Re-inserting every row
      // also locks every referenced wire_items row through the foreign key,
      // generating WAL on that logged parent even though rollups are unlogged.
      try await connection.query(
        """
        UPDATE wire_signal_rollups current
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
          )
        """,
        logger: logger
      )
      try await connection.query(
        """
        INSERT INTO wire_signal_rollups
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
        )
        """,
        logger: logger
      )
      try await connection.query(
        """
        DELETE FROM wire_signal_rollups current
        WHERE NOT EXISTS (
          SELECT 1 FROM wire_signal_rollups_next staged
          WHERE staged.canonical_key = current.canonical_key
        )
        \(unescaped: deleteFilter)
        """,
        logger: logger
      )
      if incremental {
        try await finishIncrementalRefresh(connection: connection, asOf: asOf)
      } else {
        // An oracle refresh may use another asOf, so the next opt-in refresh
        // must rebuild scheduling coverage rather than trust an older cursor.
        try await connection.query(
          "UPDATE wire_signal_rollup_control SET last_as_of = NULL WHERE singleton AND last_as_of IS NOT NULL",
          logger: logger)
      }
      // All changes commit together. A concurrent parent deletion or any other
      // failure rolls back the refresh, preserving the prior complete snapshot.
    }
  }
}
