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
    return try await pool.withTransaction(logger: logger) { connection in
      try await lockCoordinatorAuthority(on: connection)
      let rows = try await connection.query(query, logger: logger)
      var result: [PostgresRow] = []
      for try await row in rows { result.append(row) }
      return result
    }
  }
}
