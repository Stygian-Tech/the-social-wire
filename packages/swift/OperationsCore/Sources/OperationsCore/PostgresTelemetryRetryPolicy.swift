import PostgresNIO

/// Only a completed rollback permits replaying additive metrics beyond the initial retry budget.
/// A lost COMMIT response is ambiguous and must never be treated as database contention.
enum PostgresTelemetryRetryPolicy {
  static func canDefer(_ error: any Error) -> Bool {
    guard let transaction = error as? PostgresTransactionError,
      transaction.beginError == nil, transaction.commitError == nil,
      transaction.rollbackError == nil, let failure = transaction.closureError
    else { return false }
    if failure is PostgresTelemetryWriteBudget.Exhausted { return true }
    guard let postgres = failure as? PSQLError,
      let state = postgres.serverInfo?[.sqlState]
    else { return false }
    // Lock timeout, deadlock, serialization failure, or a server-cancelled statement.
    return ["55P03", "40P01", "40001", "57014"].contains(state)
  }
}
