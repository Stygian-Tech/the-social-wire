import Foundation
import Logging
import Testing

@testable import OperationsCore

@Suite("Fenced role leases")
struct FencedRoleLeaseTests {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("active owner reacquires idempotently and excludes contenders")
  func idempotentAcquire() async throws {
    try await withStore { store in
      let first = try #require(await store.acquireRoleLease(
        role: "wire-rank", ownerID: "replica-a",
        leaseUntil: now.addingTimeInterval(30), at: now
      ))
      let reacquired = try #require(await store.acquireRoleLease(
        role: "wire-rank", ownerID: "replica-a",
        leaseUntil: now.addingTimeInterval(45), at: now.addingTimeInterval(5)
      ))
      let contender = try await store.acquireRoleLease(
        role: "wire-rank", ownerID: "replica-b",
        leaseUntil: now.addingTimeInterval(45), at: now.addingTimeInterval(5)
      )

      #expect(first.fencingToken == 1)
      #expect(reacquired.fencingToken == first.fencingToken)
      #expect(reacquired.acquiredAt == first.acquiredAt)
      #expect(reacquired.expiresAt == now.addingTimeInterval(45))
      #expect(contender == nil)
    }
  }

  @Test("release permits a fenced successor and rejects the former owner")
  func releaseAndTakeover() async throws {
    try await withStore { store in
      let first = try #require(await store.acquireRoleLease(
        role: "rss-poll", ownerID: "replica-a",
        leaseUntil: now.addingTimeInterval(30), at: now
      ))
      let renewed = try await store.renewRoleLease(
        role: first.role, ownerID: first.ownerID, fencingToken: first.fencingToken,
        leaseUntil: now.addingTimeInterval(60), at: now.addingTimeInterval(5)
      )
      #expect(renewed.expiresAt == now.addingTimeInterval(60))

      try await store.releaseRoleLease(
        role: first.role, ownerID: first.ownerID, fencingToken: first.fencingToken,
        at: now.addingTimeInterval(6)
      )
      let successor = try #require(await store.acquireRoleLease(
        role: first.role, ownerID: "replica-b",
        leaseUntil: now.addingTimeInterval(70), at: now.addingTimeInterval(7)
      ))
      #expect(successor.fencingToken == first.fencingToken + 1)

      await #expect(throws: OperationsStoreError.leaseConflict) {
        _ = try await store.renewRoleLease(
          role: first.role, ownerID: first.ownerID, fencingToken: first.fencingToken,
          leaseUntil: now.addingTimeInterval(80), at: now.addingTimeInterval(8)
        )
      }
      await #expect(throws: OperationsStoreError.leaseConflict) {
        try await store.releaseRoleLease(
          role: first.role, ownerID: first.ownerID, fencingToken: first.fencingToken,
          at: now.addingTimeInterval(8)
        )
      }
    }
  }

  @Test("expired leases are taken over at the expiry boundary")
  func expiredTakeover() async throws {
    try await withStore { store in
      let first = try #require(await store.acquireRoleLease(
        role: "ttl-cleanup", ownerID: "replica-a",
        leaseUntil: now.addingTimeInterval(10), at: now
      ))
      let successor = try #require(await store.acquireRoleLease(
        role: first.role, ownerID: "replica-b",
        leaseUntil: now.addingTimeInterval(40), at: now.addingTimeInterval(10)
      ))

      #expect(successor.ownerID == "replica-b")
      #expect(successor.fencingToken == first.fencingToken + 1)
      #expect(successor.acquiredAt == now.addingTimeInterval(10))
      await #expect(throws: OperationsStoreError.leaseConflict) {
        _ = try await store.renewRoleLease(
          role: first.role, ownerID: first.ownerID, fencingToken: first.fencingToken,
          leaseUntil: now.addingTimeInterval(50), at: now.addingTimeInterval(11)
        )
      }
    }
  }

  @Test("the same role is isolated by environment")
  func environmentIsolation() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-role-lease-environments-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let logger = Logger(label: "operations.role-lease.test")
    let development = try SQLiteOperationsStore(
      path: url.path, environment: "development", logger: logger
    )
    let production = try SQLiteOperationsStore(
      path: url.path, environment: "production", logger: logger
    )

    let developmentLease = try #require(await development.acquireRoleLease(
      role: "wire-rank", ownerID: "dev-replica",
      leaseUntil: now.addingTimeInterval(30), at: now
    ))
    let productionLease = try #require(await production.acquireRoleLease(
      role: "wire-rank", ownerID: "prod-replica",
      leaseUntil: now.addingTimeInterval(30), at: now
    ))

    #expect(developmentLease.environment == "development")
    #expect(productionLease.environment == "production")
    #expect(developmentLease.fencingToken == 1)
    #expect(productionLease.fencingToken == 1)
  }

  @Test("fenced work excludes takeover until the operation returns")
  func fencedOperation() async throws {
    try await withStore { store in
      let first = try #require(await store.acquireRoleLease(
        role: "wire-rank", ownerID: "replica-a",
        leaseUntil: now.addingTimeInterval(10), at: now
      ))
      try await store.withRoleLeaseFence(
        role: first.role, ownerID: first.ownerID, fencingToken: first.fencingToken,
        at: now.addingTimeInterval(5)
      ) {
        let sameOwnerBlocked = try await store.acquireRoleLease(
          role: first.role, ownerID: first.ownerID,
          leaseUntil: now.addingTimeInterval(40), at: now.addingTimeInterval(20)
        )
        let blocked = try await store.acquireRoleLease(
          role: first.role, ownerID: "replica-b",
          leaseUntil: now.addingTimeInterval(40), at: now.addingTimeInterval(20)
        )
        #expect(sameOwnerBlocked == nil)
        #expect(blocked == nil)
      }
      let successor = try #require(await store.acquireRoleLease(
        role: first.role, ownerID: "replica-b",
        leaseUntil: now.addingTimeInterval(40), at: now.addingTimeInterval(20)
      ))
      #expect(successor.fencingToken == first.fencingToken + 1)
    }
  }

  @Test("non-positive lease durations fail before touching storage")
  func invalidLeaseDuration() async throws {
    try await withStore { store in
      await #expect(throws: OperationsStoreError.invalidProgress) {
        _ = try await store.acquireRoleLease(
          role: "wire-rank", ownerID: "replica-a", leaseUntil: now, at: now
        )
      }
      await #expect(throws: OperationsStoreError.invalidProgress) {
        _ = try await store.acquireRoleLease(
          role: "", ownerID: "replica-a",
          leaseUntil: now.addingTimeInterval(30), at: now
        )
      }
      await #expect(throws: OperationsStoreError.invalidProgress) {
        _ = try await store.acquireRoleLease(
          role: "wire-rank", ownerID: "",
          leaseUntil: now.addingTimeInterval(30), at: now
        )
      }
    }
  }

  private func withStore(
    _ operation: (SQLiteOperationsStore) async throws -> Void
  ) async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("operations-role-lease-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = try SQLiteOperationsStore(
      path: url.path,
      environment: "dev",
      logger: Logger(label: "operations.role-lease.test")
    )
    try await operation(store)
  }
}
