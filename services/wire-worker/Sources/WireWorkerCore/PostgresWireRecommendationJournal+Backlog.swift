import Foundation
import PostgresNIO

extension PostgresWireRecommendationJournal {
  /// Each status reads at most the oldest 1,000 entries, including dependencies
  /// in backoff. The cap is explicit so a growing deferred queue stays visible.
  func backlog(asOf: Date, sourceScope: WireInboxSourceScope?) async throws -> WireRecommendationBacklog {
    let environment = sourceScope?.environment
    let generations = sourceScope?.sourceGenerations ?? []
    var samples: [(Int, Double)] = []
    for status in ["pending", "conflict"] {
      let rows = try await pool.query(
        """
        SELECT count(*)::bigint, min(event_time) FROM (
          SELECT event_time FROM wire_recommendation_journal
          WHERE status = \(status)
            AND (\(environment)::text IS NULL OR environment = \(environment))
            AND (\(generations.isEmpty) OR source_generation = ANY(\(generations)))
          ORDER BY event_time, environment, source_generation, seq LIMIT 1000
        ) bounded
        """, logger: logger)
      for try await row in rows {
        let value = try row.decode((Int64, Date?).self)
        samples.append((Int(value.0), value.1.map { max(0, asOf.timeIntervalSince($0)) } ?? 0))
      }
    }
    return .init(pendingCount: samples[0].0, conflictCount: samples[1].0,
      oldestPendingAgeSeconds: samples[0].1, oldestConflictAgeSeconds: samples[1].1, countLimit: 1000)
  }
}
