import Foundation
import Logging
import PostgresNIO
import Testing

@testable import OperationsCore

@Suite(
  "PostgreSQL telemetry actor isolation",
  .serialized,
  .enabled(
    if: ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"] != nil,
    "Requires an explicitly disposable migrated PostgreSQL database."
  )
)
struct PostgresTelemetryActorIsolationTests {
  @Test("a busy store actor cannot delay telemetry COMMIT after a rollup write")
  func commitDoesNotNeedStoreActor() async throws {
    let rawURL = try #require(ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"])
    let url = try #require(URL(string: rawURL))
    let logger = Logger(label: "operations-telemetry-isolation.tests")
    let applicationName = "telemetry-isolation-\(UUID().uuidString)"
    var config = PostgresClient.Configuration(
      host: try #require(url.host), port: url.port ?? 5432,
      username: try #require(url.user), password: url.password,
      database: String(url.path.dropFirst()), tls: .disable)
    config.options.maximumConnections = 4
    config.options.additionalStartupParameters = [("application_name", applicationName)]
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let running = Task { await pool.run() }
    defer { running.cancel() }
    let store = PostgresOperationsStore(pool: pool, environment: "prod", logger: logger)
    let name = "actor-isolation.\(UUID().uuidString)"
    let signal = OperationsTelemetrySignal.metric(.init(name: name, value: 7, dimensions: [:]))
    try await store.recordTelemetryBatch([signal])
    let gate = TelemetryActorTestGate()
    defer { gate.release() }
    var writer: Task<Void, any Error>?
    var occupation: Task<Void, Never>?
    try await pool.withTransaction(logger: logger) { blocker in
      try await blocker.query(
        "UPDATE operations_metric_rollups SET sample_count = sample_count WHERE metric_name = \(name)",
        logger: logger)
      writer = Task { try await store.recordTelemetryBatch([signal]) }
      // Wait until the exporter is suspended in PostgreSQL, before occupying its caller actor.
      var blocked = false
      for _ in 0..<30 {
        let rows = try await pool.query(
          """
          SELECT EXISTS (SELECT 1 FROM pg_stat_activity
            WHERE datname = current_database() AND wait_event_type = 'Lock'
              AND application_name = \(applicationName)
              AND query LIKE '%INSERT INTO operations_metric_rollups%')
          """, logger: logger)
        for try await row in rows { blocked = try row.decode(Bool.self) }
        if blocked { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      try #require(blocked)
      occupation = Task { await store.occupyActorForTelemetryTest(gate) }
      for _ in 0..<30 {
        if gate.started { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      try #require(gate.started)
    }
    // The actor is still occupied, so only a transaction independent of that actor
    // can make its updated value visible to another connection before release().
    var committed = false
    for _ in 0..<30 {
      let rows = try await pool.query(
        "SELECT sample_count FROM operations_metric_rollups WHERE metric_name = \(name)",
        logger: logger)
      for try await row in rows { committed = try row.decode(Int64.self) == 2 }
      if committed { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(committed)
    gate.release()
    try await writer?.value
    await occupation?.value
  }
}

/// This deliberately synchronous, bounded hold models unrelated store-actor CPU work.
/// Every field is protected by the condition, and the test always releases it on exit.
private final class TelemetryActorTestGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var didStart = false
  private var released = false

  var started: Bool {
    condition.lock()
    defer { condition.unlock() }
    return didStart
  }

  func occupy() {
    condition.lock()
    defer { condition.unlock() }
    didStart = true
    let deadline = Date().addingTimeInterval(5)
    while !released {
      if !condition.wait(until: deadline) { break }
    }
  }

  func release() {
    condition.lock()
    released = true
    condition.broadcast()
    condition.unlock()
  }
}

extension PostgresOperationsStore {
  fileprivate func occupyActorForTelemetryTest(_ gate: TelemetryActorTestGate) {
    gate.occupy()
  }
}
