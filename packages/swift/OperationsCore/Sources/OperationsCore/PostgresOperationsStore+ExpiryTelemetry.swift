import Foundation
import PostgresNIO

extension PostgresOperationsStore {
  /// Read at most limit + 1 indexed expiry candidates from one table, then count only
  /// cleanup-eligible rows. Truncation remains a lower bound even if protected recovery
  /// rows make that count zero. Global indexes are sampled before environment filtering.
  /// Each table has its own two-second timeout, so a failed table cannot hide other samples.
  func databaseExpiryBacklogRows(
    table: DatabaseExpiryTelemetryTable, at: Date, sampleLimit: Int = 1_000
  ) async throws -> [PostgresRow] {
    let limit = max(1, min(sampleLimit, 1_000))
    let query: PostgresQuery
    switch table {
    case .contentItems:
      query = """
      SELECT 'content_items'::text, COUNT(*)::bigint, COUNT(*) > \(limit)
      FROM (SELECT 1 FROM content_items
        WHERE expires_at <= \(at)
        ORDER BY expires_at LIMIT \(limit + 1)) sampled
      """
    case .wireItems:
      query = """
      SELECT 'wire_items'::text, COUNT(*)::bigint, COUNT(*) > \(limit)
      FROM (SELECT 1 FROM wire_items
        WHERE expires_at <= \(at)
        ORDER BY expires_at LIMIT \(limit + 1)) sampled
      """
    case .wireItemAliases:
      query = """
      SELECT 'wire_item_aliases'::text, COUNT(*)::bigint, COUNT(*) > \(limit)
      FROM (SELECT 1 FROM wire_item_aliases
        WHERE expires_at <= \(at)
        ORDER BY expires_at LIMIT \(limit + 1)) sampled
      """
    case .wireRankGenerations:
      query = """
      SELECT 'wire_rank_generations'::text,
        COUNT(*) FILTER (WHERE is_active = FALSE)::bigint, COUNT(*) > \(limit)
      FROM (SELECT is_active FROM wire_rank_generations
        WHERE expires_at <= \(at)
        ORDER BY expires_at LIMIT \(limit + 1)) sampled
      """
    case .circleGraphSnapshots:
      query = """
      SELECT 'appview_circle_graph_snapshots'::text, COUNT(*)::bigint, COUNT(*) > \(limit)
      FROM (SELECT 1 FROM appview_circle_graph_snapshots
        WHERE stale_until <= \(at)
        ORDER BY stale_until LIMIT \(limit + 1)) sampled
      """
    case .circleEditionCache:
      query = """
      SELECT 'appview_circle_edition_cache'::text, COUNT(*)::bigint, COUNT(*) > \(limit)
      FROM (SELECT 1 FROM appview_circle_edition_cache
        WHERE expires_at <= \(at)
        ORDER BY expires_at LIMIT \(limit + 1)) sampled
      """
    case .metricRollups:
      query = """
      SELECT 'operations_metric_rollups'::text,
        COUNT(*) FILTER (WHERE environment = \(environment))::bigint, COUNT(*) > \(limit)
      FROM (SELECT environment FROM operations_metric_rollups
        WHERE expires_at <= \(at)
        ORDER BY expires_at LIMIT \(limit + 1)) sampled
      """
    case .changeEvents:
      query = """
      SELECT 'operations_change_events'::text, COUNT(*)::bigint, COUNT(*) > \(limit)
      FROM (SELECT 1 FROM operations_change_events
        WHERE environment = \(environment) AND expires_at <= \(at)
        ORDER BY expires_at LIMIT \(limit + 1)) sampled
      """
    case .appviewInbox:
      query = """
      SELECT 'appview_ingestion_inbox'::text,
        COUNT(*) FILTER (WHERE status IN ('applied', 'filtered_scope')
          OR (status = 'dead_letter' AND reconciled_at IS NOT NULL))::bigint,
        COUNT(*) > \(limit)
      FROM (SELECT status, reconciled_at FROM appview_ingestion_inbox
        WHERE environment = \(environment) AND expires_at <= \(at)
        ORDER BY expires_at LIMIT \(limit + 1)) sampled
      """
    case .wireInbox:
      query = """
      SELECT 'wire_ingestion_inbox'::text,
        COUNT(*) FILTER (WHERE environment = \(environment)
          AND status IN ('applied', 'dead_letter'))::bigint,
        COUNT(*) > \(limit)
      FROM (SELECT environment, status FROM wire_ingestion_inbox
        WHERE expires_at <= \(at)
        ORDER BY expires_at LIMIT \(limit + 1)) sampled
      """
    }
    return try await databaseCostRows(query)
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
