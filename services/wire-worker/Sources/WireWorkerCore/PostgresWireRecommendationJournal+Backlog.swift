import Foundation
import PostgresNIO

extension PostgresWireRecommendationJournal {
  /// Each status reads at most the oldest 1,000 entries, including dependencies
  /// in backoff. The cap is explicit so a growing deferred queue stays visible.
  func backlog(asOf: Date, sourceScope: WireInboxSourceScope?) async throws -> WireRecommendationBacklog {
    var samples: [(Int, Double)] = []
    for status in ["pending", "conflict"] {
      var query = PostgresQuery.StringInterpolation(literalCapacity: 800, interpolationCount: 3)
      query.appendLiteral("""
        SELECT count(*)::bigint, min(event_time) FROM (
          SELECT event_time FROM wire_recommendation_journal
        """)
      // These two closed literals keep the partial backlog indexes available
      // to generic prepared plans. A parameterized status forces a full scan.
      query.appendLiteral(status == "pending" ? " WHERE status = 'pending'" : " WHERE status = 'conflict'")
      if let sourceScope {
        query.appendLiteral(" AND environment = ")
        query.appendInterpolation(sourceScope.environment)
        if !sourceScope.sourceGenerations.isEmpty {
          query.appendLiteral(" AND source_generation = ANY(")
          query.appendInterpolation(sourceScope.sourceGenerations)
          query.appendLiteral(")")
        }
      }
      query.appendLiteral(" ORDER BY event_time, environment, source_generation, seq LIMIT 1000) bounded")
      let rows = try await pool.query(PostgresQuery(stringInterpolation: query), logger: logger)
      for try await row in rows {
        let value = try row.decode((Int64, Date?).self)
        samples.append((Int(value.0), value.1.map { max(0, asOf.timeIntervalSince($0)) } ?? 0))
      }
    }
    return .init(pendingCount: samples[0].0, conflictCount: samples[1].0,
      oldestPendingAgeSeconds: samples[0].1, oldestConflictAgeSeconds: samples[1].1, countLimit: 1000)
  }
}
