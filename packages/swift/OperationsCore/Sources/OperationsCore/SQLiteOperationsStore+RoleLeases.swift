import Foundation
@preconcurrency import GRDB

extension SQLiteOperationsStore {
  public func acquireRoleLease(
    role: String,
    ownerID: String,
    leaseUntil: Date,
    at: Date
  ) async throws -> FencedRoleLease? {
    try FencedRoleLease.validate(role: role, ownerID: ownerID)
    guard leaseUntil > at else { throw OperationsStoreError.invalidProgress }
    let activeFence = roleLeaseFenceCounts[role]
    if let activeFence, activeFence.ownerID != ownerID {
      return nil
    }
    return try await db.write { database in
      let existing = try Row.fetchOne(
        database,
        sql: "SELECT * FROM operations_role_leases WHERE environment = ? AND role = ?",
        arguments: [environment, role]
      )
      let existingExpiry = Self.date(existing?["lease_expires_at"])
      let existingReleased: String? = existing?["released_at"]
      let existingOwner: String? = existing?["owner_id"]
      if existing != nil, existingReleased == nil, let existingExpiry, existingExpiry > at,
        existingOwner != ownerID
      {
        return nil
      }
      let sameLease = existing != nil && existingReleased == nil
        && existingExpiry.map { $0 > at } == true && existingOwner == ownerID
      if activeFence != nil, !sameLease { return nil }
      let existingToken: Int64 = existing?["fencing_token"] ?? 0
      let token = sameLease ? existingToken : existingToken + 1
      let acquiredAt: String = sameLease ? (existing?["acquired_at"] ?? Self.iso(at)) : Self.iso(at)
      try database.execute(
        sql: """
          INSERT INTO operations_role_leases
            (environment, role, owner_id, fencing_token, acquired_at, lease_expires_at,
             released_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, NULL, ?)
          ON CONFLICT (environment, role) DO UPDATE SET
            owner_id = excluded.owner_id, fencing_token = excluded.fencing_token,
            acquired_at = excluded.acquired_at, lease_expires_at = excluded.lease_expires_at,
            released_at = NULL, updated_at = excluded.updated_at
          """,
        arguments: [
          environment, role, ownerID, token, acquiredAt, Self.iso(leaseUntil), Self.iso(at),
        ]
      )
      guard let row = try Row.fetchOne(
        database,
        sql: "SELECT * FROM operations_role_leases WHERE environment = ? AND role = ?",
        arguments: [environment, role]
      ), let lease = Self.fencedRoleLease(row)
      else { throw OperationsStoreError.missingCreatedRecord }
      return lease
    }
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
    return try await db.write { database in
      try database.execute(
        sql: """
          UPDATE operations_role_leases SET lease_expires_at = ?, updated_at = ?
          WHERE environment = ? AND role = ? AND owner_id = ? AND fencing_token = ?
            AND released_at IS NULL AND lease_expires_at >= ?
          """,
        arguments: [
          Self.iso(leaseUntil), Self.iso(at), environment, role, ownerID, fencingToken,
          Self.iso(at),
        ]
      )
      guard database.changesCount == 1,
        let row = try Row.fetchOne(
          database,
          sql: "SELECT * FROM operations_role_leases WHERE environment = ? AND role = ?",
          arguments: [environment, role]
        ), let lease = Self.fencedRoleLease(row)
      else { throw OperationsStoreError.leaseConflict }
      return lease
    }
  }

  public func releaseRoleLease(
    role: String,
    ownerID: String,
    fencingToken: Int64,
    at: Date
  ) async throws {
    try FencedRoleLease.validate(role: role, ownerID: ownerID)
    if let fence = roleLeaseFenceCounts[role],
      fence.ownerID == ownerID, fence.fencingToken == fencingToken
    {
      throw OperationsStoreError.leaseConflict
    }
    try await db.write { database in
      try database.execute(
        sql: """
          UPDATE operations_role_leases SET released_at = ?, updated_at = ?
          WHERE environment = ? AND role = ? AND owner_id = ? AND fencing_token = ?
            AND released_at IS NULL
          """,
        arguments: [Self.iso(at), Self.iso(at), environment, role, ownerID, fencingToken]
      )
      guard database.changesCount == 1 else { throw OperationsStoreError.leaseConflict }
    }
  }

  public func withRoleLeaseFence(
    role: String,
    ownerID: String,
    fencingToken: Int64,
    at: Date,
    operation: @Sendable @escaping () async throws -> Void
  ) async throws {
    try FencedRoleLease.validate(role: role, ownerID: ownerID)
    if let existing = roleLeaseFenceCounts[role] {
      guard existing.ownerID == ownerID, existing.fencingToken == fencingToken else {
        throw OperationsStoreError.leaseConflict
      }
      roleLeaseFenceCounts[role] = RoleLeaseFenceState(
        ownerID: ownerID, fencingToken: fencingToken, count: existing.count + 1
      )
    } else {
      roleLeaseFenceCounts[role] = RoleLeaseFenceState(
        ownerID: ownerID, fencingToken: fencingToken, count: 1
      )
    }
    defer {
      if let existing = roleLeaseFenceCounts[role] {
        if existing.count == 1 {
          roleLeaseFenceCounts.removeValue(forKey: role)
        } else {
          roleLeaseFenceCounts[role] = RoleLeaseFenceState(
            ownerID: ownerID, fencingToken: fencingToken, count: existing.count - 1
          )
        }
      }
    }
    let valid = try await db.read { database in
      try Bool.fetchOne(
        database,
        sql: """
          SELECT EXISTS(
            SELECT 1 FROM operations_role_leases
            WHERE environment = ? AND role = ? AND owner_id = ? AND fencing_token = ?
              AND released_at IS NULL AND lease_expires_at >= ?)
          """,
        arguments: [environment, role, ownerID, fencingToken, Self.iso(at)]
      ) ?? false
    }
    guard valid else { throw OperationsStoreError.leaseConflict }
    try await operation()
  }

  private static func fencedRoleLease(_ row: Row) -> FencedRoleLease? {
    guard let acquiredAt = date(row["acquired_at"]),
      let expiresAt = date(row["lease_expires_at"]),
      let updatedAt = date(row["updated_at"])
    else { return nil }
    return FencedRoleLease(
      environment: row["environment"], role: row["role"], ownerID: row["owner_id"],
      fencingToken: row["fencing_token"], acquiredAt: acquiredAt,
      expiresAt: expiresAt, updatedAt: updatedAt
    )
  }
}

struct RoleLeaseFenceState: Sendable {
  let ownerID: String
  let fencingToken: Int64
  let count: Int
}
