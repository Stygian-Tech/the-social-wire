import Foundation

public protocol RoleLeaseStoring: Actor {
  func acquireRoleLease(role: String, ownerID: String, leaseUntil: Date, at: Date) async throws -> FencedRoleLease?
  func renewRoleLease(role: String, ownerID: String, fencingToken: Int64, leaseUntil: Date, at: Date) async throws -> FencedRoleLease
  func releaseRoleLease(role: String, ownerID: String, fencingToken: Int64, at: Date) async throws
  func withRoleLeaseFence(
    role: String, ownerID: String, fencingToken: Int64, at: Date,
    operation: @Sendable @escaping () async throws -> Void
  ) async throws
}
