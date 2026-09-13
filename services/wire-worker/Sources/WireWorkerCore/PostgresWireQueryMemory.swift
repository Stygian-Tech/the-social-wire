import Logging
import PostgresNIO

/// A measured query budget inside an existing transaction, never a pooled session setting.
enum PostgresWireQueryMemory {
  static func withWorkMemory<Value>(
    megabytes: Int,
    connection: PostgresConnection,
    logger: Logger,
    operation: () async throws -> Value
  ) async throws -> Value {
    precondition(megabytes > 0)
    try Task.checkCancellation()
    let previous = try await connection.query("SHOW work_mem", logger: logger).get()
    let original = try previous.rows[0].decode(String.self)
    do {
      _ = try await connection.query(
        "SELECT set_config('work_mem', \(String(megabytes) + "MB"), true)", logger: logger
      ).get()
      try Task.checkCancellation()
      let value = try await operation()
      try Task.checkCancellation()
      _ = try await connection.query(
        "SELECT set_config('work_mem', \(original), true)", logger: logger
      ).get()
      return value
    } catch {
      // A SQL error can abort the transaction and prevent restoration here. The owning
      // transaction must then roll back, which also discards this local setting.
      _ = try? await connection.query(
        "SELECT set_config('work_mem', \(original), true)", logger: logger
      ).get()
      throw error
    }
  }
}
