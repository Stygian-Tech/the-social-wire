import PostgresNIO

/// Deliberately excludes SQL, error descriptions, server detail, and bound values.
public enum RoleLeaseFailure: String, Error, Sendable, Equatable {
  case leaseConflict, cancelled, operationTimedOut, authorityExpired
  case lockTimeout, statementCancelled, deadlock, serializationFailure
  case connectionUnavailable, unknown

  public var isTransient: Bool {
    switch self {
    case .operationTimedOut, .lockTimeout, .statementCancelled, .deadlock,
      .serializationFailure, .connectionUnavailable: true
    default: false
    }
  }

  public static func classify(_ error: any Error) -> Self {
    if let failure = error as? Self { return failure }
    if error is CancellationError { return .cancelled }
    if let failure = error as? OperationsStoreError, failure == .leaseConflict { return .leaseConflict }
    if let transaction = error as? PostgresTransactionError {
      for cause in [transaction.closureError, transaction.beginError, transaction.commitError, transaction.rollbackError] {
        if let cause {
          let classification = classify(cause)
          if classification != .unknown { return classification }
        }
      }
    }
    guard let postgres = error as? PSQLError else { return .unknown }
    switch postgres.serverInfo?[.sqlState] {
    case "55P03": return .lockTimeout
    case "57014": return .statementCancelled
    case "40P01": return .deadlock
    case "40001": return .serializationFailure
    case "08000", "08003", "08006", "08001", "08004", "57P01", "57P02", "57P03":
      return .connectionUnavailable
    default: break
    }
    switch postgres.code {
    case .connectionError, .serverClosedConnection, .clientClosedConnection, .poolClosed, .uncleanShutdown:
      return .connectionUnavailable
    case .queryCancelled: return .statementCancelled
    default: return .unknown
    }
  }
}
