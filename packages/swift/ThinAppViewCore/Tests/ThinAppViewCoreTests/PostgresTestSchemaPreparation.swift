/// Repeated fixture DDL can deadlock with another suite's ordinary transactions.
/// Share one installation result per database, including failures, for this process.
actor PostgresTestSchemaPreparation {
  static let shared = PostgresTestSchemaPreparation()
  private var installations: [String: Task<Void, any Error>] = [:]

  func prepare(
    database: String,
    operation: @escaping @Sendable () async throws -> Void
  ) async throws {
    if let installation = installations[database] {
      return try await installation.value
    }
    let installation = Task { try await operation() }
    installations[database] = installation
    try await installation.value
  }
}
