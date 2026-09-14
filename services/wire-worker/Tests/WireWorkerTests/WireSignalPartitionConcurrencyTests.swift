import Foundation
import Logging
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("an existing signal partition bypasses the day creation lock", .timeLimit(.minutes(1)))
  func existingSignalPartitionDoesNotLockDay() async throws {
    try await withSignalPartitionFixture { fixture in
      try await fixture.pool.withTransaction(logger: fixture.logger) { connection in
        try await fixture.configure(connection)
        try await connection.query(
          "SELECT ensure_wire_signal_event_partition('2099-01-02'::date)", logger: fixture.logger)
      }
      try await fixture.pool.withTransaction(logger: fixture.logger) { holder in
        try await holder.query(
          "SELECT pg_advisory_xact_lock(hashtext('wire_signal_events'), hashtext('2099-01-02'))",
          logger: fixture.logger)
        try await fixture.pool.withTransaction(logger: fixture.logger) { caller in
          try await fixture.configure(caller)
          try await caller.query("SET LOCAL statement_timeout = '500ms'", logger: fixture.logger)
          try await caller.query(
            "SELECT ensure_wire_signal_event_partition('2099-01-02'::date)", logger: fixture.logger)
          let rows = try await caller.query(
            """
            SELECT COUNT(*)::bigint FROM pg_locks
            WHERE pid = pg_backend_pid() AND locktype = 'advisory' AND objsubid = 2
              AND classid = ((hashtext('wire_signal_events')::bigint & 4294967295)::oid)
            """, logger: fixture.logger)
          for try await row in rows { #expect(try row.decode(Int64.self) == 0) }
        }
      }
      try await fixture.verifyPartition()
    }
  }

  @Test(
    "concurrent signal partition creation rechecks after commit or rollback",
    .timeLimit(.minutes(1)), arguments: [false, true]
  )
  func concurrentSignalPartitionCreation(rollbackFirst: Bool) async throws {
    try await withSignalPartitionFixture { fixture in
      let created = AsyncStream<Void>.makeStream()
      let waitingPID = AsyncStream<Int32>.makeStream()
      try await withThrowingTaskGroup(of: Void.self) { tasks in
        tasks.addTask {
          defer { created.continuation.finish() }
          do {
            try await fixture.pool.withTransaction(logger: fixture.logger) { connection in
              try await fixture.configure(connection)
              try await connection.query(
                "SELECT ensure_wire_signal_event_partition('2099-01-02'::date)",
                logger: fixture.logger)
              created.continuation.yield()
              var pids = waitingPID.stream.makeAsyncIterator()
              guard let pid = await pids.next() else { throw CancellationError() }
              // Observe the second creator waiting on this exact lock before
              // releasing the first transaction; no timing-based race assumption.
              let deadline = Date().addingTimeInterval(5)
              var observedWait = false
              while Date() < deadline {
                try Task.checkCancellation()
                let rows = try await connection.query(
                  """
                  SELECT EXISTS (
                    SELECT 1 FROM pg_locks WHERE pid = \(pid) AND locktype = 'advisory'
                      AND objsubid = 2 AND NOT granted
                      AND classid = ((hashtext('wire_signal_events')::bigint & 4294967295)::oid)
                  )
                  """, logger: fixture.logger)
                for try await row in rows { observedWait = try row.decode(Bool.self) }
                if observedWait { break }
                try await Task.sleep(for: .milliseconds(5))
              }
              try #require(
                observedWait, "second creator must wait until the first transaction ends")
              if rollbackFirst { throw SignalPartitionFixtureRollback.requested }
            }
          } catch let error as PostgresTransactionError {
            guard rollbackFirst, error.closureError is SignalPartitionFixtureRollback else {
              throw error
            }
          } catch SignalPartitionFixtureRollback.requested {
            guard rollbackFirst else { throw SignalPartitionFixtureRollback.requested }
          }
        }
        tasks.addTask {
          defer { waitingPID.continuation.finish() }
          var ready = created.stream.makeAsyncIterator()
          guard await ready.next() != nil else { throw CancellationError() }
          try await fixture.pool.withTransaction(logger: fixture.logger) { connection in
            try await fixture.configure(connection)
            let rows = try await connection.query("SELECT pg_backend_pid()", logger: fixture.logger)
            for try await row in rows { waitingPID.continuation.yield(try row.decode(Int32.self)) }
            try await connection.query(
              "SELECT ensure_wire_signal_event_partition('2099-01-02'::date)",
              logger: fixture.logger)
          }
        }
        try await tasks.waitForAll()
      }
      try await fixture.verifyPartition()
    }
  }

  private func withSignalPartitionFixture(
    _ operation: @Sendable (WireSignalPartitionTestFixture) async throws -> Void
  ) async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-signal-partition.integration")
    let configuration = try PostgresWireConfig.make(
      from: url, maximumConnections: 4, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    defer { runTask.cancel() }
    let fixture = WireSignalPartitionTestFixture(pool: pool, logger: logger)
    do {
      try await fixture.create()
      try await operation(fixture)
    } catch {
      try? await fixture.remove()
      throw error
    }
    try await fixture.remove()
  }
}

private enum SignalPartitionFixtureRollback: Error { case requested }
