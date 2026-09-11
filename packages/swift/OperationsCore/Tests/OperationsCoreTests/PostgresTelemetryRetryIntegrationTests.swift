import Foundation
import Logging
import PostgresNIO
import Testing

@testable import OperationsCore

@Suite(
  "Operations PostgreSQL telemetry retry safety",
  .serialized,
  .enabled(
    if: ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"] != nil,
    "Requires an explicitly disposable migrated PostgreSQL database."
  )
)
struct PostgresTelemetryRetryIntegrationTests {
  private enum TestFailure: Error { case expectedTransactionFailure }

  @Test("permanent and ambiguous PostgreSQL errors stop on the first attempt")
  func unsafeErrorsAreNeverReplayed() async throws {
    try await withStore { _, pool, logger in
      let permanent = try await permanentError(pool: pool, logger: logger)
      var retryable = permanent
      retryable.closureError = PostgresTelemetryWriteBudget.Exhausted.transactionBudget
      #expect(PostgresTelemetryRetryPolicy.canRetry(retryable))

      var failedCommit = retryable
      failedCommit.commitError = CancellationError()
      var failedRollback = retryable
      failedRollback.rollbackError = CancellationError()
      var failedBegin = retryable
      failedBegin.beginError = CancellationError()
      let errors: [any Error] = [
        permanent, failedCommit, failedRollback, failedBegin,
        try #require(permanent.closureError),
      ]
      for error in errors {
        let exporter = ScriptedExporter(error: error)
        let buffer = OperationsTelemetryBuffer(
          capacity: 2, batchSize: 1, maxRetryAttempts: 5, logger: logger,
          exporter: { try await exporter.export($0) })
        #expect(await buffer.enqueue(Self.metric(name: "retry-safety", value: 1)))
        #expect(await buffer.enqueue(Self.metric(name: "retry-safety", value: 2)))
        #expect(await buffer.flushOnce() == 0)
        #expect(await exporter.attempts == 1)
        let failed = await buffer.snapshot()
        #expect(failed.queueDepth == 1 && failed.inFlightCount == 0)
        #expect(failed.droppedCount == 1 && failed.consecutiveFailures == 1)
        #expect(failed.lastDropAt != nil && failed.lastDropRecoveredAt == nil)
        #expect(await buffer.flushOnce() == 1)
        #expect(await exporter.attempts == 2)
        #expect(await buffer.snapshot().droppedCount == 1)
      }
    }
  }

  @Test("a lost commit acknowledgement never doubles an already committed metric")
  func ambiguousCommitPreservesSingleContribution() async throws {
    try await withStore { store, pool, logger in
      var commitFailure = try await permanentError(pool: pool, logger: logger)
      commitFailure.closureError = nil
      commitFailure.commitError = CancellationError()
      let exporter = ScriptedExporter(error: commitFailure, store: store)
      let buffer = OperationsTelemetryBuffer(
        capacity: 2, maxRetryAttempts: 5, logger: logger,
        exporter: { try await exporter.export($0) })
      let name = "ambiguous-commit.\(UUID().uuidString)"
      #expect(await buffer.enqueue(Self.metric(name: name, value: 7)))
      #expect(await buffer.flushOnce() == 0)
      #expect(await exporter.attempts == 1)
      #expect(await buffer.snapshot().droppedCount == 1)
      let rows = try await pool.query(
        "SELECT sample_count, value_sum FROM operations_metric_rollups WHERE metric_name = \(name)",
        logger: logger)
      var found = false
      for try await row in rows {
        let values = try row.decode((Int64, Double).self)
        #expect(values.0 == 1 && values.1 == 7)
        found = true
      }
      #expect(found)
    }
  }

  @Test("a confirmed transaction rollback retains the bounded retry behavior")
  func confirmedRollbackCanRetry() async throws {
    try await withStore { _, pool, logger in
      var failure = try await permanentError(pool: pool, logger: logger)
      failure.closureError = PostgresTelemetryWriteBudget.Exhausted.transactionBudget
      let exporter = ScriptedExporter(error: failure)
      let buffer = OperationsTelemetryBuffer(
        capacity: 1, maxRetryAttempts: 2, logger: logger,
        exporter: { try await exporter.export($0) })
      #expect(await buffer.enqueue(Self.metric(name: "safe-retry", value: 7)))
      #expect(await buffer.flushOnce() == 1)
      #expect(await exporter.attempts == 2)
      let snapshot = await buffer.snapshot()
      #expect(snapshot.droppedCount == 0 && snapshot.consecutiveFailures == 0)
      #expect(snapshot.lastSuccessfulExportAt != nil)
    }
  }

  private actor ScriptedExporter {
    let error: any Error
    let store: PostgresOperationsStore?
    private(set) var attempts = 0

    init(error: any Error, store: PostgresOperationsStore? = nil) {
      self.error = error
      self.store = store
    }

    func export(_ signals: [OperationsTelemetrySignal]) async throws {
      attempts += 1
      if let store { try await store.recordTelemetryBatch(signals) }
      if attempts == 1 { throw error }
    }
  }

  private static func metric(name: String, value: Double) -> OperationsTelemetrySignal {
    .metric(.init(name: name, value: value, dimensions: [:]))
  }

  private func permanentError(pool: PostgresClient, logger: Logger) async throws
    -> PostgresTransactionError
  {
    do {
      try await pool.withTransaction(logger: logger) { connection in
        let rows = try await connection.query("SELECT 1 / 0", logger: logger)
        for try await _ in rows {}
      }
    } catch let error as PostgresTransactionError {
      return error
    }
    throw TestFailure.expectedTransactionFailure
  }

  private func withStore(
    _ body: (PostgresOperationsStore, PostgresClient, Logger) async throws -> Void
  ) async throws {
    let rawURL = try #require(ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"])
    let url = try #require(URL(string: rawURL))
    let host = try #require(url.host)
    let username = try #require(url.user)
    let logger = Logger(label: "operations-postgres-retry.tests")
    var config = PostgresClient.Configuration(
      host: host, port: url.port ?? 5432, username: username, password: url.password,
      database: String(url.path.dropFirst()), tls: .disable)
    config.options.maximumConnections = 4
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let task = Task { await pool.run() }
    defer { task.cancel() }
    try await body(
      PostgresOperationsStore(pool: pool, environment: "prod", logger: logger), pool, logger)
  }
}
