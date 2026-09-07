import Foundation
import PostgresNIO

extension PostgresOperationsStore {
  /// The latest observed sample per UTC day. Missing days stay absent; projections cannot
  /// reconstruct past population totals or activity windows reliably.
  public func fetchViewerHistory(at: Date) async throws -> [OperationsViewerCounts] {
    let rows = try await viewerHistoryRows(
      """
      SELECT known_viewers, active_viewers_7d, active_viewers_30d, observed_at
      FROM operations_viewer_daily_counts
      WHERE environment = \(environment)
        AND snapshot_day >= (\(at)::timestamptz AT TIME ZONE 'UTC')::date - 89
        AND snapshot_day <= (\(at)::timestamptz AT TIME ZONE 'UTC')::date
        AND observed_at <= \(at)
      ORDER BY snapshot_day ASC
      LIMIT 90
      """)
    return try rows.map { row in
      let value = try row.decode((Int64, Int64, Int64, Date).self)
      return OperationsViewerCounts(
        knownViewers: Int(value.0), activeViewers7d: Int(value.1),
        activeViewers30d: Int(value.2), observedAt: value.3)
    }
  }

  public func recordViewerHistory(at: Date) async throws {
    // Prune independently of projection availability, so a failed observation never
    // extends retention or turns an unavailable measurement into a zero sample.
    _ = try await viewerHistoryRows(
      """
      DELETE FROM operations_viewer_daily_counts
      WHERE environment = \(environment)
        AND snapshot_day < (\(at)::timestamptz AT TIME ZONE 'UTC')::date - 89
      """)
    guard let counts = try await fetchViewerCounts(at: at) else { return }
    try await saveViewerHistory(counts)
  }

  func saveViewerHistory(_ counts: OperationsViewerCounts) async throws {
    _ = try await viewerHistoryRows(
      """
      INSERT INTO operations_viewer_daily_counts
        (environment, snapshot_day, known_viewers, active_viewers_7d,
         active_viewers_30d, observed_at)
      VALUES (\(environment), (\(counts.observedAt)::timestamptz AT TIME ZONE 'UTC')::date,
        \(Int64(counts.knownViewers)), \(Int64(counts.activeViewers7d)),
        \(Int64(counts.activeViewers30d)), \(counts.observedAt))
      ON CONFLICT (environment, snapshot_day) DO UPDATE SET
        known_viewers = EXCLUDED.known_viewers,
        active_viewers_7d = EXCLUDED.active_viewers_7d,
        active_viewers_30d = EXCLUDED.active_viewers_30d,
        observed_at = EXCLUDED.observed_at
      WHERE operations_viewer_daily_counts.observed_at < EXCLUDED.observed_at
      """)
  }

  /// The timeout is transaction-local and also bounds lock waits during overlapping
  /// deployments. A failed query cannot leave a timeout on a pooled connection.
  func viewerHistoryRows(_ query: PostgresQuery) async throws -> [PostgresRow] {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query("SET LOCAL statement_timeout = '2s'", logger: logger)
      let rows = try await connection.query(query, logger: logger)
      var result: [PostgresRow] = []
      for try await row in rows { result.append(row) }
      return result
    }
  }

  /// Counts viewers the AppView holds projections for.
  ///
  /// `appview_viewer_feeds` and `appview_publication_scopes` are the two viewer-keyed projection
  /// tables written whenever a viewer's sidebar resolves, so their union is the AppView's view of
  /// the user population. They are small (one row per viewer feed / viewer publication) and both
  /// carry `updated_at`, unlike `read_marks`, which would need a full scan to count viewers.
  /// The AppView tables are absent on deployments that point Operations at a separate database, so
  /// a missing relation degrades to `nil` rather than failing the overview.
  public func fetchViewerCounts(at: Date) async throws -> OperationsViewerCounts? {
    let rows = try await viewerHistoryRows(
      """
      WITH viewer_activity AS (
        SELECT viewer_did, MAX(updated_at) AS last_seen_at
        FROM (
          SELECT viewer_did, updated_at FROM appview_viewer_feeds
          UNION ALL
          SELECT viewer_did, updated_at FROM appview_publication_scopes
        ) viewers
        GROUP BY viewer_did
      )
      SELECT
        COUNT(*)::bigint,
        COUNT(*) FILTER (WHERE last_seen_at >= \(at.addingTimeInterval(-7 * 86_400)))::bigint,
        COUNT(*) FILTER (WHERE last_seen_at >= \(at.addingTimeInterval(-30 * 86_400)))::bigint
      FROM viewer_activity
      """
    )
    for row in rows {
      let value = try row.decode((Int64, Int64, Int64).self)
      return OperationsViewerCounts(
        knownViewers: Int(value.0),
        activeViewers7d: Int(value.1),
        activeViewers30d: Int(value.2),
        observedAt: at
      )
    }
    return nil
  }

}
