import Foundation
@preconcurrency import GRDB

extension SQLiteOperationsStore {
  public func fetchIngestionGenerationHealth(
    sourceGeneration: String, at: Date
  ) async throws -> IngestionGenerationHealthSnapshot {
    try Task.checkCancellation()
    return try await db.read { database in
      let row = try Row.fetchOne(database, sql: """
        WITH actionable AS (
          SELECT COALESCE(SUM(status = 'pending'), 0) AS pending_count,
            COALESCE(SUM(status = 'leased'), 0) AS leased_count,
            COALESCE(SUM(status = 'retry'), 0) AS retry_count,
            MIN(staged_at) AS oldest_pending_at
          FROM appview_ingestion_inbox
          WHERE environment = ? AND source_generation = ?
            AND status IN ('pending', 'leased', 'retry')
        ), dead_letters AS (
          SELECT COUNT(*) AS dead_letter_count FROM appview_ingestion_inbox
          WHERE environment = ? AND source_generation = ?
            AND status = 'dead_letter' AND reconciled_at IS NULL
        ), checkpoint AS (
          SELECT checkpoint.*,
            (SELECT MAX(lease.updated_at) FROM appview_ingestion_leases lease
             WHERE lease.environment = checkpoint.environment
               AND lease.source_generation = checkpoint.source_generation
               AND lease.released_at IS NULL AND lease.lease_expires_at >= ?)
              AS intake_heartbeat_at
          FROM appview_jetstream_checkpoints checkpoint
          WHERE checkpoint.environment = ? AND checkpoint.source_generation = ?
        )
        SELECT checkpoint.*, actionable.*, dead_letters.*
        FROM actionable CROSS JOIN dead_letters LEFT JOIN checkpoint ON TRUE
        """, arguments: [environment, sourceGeneration, environment, sourceGeneration,
          Self.iso(at), environment, sourceGeneration])
      try Task.checkCancellation()
      guard let row else { throw OperationsStoreError.notFound }
      let generation: String? = row["source_generation"]
      return IngestionGenerationHealthSnapshot(
        checkpoint: generation == nil ? nil : Self.durabilityCheckpoint(row),
        pending: row["pending_count"], leased: row["leased_count"], retrying: row["retry_count"],
        deadLetters: row["dead_letter_count"], oldestPendingAt: Self.date(row["oldest_pending_at"]), observedAt: at)
    }
  }
}
