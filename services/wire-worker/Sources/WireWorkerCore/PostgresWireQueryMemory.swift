import Logging
import PostgresNIO

/// A measured query budget inside an existing transaction, never a pooled session setting.
enum PostgresWireQueryMemory {
  static func withWorkMemory<Value>(
    megabytes: Int,
    connection: PostgresConnection,
    logger: Logger,
    serial: Bool = false,
    operation: () async throws -> Value
  ) async throws -> Value {
    precondition(megabytes > 0)
    try Task.checkCancellation()
    let previous = try await connection.query(
      "SELECT current_setting('work_mem'), current_setting('max_parallel_workers_per_gather')",
      logger: logger
    ).get()
    let original = try previous.rows[0].decode((String, String).self)
    func restore() async throws {
      _ = try await connection.query(
        "SELECT set_config('work_mem', \(original.0), true)", logger: logger
      ).get()
      if serial {
        _ = try await connection.query(
          "SELECT set_config('max_parallel_workers_per_gather', \(original.1), true)",
          logger: logger
        ).get()
      }
    }
    do {
      _ = try await connection.query(
        "SELECT set_config('work_mem', \(String(megabytes) + "MB"), true)", logger: logger
      ).get()
      if serial {
        // Parallel hashes allocate shared memory; the measured serial candidate plan
        // avoids exhausting Railway's small /dev/shm mount at the larger query budget.
        _ = try await connection.query(
          "SET LOCAL max_parallel_workers_per_gather = 0", logger: logger
        ).get()
      }
      try Task.checkCancellation()
      let value = try await operation()
      try Task.checkCancellation()
      try await restore()
      return value
    } catch {
      // A SQL error can abort the transaction and prevent restoration here. The owning
      // transaction must then roll back, which also discards these local settings.
      try? await restore()
      throw error
    }
  }
}
