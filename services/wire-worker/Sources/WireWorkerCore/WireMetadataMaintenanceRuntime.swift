import Foundation
import Logging
import PostgresNIO

enum WireMetadataMaintenanceRuntime {
  /// Repair has its own durable cursor and runs independently of HTTP batch time.
  static func runRepair(
    store: PostgresWireLinkMetadataStore, logger: Logger, intervalMilliseconds: Int
  ) async throws {
    var nextLogAt = Date.distantPast
    var scanned: Int64 = 0
    var repaired: Int64 = 0
    var databaseSeconds: TimeInterval = 0
    var sweepStarted: Date?
    var lastFullSweepSeconds: TimeInterval?
    while !Task.isCancelled {
      do {
        try Task.checkCancellation()
        let started = Date()
        let progress = try await store.repairMetadataPage(asOf: started)
        let completed = Date()
        scanned += progress.scanned
        repaired += progress.repaired
        databaseSeconds += completed.timeIntervalSince(started)
        if progress.wrapped {
          if let sweepStarted { lastFullSweepSeconds = completed.timeIntervalSince(sweepStarted) }
          sweepStarted = completed
        }
        if started >= nextLogAt {
          logger.info("The Wire metadata repair advanced", metadata: [
            "rows_scanned": .stringConvertible(scanned),
            "rows_repaired": .stringConvertible(repaired),
            "database_wait_and_execution_ms": .stringConvertible(databaseSeconds * 1_000),
            "last_full_sweep_seconds": .string(lastFullSweepSeconds.map(String.init(describing:)) ?? "unknown"),
          ])
          nextLogAt = started.addingTimeInterval(60)
          scanned = 0
          repaired = 0
          databaseSeconds = 0
        }
      } catch is CancellationError { throw CancellationError() }
      catch {
        logger.error("The Wire metadata repair failed", metadata: ["failure_category": .string(failureCategory(error))])
      }
      try await Task.sleep(for: .milliseconds(max(250, intervalMilliseconds)))
    }
  }

  /// Explicit trial-only loop. Database tracking must be enabled separately; this
  /// process never enables triggers or changes the operator's tracking policy.
  static func runScheduling(store: PostgresWireLinkMetadataStore, logger: Logger) async throws {
    while !Task.isCancelled {
      do {
        try Task.checkCancellation()
        try await store.backfillMetadataScheduling()
        if let mismatches = try await store.validateMetadataSchedulingIfComplete(asOf: Date()) {
          logger.info("The Wire metadata scheduling parity checked", metadata: [
            "mismatches": .stringConvertible(mismatches),
          ])
        }
        try await store.cleanupMetadataScheduling()
      } catch is CancellationError { throw CancellationError() }
      catch {
        // A failed transaction is abandoned. The committed cursor only advances
        // atomically with its copied rows, so the next bounded pass is recoverable.
        logger.error("The Wire metadata scheduling maintenance failed", metadata: [
          "failure_category": .string(failureCategory(error)),
        ])
      }
      try await Task.sleep(for: .seconds(2))
    }
  }

  private static func failureCategory(_ error: any Error) -> String {
    if let transaction = error as? PostgresTransactionError, let cause = transaction.closureError {
      return failureCategory(cause)
    }
    guard let database = error as? PSQLError else { return "operation_failed" }
    switch database.serverInfo?[.sqlState] {
    case "40P01": return "deadlock"
    case "40001": return "serialization_conflict"
    case "57014": return "statement_timeout"
    case "55P03": return "lock_timeout"
    default: return "database_failed"
    }
  }
}
