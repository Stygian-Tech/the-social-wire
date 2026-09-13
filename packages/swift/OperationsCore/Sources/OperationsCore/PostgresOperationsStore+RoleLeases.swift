import Foundation
import Logging
import PostgresNIO

extension PostgresOperationsStore {
  public func acquireRoleLease(
    role: String, ownerID: String, leaseUntil: Date, at: Date
  ) async throws -> FencedRoleLease? {
    try FencedRoleLease.validate(role: role, ownerID: ownerID)
    let duration = leaseUntil.timeIntervalSince(at)
    guard duration.isFinite, duration > 0 else { throw OperationsStoreError.invalidProgress }
    let environment = environment
    let logger = logger
    return try await PostgresRoleLeaseBudget.withTransaction(pool: pool, logger: logger) { connection in
      _ = try await PostgresRoleLeaseBudget.query(
        """
        WITH instant AS (SELECT clock_timestamp() AS now)
        INSERT INTO operations_role_leases
          (environment, role, owner_id, fencing_token, acquired_at, lease_expires_at, released_at, updated_at)
        SELECT \(environment), \(role), \(ownerID), 1, instant.now,
          instant.now + \(duration) * INTERVAL '1 second', NULL, instant.now FROM instant
        ON CONFLICT (environment, role) DO NOTHING
        """, connection: connection, logger: logger)
      let locked = try await PostgresRoleLeaseBudget.query(
        """
        SELECT fencing_token FROM operations_role_leases
        WHERE environment = \(environment) AND role = \(role)
          AND (released_at IS NOT NULL OR lease_expires_at <= clock_timestamp()
            OR owner_id = \(ownerID))
        FOR UPDATE SKIP LOCKED
        """, connection: connection, logger: logger)
      // Standby polls must not lock a healthy owner's row or queue behind a
      // renewal/publication. The update below rechecks eligibility after locking.
      guard !locked.isEmpty else { return nil }
      // Sample server time after INSERT/row-lock waits have finished.
      let rows = try await PostgresRoleLeaseBudget.query(
        """
        WITH instant AS (SELECT clock_timestamp() AS now)
        UPDATE operations_role_leases AS lease SET
          owner_id = \(ownerID),
          fencing_token = CASE WHEN lease.owner_id = \(ownerID)
            AND lease.released_at IS NULL AND lease.lease_expires_at > instant.now
            THEN lease.fencing_token ELSE lease.fencing_token + 1 END,
          acquired_at = CASE WHEN lease.owner_id = \(ownerID)
            AND lease.released_at IS NULL AND lease.lease_expires_at > instant.now
            THEN lease.acquired_at ELSE instant.now END,
          lease_expires_at = instant.now + \(duration) * INTERVAL '1 second',
          released_at = NULL, updated_at = instant.now
        FROM instant
        WHERE lease.environment = \(environment) AND lease.role = \(role)
          AND (lease.released_at IS NOT NULL OR lease.lease_expires_at <= instant.now
            OR lease.owner_id = \(ownerID))
        RETURNING lease.environment, lease.role, lease.owner_id, lease.fencing_token,
          lease.acquired_at, lease.lease_expires_at, lease.updated_at
        """, connection: connection, logger: logger)
      for row in rows { return try Self.fencedRoleLease(row) }
      return nil
    }
  }

  public func renewRoleLease(
    role: String, ownerID: String, fencingToken: Int64, leaseUntil: Date, at: Date
  ) async throws -> FencedRoleLease {
    try FencedRoleLease.validate(role: role, ownerID: ownerID)
    let duration = leaseUntil.timeIntervalSince(at)
    guard duration.isFinite, duration > 0 else { throw OperationsStoreError.invalidProgress }
    let authority = RoleLeaseAuthority(environment: environment, role: role, ownerID: ownerID, fencingToken: fencingToken)
    let logger = logger
    return try await PostgresRoleLeaseBudget.withTransaction(pool: pool, logger: logger) { connection in
      try await PostgresRoleLeaseFence.lockAndValidate(authority, connection: connection, logger: logger)
      let rows = try await PostgresRoleLeaseBudget.query(
        """
        WITH instant AS (SELECT clock_timestamp() AS now)
        UPDATE operations_role_leases AS lease
        SET lease_expires_at = instant.now + \(duration) * INTERVAL '1 second', updated_at = instant.now
        FROM instant
        WHERE lease.environment = \(authority.environment) AND lease.role = \(role)
          AND lease.owner_id = \(ownerID) AND lease.fencing_token = \(fencingToken)
          AND lease.released_at IS NULL AND lease.lease_expires_at > instant.now
        RETURNING lease.environment, lease.role, lease.owner_id, lease.fencing_token,
          lease.acquired_at, lease.lease_expires_at, lease.updated_at
        """, connection: connection, logger: logger)
      for row in rows { return try Self.fencedRoleLease(row) }
      throw OperationsStoreError.leaseConflict
    }
  }

  public func releaseRoleLease(role: String, ownerID: String, fencingToken: Int64, at: Date) async throws {
    try FencedRoleLease.validate(role: role, ownerID: ownerID)
    let environment = environment
    let logger = logger
    try await PostgresRoleLeaseBudget.withTransaction(pool: pool, logger: logger) { connection in
      let rows = try await PostgresRoleLeaseBudget.query(
        """
        UPDATE operations_role_leases SET released_at = clock_timestamp(), updated_at = clock_timestamp()
        WHERE environment = \(environment) AND role = \(role)
          AND owner_id = \(ownerID) AND fencing_token = \(fencingToken) AND released_at IS NULL
        RETURNING fencing_token
        """, connection: connection, logger: logger)
      for _ in rows { return }
      throw OperationsStoreError.leaseConflict
    }
  }

  public func withRoleLeaseFence(
    role: String, ownerID: String, fencingToken: Int64, at: Date,
    operation: @Sendable @escaping () async throws -> Void
  ) async throws {
    let authority = RoleLeaseAuthority(environment: environment, role: role, ownerID: ownerID, fencingToken: fencingToken)
    let logger = logger
    try await PostgresRoleLeaseBudget.withTransaction(pool: pool, logger: logger) { connection in
      try await PostgresRoleLeaseFence.lockAndValidate(authority, connection: connection, logger: logger)
      try await operation()
    }
  }

  private static func fencedRoleLease(_ row: PostgresRow) throws -> FencedRoleLease {
    let value = row.makeRandomAccess()
    return FencedRoleLease(
      environment: try value["environment"].decode(String.self), role: try value["role"].decode(String.self),
      ownerID: try value["owner_id"].decode(String.self), fencingToken: try value["fencing_token"].decode(Int64.self),
      acquiredAt: try value["acquired_at"].decode(Date.self), expiresAt: try value["lease_expires_at"].decode(Date.self),
      updatedAt: try value["updated_at"].decode(Date.self))
  }
}
