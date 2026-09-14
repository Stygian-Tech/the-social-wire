import PostgresNIO

extension PostgresOperationsStore {
  /// The hosted Coordinator passes authority into its own store; operator/API stores
  /// remain independently authorized and continue to use existing job versions.
  func lockCoordinatorAuthority(on connection: PostgresConnection) async throws {
    if let coordinatorAuthority {
      try await PostgresRoleLeaseFence.lockAndValidate(
        coordinatorAuthority, connection: connection, logger: logger)
    }
  }

  func coordinatorControlRows(_ query: PostgresQuery) async throws -> [PostgresRow] {
    guard coordinatorAuthority != nil else {
      let rows = try await pool.query(query, logger: logger)
      var result: [PostgresRow] = []
      for try await row in rows { result.append(row) }
      return result
    }
    return try await withCoordinatorTransaction { connection in
      let rows = try await connection.query(query, logger: logger)
      var result: [PostgresRow] = []
      for try await row in rows { result.append(row) }
      return result
    }
  }

  /// Prepare durable control changes before taking the role lock. Every successful
  /// return, including an empty claim or idempotent replay, must pass the final
  /// database-time authority check. Failure rolls back all prepared changes.
  func withCoordinatorTransaction<Value: Sendable>(
    _ operation: (PostgresConnection) async throws -> Value
  ) async throws -> Value {
    try await pool.withTransaction(logger: logger) { connection in
      // Preserve the existing per-statement bounds throughout preparation; moving
      // the fence must not remove its previous timeout coverage.
      if coordinatorAuthority != nil {
        try await PostgresRoleLeaseFence.setTimeouts(connection: connection, logger: logger)
      }
      let result = try await operation(connection)
      try await lockCoordinatorAuthority(on: connection)
      return result
    }
  }
}
