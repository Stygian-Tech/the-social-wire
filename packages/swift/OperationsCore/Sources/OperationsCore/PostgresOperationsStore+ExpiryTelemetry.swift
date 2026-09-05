import Foundation
import PostgresNIO

extension PostgresOperationsStore {
  /// Read at most limit + 1 indexed expiry candidates per table, then count only rows
  /// eligible for cleanup. A truncated sample is a lower bound, even when its count is
  /// zero (the bounded inbox prefix may contain protected recovery rows). Wire inbox and
  /// metric-rollup expiry indexes are global: sample first, then scope their counts to
  /// the environment, so another environment cannot cause an unbounded filtered scan.
  /// The entire fixed ten-table sample shares one two-second statement timeout.
  func databaseExpiryBacklogRows(at: Date, sampleLimit: Int = 1_000) async throws -> [PostgresRow] {
    let limit = max(1, min(sampleLimit, 1_000))
    return try await databaseCostRows(
      """
      SELECT 'content_items'::text, COUNT(*)::bigint, COUNT(*) > \(limit)
      FROM (SELECT 1 FROM content_items
        WHERE expires_at <= \(at)
        ORDER BY expires_at LIMIT \(limit + 1)) sampled
      UNION ALL
      SELECT 'wire_items'::text, COUNT(*)::bigint, COUNT(*) > \(limit)
      FROM (SELECT 1 FROM wire_items
        WHERE expires_at <= \(at)
        ORDER BY expires_at LIMIT \(limit + 1)) sampled
      UNION ALL
      SELECT 'wire_item_aliases'::text, COUNT(*)::bigint, COUNT(*) > \(limit)
      FROM (SELECT 1 FROM wire_item_aliases
        WHERE expires_at <= \(at)
        ORDER BY expires_at LIMIT \(limit + 1)) sampled
      UNION ALL
      SELECT 'wire_rank_generations'::text,
        COUNT(*) FILTER (WHERE is_active = FALSE)::bigint, COUNT(*) > \(limit)
      FROM (SELECT is_active FROM wire_rank_generations
        WHERE expires_at <= \(at)
        ORDER BY expires_at LIMIT \(limit + 1)) sampled
      UNION ALL
      SELECT 'appview_circle_graph_snapshots'::text, COUNT(*)::bigint, COUNT(*) > \(limit)
      FROM (SELECT 1 FROM appview_circle_graph_snapshots
        WHERE stale_until <= \(at)
        ORDER BY stale_until LIMIT \(limit + 1)) sampled
      UNION ALL
      SELECT 'appview_circle_edition_cache'::text, COUNT(*)::bigint, COUNT(*) > \(limit)
      FROM (SELECT 1 FROM appview_circle_edition_cache
        WHERE expires_at <= \(at)
        ORDER BY expires_at LIMIT \(limit + 1)) sampled
      UNION ALL
      SELECT 'operations_metric_rollups'::text,
        COUNT(*) FILTER (WHERE environment = \(environment))::bigint, COUNT(*) > \(limit)
      FROM (SELECT environment FROM operations_metric_rollups
        WHERE expires_at <= \(at)
        ORDER BY expires_at LIMIT \(limit + 1)) sampled
      UNION ALL
      SELECT 'operations_change_events'::text, COUNT(*)::bigint, COUNT(*) > \(limit)
      FROM (SELECT 1 FROM operations_change_events
        WHERE environment = \(environment) AND expires_at <= \(at)
        ORDER BY expires_at LIMIT \(limit + 1)) sampled
      UNION ALL
      SELECT 'appview_ingestion_inbox'::text,
        COUNT(*) FILTER (WHERE status IN ('applied', 'filtered_scope')
          OR (status = 'dead_letter' AND reconciled_at IS NOT NULL))::bigint,
        COUNT(*) > \(limit)
      FROM (SELECT status, reconciled_at FROM appview_ingestion_inbox
        WHERE environment = \(environment) AND expires_at <= \(at)
        ORDER BY expires_at LIMIT \(limit + 1)) sampled
      UNION ALL
      SELECT 'wire_ingestion_inbox'::text,
        COUNT(*) FILTER (WHERE environment = \(environment)
          AND status IN ('applied', 'dead_letter'))::bigint,
        COUNT(*) > \(limit)
      FROM (SELECT environment, status FROM wire_ingestion_inbox
        WHERE expires_at <= \(at)
        ORDER BY expires_at LIMIT \(limit + 1)) sampled
      """)
  }

  /// The partial active-generation index bounds this sample without scanning history.
  /// Old generations without duration diagnostics remain unavailable, never zero-valued.
  func databaseGenerationDurationRows() async throws -> [PostgresRow] {
    try await databaseCostRows(
      """
      SELECT language_bucket, diagnostics->>'cycleDurationMilliseconds'
      FROM wire_rank_generations
      WHERE feed_key = 'wire' AND is_active = TRUE
      ORDER BY feed_key, language_bucket LIMIT 32
      """)
  }
}
