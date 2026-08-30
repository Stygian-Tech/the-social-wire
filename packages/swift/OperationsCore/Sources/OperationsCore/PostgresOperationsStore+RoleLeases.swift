import Foundation
import PostgresNIO

extension PostgresOperationsStore {
  public func acquireRoleLease(
    role: String,
    ownerID: String,
    leaseUntil: Date,
    at: Date
  ) async throws -> FencedRoleLease? {
    try FencedRoleLease.validate(role: role, ownerID: ownerID)
    guard leaseUntil > at else { throw OperationsStoreError.invalidProgress }
    let rows = try await pool.query(
      """
      INSERT INTO operations_role_leases
        (environment, role, owner_id, fencing_token, acquired_at, lease_expires_at,
         released_at, updated_at)
      VALUES (\(environment), \(role), \(ownerID), 1, \(at), \(leaseUntil),
        NULL, \(at))
      ON CONFLICT (environment, role) DO UPDATE SET
        owner_id = EXCLUDED.owner_id,
        fencing_token = CASE
          WHEN operations_role_leases.owner_id = EXCLUDED.owner_id
            AND operations_role_leases.released_at IS NULL
            AND operations_role_leases.lease_expires_at > \(at)
          THEN operations_role_leases.fencing_token
          ELSE operations_role_leases.fencing_token + 1 END,
        acquired_at = CASE
          WHEN operations_role_leases.owner_id = EXCLUDED.owner_id
            AND operations_role_leases.released_at IS NULL
            AND operations_role_leases.lease_expires_at > \(at)
          THEN operations_role_leases.acquired_at ELSE EXCLUDED.acquired_at END,
        lease_expires_at = EXCLUDED.lease_expires_at, released_at = NULL,
        updated_at = EXCLUDED.updated_at
      WHERE operations_role_leases.released_at IS NOT NULL
        OR operations_role_leases.lease_expires_at <= \(at)
        OR operations_role_leases.owner_id = EXCLUDED.owner_id
      RETURNING environment, role, owner_id, fencing_token, acquired_at, lease_expires_at,
        updated_at
      """,
      logger: logger
    )
    for try await row in rows { return try Self.fencedRoleLease(row) }
    return nil
  }

  public func renewRoleLease(
    role: String,
    ownerID: String,
    fencingToken: Int64,
    leaseUntil: Date,
    at: Date
  ) async throws -> FencedRoleLease {
    try FencedRoleLease.validate(role: role, ownerID: ownerID)
    guard leaseUntil > at else { throw OperationsStoreError.invalidProgress }
    let rows = try await pool.query(
      """
      UPDATE operations_role_leases
      SET lease_expires_at = \(leaseUntil), updated_at = \(at)
      WHERE environment = \(environment) AND role = \(role)
        AND owner_id = \(ownerID) AND fencing_token = \(fencingToken)
        AND released_at IS NULL AND lease_expires_at >= \(at)
      RETURNING environment, role, owner_id, fencing_token, acquired_at, lease_expires_at,
        updated_at
      """,
      logger: logger
    )
    for try await row in rows { return try Self.fencedRoleLease(row) }
    throw OperationsStoreError.leaseConflict
  }

  public func releaseRoleLease(
    role: String,
    ownerID: String,
    fencingToken: Int64,
    at: Date
  ) async throws {
    try FencedRoleLease.validate(role: role, ownerID: ownerID)
    let rows = try await pool.query(
      """
      UPDATE operations_role_leases
      SET released_at = \(at), updated_at = \(at)
      WHERE environment = \(environment) AND role = \(role)
        AND owner_id = \(ownerID) AND fencing_token = \(fencingToken)
        AND released_at IS NULL
      RETURNING fencing_token
      """,
      logger: logger
    )
    for try await _ in rows { return }
    throw OperationsStoreError.leaseConflict
  }

  public func withRoleLeaseFence(
    role: String,
    ownerID: String,
    fencingToken: Int64,
    at: Date,
    operation: @Sendable @escaping () async throws -> Void
  ) async throws {
    try FencedRoleLease.validate(role: role, ownerID: ownerID)
    try await pool.withTransaction(logger: logger) { connection in
      let rows = try await connection.query(
        """
        SELECT fencing_token
        FROM operations_role_leases
        WHERE environment = \(environment) AND role = \(role)
          AND owner_id = \(ownerID) AND fencing_token = \(fencingToken)
          AND released_at IS NULL AND lease_expires_at >= \(at)
        FOR UPDATE
        """,
        logger: logger
      )
      var valid = false
      for try await _ in rows { valid = true }
      guard valid else { throw OperationsStoreError.leaseConflict }
      try await operation()
    }
  }

  private static func fencedRoleLease(_ row: PostgresRow) throws -> FencedRoleLease {
    let value = row.makeRandomAccess()
    return FencedRoleLease(
      environment: try value["environment"].decode(String.self),
      role: try value["role"].decode(String.self),
      ownerID: try value["owner_id"].decode(String.self),
      fencingToken: try value["fencing_token"].decode(Int64.self),
      acquiredAt: try value["acquired_at"].decode(Date.self),
      expiresAt: try value["lease_expires_at"].decode(Date.self),
      updatedAt: try value["updated_at"].decode(Date.self)
    )
  }
}
