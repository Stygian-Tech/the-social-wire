import Foundation
import Logging
import PostgresNIO

/// Imported sources live in the AppView database, independently of Corpus cleanup.
actor FinanceSnapshotRetention {
  private let pool: PostgresClient
  private let logger: Logger
  private var lastAttempt: Date?

  init(pool: PostgresClient, logger: Logger) {
    self.pool = pool; self.logger = logger
  }

  /// Expired source deletion cascades to its snapshots. Maintenance never blocks feed availability.
  func purgeIfDue(now: Date) async -> Int {
    if let lastAttempt, now.timeIntervalSince(lastAttempt) < 60 { return 0 }
    // Set before suspension to prevent concurrent requests from scheduling duplicate sweeps.
    lastAttempt = now
    do {
      return try await pool.withTransaction(logger: logger) { connection in
        try await connection.query("SET LOCAL lock_timeout = '500ms'", logger: self.logger)
        try await connection.query("SET LOCAL statement_timeout = '5s'", logger: self.logger)
        let rows = try await connection.query("""
          WITH expired AS (
            SELECT generation_id FROM finance_generations
            WHERE expires_at <= \(now)
            ORDER BY expires_at LIMIT 100 FOR UPDATE SKIP LOCKED
          )
          DELETE FROM finance_generations generation USING expired
          WHERE generation.generation_id = expired.generation_id
          RETURNING generation.generation_id
          """, logger: self.logger)
        var deleted = 0
        for try await _ in rows { deleted += 1 }
        return deleted
      }
    } catch {
      logger.warning("Finance snapshot retention maintenance unavailable")
      return 0
    }
  }
}
