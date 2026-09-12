import Logging
import PostgresNIO

public enum PostgresRoleLeaseFence {
  /// The caller must already hold a transaction on this connection. Keep the fenced body
  /// short: ranking, HTTP requests, and other preparation belong before this boundary.
  public static func lockAndValidate(
    _ authority: RoleLeaseAuthority,
    connection: PostgresConnection,
    logger: Logger
  ) async throws {
    try FencedRoleLease.validate(role: authority.role, ownerID: authority.ownerID)
    try await setTimeouts(connection: connection, logger: logger)
    let locked = try await PostgresRoleLeaseBudget.query(
      """
      SELECT fencing_token FROM operations_role_leases
      WHERE environment = \(authority.environment) AND role = \(authority.role)
      FOR UPDATE
      """, connection: connection, logger: logger)
    var found = false
    for _ in locked { found = true }
    guard found else { throw OperationsStoreError.leaseConflict }
    // Check server time in a separate statement AFTER the row lock is acquired. A
    // request-start timestamp must not authorize work after a delayed lock wait.
    let rows = try await PostgresRoleLeaseBudget.query(
      """
      SELECT EXISTS (
        SELECT 1 FROM operations_role_leases
        WHERE environment = \(authority.environment) AND role = \(authority.role)
          AND owner_id = \(authority.ownerID) AND fencing_token = \(authority.fencingToken)
          AND released_at IS NULL AND lease_expires_at > clock_timestamp()
      )
      """, connection: connection, logger: logger)
    for row in rows {
      guard try row.decode(Bool.self) else { throw OperationsStoreError.leaseConflict }
      return
    }
    throw OperationsStoreError.leaseConflict
  }

  static func setTimeouts(connection: PostgresConnection, logger: Logger) async throws {
    _ = try await PostgresRoleLeaseBudget.query("SET LOCAL statement_timeout = '2s'", connection: connection, logger: logger)
    _ = try await PostgresRoleLeaseBudget.query("SET LOCAL lock_timeout = '500ms'", connection: connection, logger: logger)
  }
}
