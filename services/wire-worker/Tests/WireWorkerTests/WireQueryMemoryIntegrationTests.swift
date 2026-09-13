import Foundation
import Logging
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("query memory restores the prior local value and pooled setting on commit", arguments: [16, 64], [false, true])
  func queryMemoryCommit(megabytes: Int, serial: Bool) async throws {
    try await WireRollupIntegrationFixture.run { fixture in
      try await fixture.pool.withConnection { connection in
        let original = try await memoryState(connection, logger: fixture.logger)
        try await connection.withTransaction(logger: fixture.logger) { connection in
          _ = try await connection.query("SET LOCAL work_mem = '2MB'", logger: fixture.logger).get()
          _ = try await connection.query("SET LOCAL max_parallel_workers_per_gather = 1", logger: fixture.logger).get()
          let value = try await PostgresWireQueryMemory.withWorkMemory(
            megabytes: megabytes, connection: connection, logger: fixture.logger, serial: serial
          ) {
            let inside = try await memoryState(connection, logger: fixture.logger)
            #expect(inside.memory == "\(megabytes)MB")
            #expect(inside.pid == original.pid)
            #expect(inside.parallelWorkers == (serial ? "0" : "1"))
            return 42
          }
          #expect(value == 42)
          let restored = try await memoryState(connection, logger: fixture.logger)
          #expect(restored.memory == "2MB")
          #expect(restored.parallelWorkers == "1")
        }
        let after = try await memoryState(connection, logger: fixture.logger)
        #expect(after.memory == original.memory)
        #expect(after.pid == original.pid)
        #expect(after.parallelWorkers == original.parallelWorkers)
      }
    }
  }

  @Test("query memory resets after PostgreSQL failure on the same held connection", arguments: [16, 64], [false, true])
  func queryMemoryRollback(megabytes: Int, serial: Bool) async throws {
    try await WireRollupIntegrationFixture.run { fixture in
      try await fixture.pool.withConnection { connection in
        let original = try await memoryState(connection, logger: fixture.logger)
        do {
          try await connection.withTransaction(logger: fixture.logger) { connection in
            try await PostgresWireQueryMemory.withWorkMemory(
              megabytes: megabytes, connection: connection, logger: fixture.logger, serial: serial
            ) {
              let inside = try await memoryState(connection, logger: fixture.logger)
              #expect(inside.memory == "\(megabytes)MB")
              #expect(inside.parallelWorkers == (serial ? "0" : original.parallelWorkers))
              _ = try await connection.query("SELECT 1 / 0", logger: fixture.logger).get()
            }
          }
          Issue.record("Expected the original division-by-zero error")
        } catch let error as PostgresTransactionError {
          let cause = try #require(error.closureError as? PSQLError)
          #expect(cause.serverInfo?[.sqlState] == "22012")
          #expect(error.rollbackError == nil)
        }
        let after = try await memoryState(connection, logger: fixture.logger)
        #expect(after.memory == original.memory)
        #expect(after.pid == original.pid)
        #expect(after.parallelWorkers == original.parallelWorkers)
      }
    }
  }

  @Test("cancellation after a query response rolls back and resets memory", arguments: [16, 64], [false, true])
  func queryMemoryCancellation(megabytes: Int, serial: Bool) async throws {
    try await WireRollupIntegrationFixture.run { fixture in
      try await fixture.pool.withConnection { connection in
        let original = try await memoryState(connection, logger: fixture.logger)
        let cancelled = Task {
          try await connection.withTransaction(logger: fixture.logger) { connection in
            try await PostgresWireQueryMemory.withWorkMemory(
              megabytes: megabytes, connection: connection, logger: fixture.logger, serial: serial
            ) {
              let inside = try await memoryState(connection, logger: fixture.logger)
              #expect(inside.memory == "\(megabytes)MB")
              #expect(inside.parallelWorkers == (serial ? "0" : original.parallelWorkers))
              // A response can win the race with ownership cancellation. Even if the
              // operation returns normally, the memory scope must not commit success.
              withUnsafeCurrentTask { $0?.cancel() }
              return 42
            }
          }
        }
        do {
          _ = try await cancelled.value
          Issue.record("Cancelled work must not commit success")
        } catch let error as PostgresTransactionError {
          #expect(error.closureError is CancellationError)
          #expect(error.rollbackError == nil)
        }
        let after = try await memoryState(connection, logger: fixture.logger)
        #expect(after.memory == original.memory)
        #expect(after.pid == original.pid)
        #expect(after.parallelWorkers == original.parallelWorkers)
      }
    }
  }

  @Test("a row decoding failure restores query memory before leaving the transaction")
  func queryMemoryDecodeFailure() async throws {
    try await WireRollupIntegrationFixture.run { fixture in
      try await fixture.pool.withConnection { connection in
        let original = try await memoryState(connection, logger: fixture.logger)
        try await connection.withTransaction(logger: fixture.logger) { connection in
          do {
            try await PostgresWireQueryMemory.withWorkMemory(
              megabytes: 64, connection: connection, logger: fixture.logger, serial: true
            ) {
              let inside = try await memoryState(connection, logger: fixture.logger)
              #expect(inside.memory == "64MB")
              #expect(inside.parallelWorkers == "0")
              let rows = try await connection.query("SELECT 'not-an-integer'::text", logger: fixture.logger)
              for try await row in rows { _ = try row.decode(Int.self) }
            }
            Issue.record("Expected candidate-style row decoding to fail")
          } catch is PostgresDecodingError {}
          // Decoding errors do not abort PostgreSQL's transaction. Restoration must
          // already have happened even if its caller handles the error and continues.
          let afterFailure = try await memoryState(connection, logger: fixture.logger)
          #expect(afterFailure.memory == original.memory)
          #expect(afterFailure.pid == original.pid)
          #expect(afterFailure.parallelWorkers == original.parallelWorkers)
        }
      }
    }
  }

  private func memoryState(
    _ connection: PostgresConnection, logger: Logger
  ) async throws -> (memory: String, pid: Int, parallelWorkers: String) {
    let result = try await connection.query(
      "SELECT current_setting('work_mem'), pg_backend_pid(), current_setting('max_parallel_workers_per_gather')", logger: logger
    ).get()
    return try result.rows[0].decode((String, Int, String).self)
  }
}
