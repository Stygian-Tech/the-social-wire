import Foundation
import Logging
import PostgresNIO

extension PostgresWireSignalRollupStore {
  // The incremental reader aggregates feedback once per key, within the same
  // statement snapshot as signals. The full reader retains its original query.
  static let incrementalSignalPrefix = """
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
    """

  static let incrementalFeedbackSuffix = """
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
    FROM signal_counts signals LEFT JOIN feedback_counts feedback USING (canonical_key)
    """

  /// Snapshot work without locking dirty rows across the expensive aggregate.
  /// A newer source revision can commit concurrently and survives acknowledgment.
  func prepareIncrementalRefresh(connection: PostgresConnection, asOf: Date) async throws -> Bool {
    let enabledRows = try await connection.query(
      "SELECT tracking_enabled FROM wire_signal_rollup_control WHERE singleton", logger: logger)
    var enabled = false
    for try await row in enabledRows { enabled = try row.decode(Bool.self) }
    guard enabled else { return false }
    // The extra schedule aggregates can cross PostgreSQL's JIT cost threshold
    // and spend longer compiling than executing. Bound this measured query
    // overhead without changing JIT for other work or pooled transactions.
    try await connection.query("SET LOCAL jit = off", logger: logger)

    // Protect the relation inventory against concurrent DROP/DETACH/TRUNCATE.
    // ACCESS SHARE permits normal ingestion and takes no source tuple locks.
    try await connection.query(
      """
      LOCK TABLE wire_signal_events, wire_article_feedback, wire_signal_rollups,
        wire_signal_rollup_dirty, wire_signal_rollup_schedule IN ACCESS SHARE MODE
      """, logger: logger)
    try await connection.query(
      """
      CREATE TEMP TABLE wire_signal_rollup_refresh_state ON COMMIT DROP AS
      WITH identity AS (
        SELECT wire_signal_rollup_relation_signature() AS signature
      )
      SELECT identity.signature,
        (control.last_as_of IS NULL OR control.last_as_of > \(asOf)
         OR control.postmaster_started_at IS DISTINCT FROM pg_postmaster_start_time()
         OR control.relation_signature IS DISTINCT FROM identity.signature) AS rebuild
      FROM wire_signal_rollup_control control CROSS JOIN identity WHERE control.singleton
      """, logger: logger)
    try await connection.query(
      """
      CREATE TEMP TABLE wire_signal_rollup_claimed ON COMMIT DROP AS
      SELECT canonical_key, revision FROM wire_signal_rollup_dirty
      """, logger: logger)
    try await connection.query(
      """
      CREATE TEMP TABLE wire_signal_rollup_keys (canonical_key text PRIMARY KEY) ON COMMIT DROP
      """, logger: logger)
    // The full fallback preserves future-dated signals, matching the existing
    // oracle's intentionally unbounded upper time range.
    try await connection.query(
      """
      INSERT INTO wire_signal_rollup_keys
      SELECT canonical_key FROM wire_signal_rollup_claimed
      UNION SELECT canonical_key FROM wire_signal_rollup_schedule WHERE next_due_at <= \(asOf)
      UNION SELECT canonical_key FROM wire_signal_events
        WHERE (SELECT rebuild FROM wire_signal_rollup_refresh_state)
          AND occurred_at >= \(asOf.addingTimeInterval(-7 * 86_400)) AND expires_at > \(asOf)
      UNION SELECT canonical_key FROM wire_signal_rollups
        WHERE (SELECT rebuild FROM wire_signal_rollup_refresh_state)
      UNION SELECT canonical_key FROM wire_signal_rollup_schedule
        WHERE (SELECT rebuild FROM wire_signal_rollup_refresh_state)
      """, logger: logger)
    try await connection.query("ANALYZE wire_signal_rollup_keys", logger: logger)
    let observations = try await connection.query(
      """
      SELECT rebuild, (SELECT count(*) FROM wire_signal_rollup_keys),
        (SELECT count(*) FROM wire_signal_rollup_claimed)
      FROM wire_signal_rollup_refresh_state
      """, logger: logger)
    for try await row in observations {
      let (rebuild, keys, dirty) = try row.decode((Bool, Int64, Int64).self)
      logger.info("Wire signal rollup work selected", metadata: [
        "full_rebuild": .stringConvertible(rebuild),
        "selected_keys": .stringConvertible(keys),
        "dirty_keys": .stringConvertible(dirty),
      ])
    }
    return true
  }

  func finishIncrementalRefresh(connection: PostgresConnection, asOf: Date) async throws {
    // Concurrent partition attachment/detachment can use weaker parent locks
    // than ordinary DDL. Reject a changed inventory instead of publishing a
    // sparse snapshot that did not revisit the affected partition's keys.
    let identityRows = try await connection.query(
      "SELECT signature = wire_signal_rollup_relation_signature() FROM wire_signal_rollup_refresh_state",
      logger: logger)
    for try await row in identityRows {
      guard try row.decode(Bool.self) else { throw WireSignalRollupRefreshError.sourceRelationsChanged }
    }
    try await connection.query(
      """
      INSERT INTO wire_signal_rollup_schedule (canonical_key, next_due_at)
      SELECT canonical_key, next_due_at FROM wire_signal_rollups_next
      WHERE next_due_at IS NOT NULL
      ON CONFLICT (canonical_key) DO UPDATE SET next_due_at = EXCLUDED.next_due_at
        WHERE wire_signal_rollup_schedule.next_due_at IS DISTINCT FROM EXCLUDED.next_due_at
      """, logger: logger)
    try await connection.query(
      """
      DELETE FROM wire_signal_rollup_schedule schedule
      USING wire_signal_rollup_keys work
      WHERE schedule.canonical_key = work.canonical_key AND NOT EXISTS (
        SELECT 1 FROM wire_signal_rollups_next staged
        WHERE staged.canonical_key = schedule.canonical_key
      )
      """, logger: logger)
    try await connection.query(
      """
      WITH acknowledged AS MATERIALIZED (
        SELECT dirty.canonical_key, dirty.revision
        FROM wire_signal_rollup_dirty dirty
        JOIN wire_signal_rollup_claimed claimed USING (canonical_key, revision)
        ORDER BY dirty.canonical_key FOR UPDATE OF dirty SKIP LOCKED
      )
      DELETE FROM wire_signal_rollup_dirty dirty USING acknowledged
      WHERE dirty.canonical_key = acknowledged.canonical_key
        AND dirty.revision = acknowledged.revision
      """, logger: logger)
    try await connection.query(
      """
      UPDATE wire_signal_rollup_control SET last_as_of = \(asOf),
        postmaster_started_at = pg_postmaster_start_time(),
        relation_signature = (SELECT signature FROM wire_signal_rollup_refresh_state)
      WHERE singleton
      """, logger: logger)
  }
}
