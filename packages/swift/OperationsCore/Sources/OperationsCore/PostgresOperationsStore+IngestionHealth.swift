import Foundation
import PostgresNIO

extension PostgresOperationsStore {
  public func fetchIngestionGenerationHealth(
    sourceGeneration: String, at: Date
  ) async throws -> IngestionGenerationHealthSnapshot {
    try Task.checkCancellation()
    return try await pool.withTransaction(logger: logger) { connection in
      // One statement observes the checkpoint, fenced intake lease and actionable
      // inbox together. A blocked or overloaded query must never become a healthy zero.
      try await connection.query("SET LOCAL statement_timeout = '2s'", logger: logger)
      let rows = try await connection.query(
        Self.ingestionGenerationHealthQuery(
          environment: environment, sourceGeneration: sourceGeneration, at: at), logger: logger)
      var result: IngestionGenerationHealthSnapshot?
      for try await row in rows {
        let value = row.makeRandomAccess()
        let hasCheckpoint = try value["source_generation"].decode(String?.self) != nil
        result = IngestionGenerationHealthSnapshot(
          checkpoint: hasCheckpoint ? try Self.durabilityCheckpoint(row) : nil,
          pending: Int(try value["pending_count"].decode(Int64.self)),
          leased: Int(try value["leased_count"].decode(Int64.self)),
          retrying: Int(try value["retry_count"].decode(Int64.self)),
          deadLetters: Int(try value["dead_letter_count"].decode(Int64.self)),
          oldestPendingAt: try value["oldest_pending_at"].decode(Date?.self), observedAt: at)
      }
      try Task.checkCancellation()
      guard let result else { throw OperationsStoreError.notFound }
      return result
    }
  }

  static func ingestionGenerationHealthQuery(
    environment: String, sourceGeneration: String, at: Date
  ) -> PostgresQuery {
    """
    WITH actionable AS (
      SELECT COUNT(*) FILTER (WHERE status = 'pending')::bigint AS pending_count,
        COUNT(*) FILTER (WHERE status = 'leased')::bigint AS leased_count,
        COUNT(*) FILTER (WHERE status = 'retry')::bigint AS retry_count,
        MIN(staged_at) AS oldest_pending_at
      FROM appview_ingestion_inbox
      WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
        AND status IN ('pending', 'leased', 'retry')
    ), dead_letters AS (
      SELECT COUNT(*)::bigint AS dead_letter_count
      FROM appview_ingestion_inbox
      WHERE environment = \(environment) AND source_generation = \(sourceGeneration)
        AND status = 'dead_letter' AND reconciled_at IS NULL
    ), checkpoint AS (
      SELECT checkpoint.*,
        (SELECT MAX(lease.updated_at) FROM appview_ingestion_leases lease
         WHERE lease.environment = checkpoint.environment
           AND lease.source_generation = checkpoint.source_generation
           AND lease.released_at IS NULL AND lease.lease_expires_at >= \(at))
          AS intake_heartbeat_at
      FROM appview_jetstream_checkpoints checkpoint
      WHERE checkpoint.environment = \(environment) AND checkpoint.source_generation = \(sourceGeneration)
    )
    SELECT checkpoint.*, actionable.*, dead_letters.*
    FROM actionable CROSS JOIN dead_letters LEFT JOIN checkpoint ON TRUE
    """
  }
}
