import Foundation
import Logging
import PostgresNIO
import Testing
@testable import OperationsCore

extension PostgresRoleLeaseAuthorityTests {
  private var concurrencyLogger: Logger { Logger(label: "role-fence-concurrency.tests") }

  @Test("a held publication fence permits renewal and another publication fence")
  func compatibleOwnerOperations() async throws {
    try await withLease { pool, store, lease in
      try await pool.withTransaction(logger: concurrencyLogger) { connection in
        try await fence(lease, connection: connection)
        let now = Date()
        let renewed = try await store.renewRoleLease(
          role: lease.role, ownerID: lease.ownerID, fencingToken: lease.fencingToken,
          leaseUntil: now.addingTimeInterval(30), at: now)
        #expect(renewed.fencingToken == lease.fencingToken)
        #expect(renewed.expiresAt >= lease.expiresAt)
        try await pool.withTransaction(logger: concurrencyLogger) { second in
          try await fence(lease, connection: second)
        }
      }
    }
  }

  @Test("an uncommitted renewal permits publication under the previous confirmed expiry")
  func publicationDuringRenewal() async throws {
    try await withLease { pool, _, lease in
      try await pool.withTransaction(logger: concurrencyLogger) { connection in
        try await PostgresRoleLeaseFence.lockForRenewalAndValidate(
          authority(lease), connection: connection, logger: concurrencyLogger)
        _ = try await PostgresRoleLeaseBudget.query(
          "UPDATE operations_role_leases SET lease_expires_at = clock_timestamp() + INTERVAL '60 seconds', updated_at = clock_timestamp() WHERE environment = \(lease.environment) AND role = \(lease.role)",
          connection: connection, logger: concurrencyLogger)
        try await pool.withTransaction(logger: concurrencyLogger) { publisher in
          try await fence(lease, connection: publisher)
          let rows = try await PostgresRoleLeaseBudget.query(
            "SELECT lease_expires_at FROM operations_role_leases WHERE environment = \(lease.environment) AND role = \(lease.role)",
            connection: publisher, logger: concurrencyLogger)
          for row in rows {
            #expect(try row.decode(Date.self) == lease.expiresAt)
          }
        }
      }
    }
  }

  @Test("release waits for publication, including a legacy direct release", arguments: [false, true])
  func releaseCannotCrossPublication(legacy: Bool) async throws {
    try await withLease { pool, store, lease in
      try await pool.withTransaction(logger: concurrencyLogger) { connection in
        try await fence(lease, connection: connection)
        do {
          if legacy {
            try await PostgresRoleLeaseBudget.withTransaction(pool: pool, logger: concurrencyLogger) { writer in
              _ = try await PostgresRoleLeaseBudget.query(
                "UPDATE operations_role_leases SET released_at = clock_timestamp() WHERE environment = \(lease.environment) AND role = \(lease.role)",
                connection: writer, logger: concurrencyLogger)
            }
          } else {
            try await store.releaseRoleLease(
              role: lease.role, ownerID: lease.ownerID, fencingToken: lease.fencingToken, at: Date())
          }
          Issue.record("Release crossed an active publication fence")
        } catch { #expect(RoleLeaseFailure.classify(error) == .lockTimeout) }
        // A failed release must leave this transaction's authority intact.
        try await fence(lease, connection: connection)
      }
      try await store.releaseRoleLease(
        role: lease.role, ownerID: lease.ownerID, fencingToken: lease.fencingToken, at: Date())
      try await expectRejectedFence(lease, pool: pool)
    }
  }

  @Test("legacy ownership updates cannot cross a publication fence")
  func legacyTakeoverCannotCrossPublication() async throws {
    try await withLease { pool, _, lease in
      try await pool.withTransaction(logger: concurrencyLogger) { connection in
        try await fence(lease, connection: connection)
        do {
          try await PostgresRoleLeaseBudget.withTransaction(pool: pool, logger: concurrencyLogger) { writer in
            _ = try await PostgresRoleLeaseBudget.query(
              "UPDATE operations_role_leases SET owner_id = 'successor', fencing_token = fencing_token + 1 WHERE environment = \(lease.environment) AND role = \(lease.role)",
              connection: writer, logger: concurrencyLogger)
          }
          Issue.record("Legacy ownership change crossed publication")
        } catch { #expect(RoleLeaseFailure.classify(error) == .lockTimeout) }
        try await fence(lease, connection: connection)
      }
    }
  }

  @Test("takeover skips a fenced expired lease and rejects the stale owner after publication")
  func expiryAndTakeover() async throws {
    try await withLease { pool, store, lease in
      let now = Date()
      try await pool.withTransaction(logger: concurrencyLogger) { connection in
        try await fence(lease, connection: connection)
        // Expiry fields are not ownership keys. Simulate clock expiry without
        // upgrading the publication transaction's KEY SHARE lock.
        try await expire(lease, pool: pool)
        let blocked = try await store.acquireRoleLease(
          role: lease.role, ownerID: "successor", leaseUntil: now.addingTimeInterval(30), at: now)
        #expect(blocked == nil)
      }
      let successor = try #require(try await store.acquireRoleLease(
        role: lease.role, ownerID: "successor", leaseUntil: now.addingTimeInterval(30), at: now))
      #expect(successor.fencingToken == lease.fencingToken + 1)
      try await expectRejectedFence(lease, pool: pool)
      do {
        _ = try await store.renewRoleLease(
          role: lease.role, ownerID: lease.ownerID, fencingToken: lease.fencingToken,
          leaseUntil: now.addingTimeInterval(30), at: now)
        Issue.record("The stale owner renewed after takeover")
      } catch { #expect(RoleLeaseFailure.classify(error) == .leaseConflict) }
      try await pool.withTransaction(logger: concurrencyLogger) { connection in
        try await fence(successor, connection: connection)
      }
    }
  }

  @Test("renewal checks database expiry after obtaining its serialization lock")
  func renewalExpiryAfterLock() async throws {
    try await withLease { pool, _, lease in
      let marker = "renewal-wait-\(UUID().uuidString)"
      let attempt = try await pool.withTransaction(logger: concurrencyLogger) { blocker in
        _ = try await PostgresRoleLeaseBudget.query(
          "SELECT fencing_token FROM operations_role_leases WHERE environment = \(lease.environment) FOR UPDATE",
          connection: blocker, logger: concurrencyLogger)
        let renewal = Task {
          try await pool.withTransaction(logger: concurrencyLogger) { connection in
            _ = try await PostgresRoleLeaseBudget.query(
              "SELECT set_config('application_name', \(marker), true)", connection: connection, logger: concurrencyLogger)
            try await PostgresRoleLeaseFence.lockForRenewalAndValidate(
              authority(lease), connection: connection, logger: concurrencyLogger)
          }
        }
        do {
          // Observe an actual database lock wait; never rely on a guessed sleep
          // to place the request before expiry. The poll has a fixed deadline.
          try await waitForLock(marker: marker, pool: pool)
          _ = try await PostgresRoleLeaseBudget.query(
            "UPDATE operations_role_leases SET acquired_at = clock_timestamp() - INTERVAL '2 seconds', lease_expires_at = clock_timestamp() - INTERVAL '1 second' WHERE environment = \(lease.environment)",
            connection: blocker, logger: concurrencyLogger)
          return renewal
        } catch {
          renewal.cancel()
          _ = await renewal.result
          throw error
        }
      }
      do {
        try await attempt.value
        Issue.record("Renewal used authority sampled before the lock wait")
      } catch { #expect(RoleLeaseFailure.classify(error) == .leaseConflict) }
    }
  }

  @Test("a failed fence rolls back prepared writes without disturbing the successor")
  func stalePublicationRollsBack() async throws {
    try await withLease { pool, store, lease in
      try await expire(lease, pool: pool)
      let now = Date()
      let successor = try #require(try await store.acquireRoleLease(
        role: lease.role, ownerID: "successor", leaseUntil: now.addingTimeInterval(30), at: now))
      do {
        try await pool.withTransaction(logger: concurrencyLogger) { connection in
          // A separate role is a durable test marker for work prepared before
          // the publication boundary; it must disappear on fencing failure.
          _ = try await PostgresRoleLeaseBudget.query(
            """
            INSERT INTO operations_role_leases
              (environment, role, owner_id, fencing_token, acquired_at, lease_expires_at, updated_at)
            VALUES (\(lease.environment), 'prepared', 'test', 1, clock_timestamp(),
              clock_timestamp() + INTERVAL '30 seconds', clock_timestamp())
            """, connection: connection, logger: concurrencyLogger)
          try await fence(lease, connection: connection)
          Issue.record("Stale owner entered publication")
        }
      } catch { #expect(RoleLeaseFailure.classify(error) == .leaseConflict) }
      let rows = try await pool.query(
        "SELECT COUNT(*) FROM operations_role_leases WHERE environment = \(lease.environment) AND role = 'prepared'", logger: concurrencyLogger)
      for try await row in rows { #expect(try row.decode(Int64.self) == 0) }
      try await pool.withTransaction(logger: concurrencyLogger) { connection in
        try await fence(successor, connection: connection)
      }
    }
  }

  private func authority(_ lease: FencedRoleLease) -> RoleLeaseAuthority {
    RoleLeaseAuthority(environment: lease.environment, role: lease.role,
      ownerID: lease.ownerID, fencingToken: lease.fencingToken)
  }

  private func fence(_ lease: FencedRoleLease, connection: PostgresConnection) async throws {
    try await PostgresRoleLeaseFence.lockAndValidate(authority(lease), connection: connection, logger: concurrencyLogger)
  }

  private func expectRejectedFence(_ lease: FencedRoleLease, pool: PostgresClient) async throws {
    do {
      try await pool.withTransaction(logger: concurrencyLogger) { connection in
        try await fence(lease, connection: connection)
      }
      Issue.record("A stale or released owner retained publication authority")
    } catch { #expect(RoleLeaseFailure.classify(error) == .leaseConflict) }
  }

  private func expire(_ lease: FencedRoleLease, pool: PostgresClient) async throws {
    try await pool.query(
      "UPDATE operations_role_leases SET acquired_at = clock_timestamp() - INTERVAL '2 seconds', lease_expires_at = clock_timestamp() - INTERVAL '1 second' WHERE environment = \(lease.environment)", logger: concurrencyLogger)
  }

  private func waitForLock(marker: String, pool: PostgresClient) async throws {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(400))
    while ContinuousClock.now < deadline {
      let rows = try await pool.query(
        "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = \(marker) AND cardinality(pg_blocking_pids(pid)) > 0)", logger: concurrencyLogger)
      for try await row in rows { if try row.decode(Bool.self) { return } }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw LockObservationFailure.notObserved
  }

  private func withLease(
    _ body: @Sendable (PostgresClient, PostgresOperationsStore, FencedRoleLease) async throws -> Void
  ) async throws {
    let raw = try #require(ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"])
    let url = try #require(URL(string: raw))
    var config = PostgresClient.Configuration(host: try #require(url.host), port: url.port ?? 5432,
      username: try #require(url.user), password: url.password,
      database: String(url.path.dropFirst()), tls: .disable)
    config.options.maximumConnections = 4
    let pool = PostgresClient(configuration: config, backgroundLogger: concurrencyLogger)
    let running = Task { await pool.run() }
    defer { running.cancel() }
    let environment = "fence-\(UUID().uuidString.prefix(20))"
    let store = PostgresOperationsStore(pool: pool, environment: environment, logger: concurrencyLogger)
    let now = Date()
    let lease = try #require(try await store.acquireRoleLease(
      role: "wire", ownerID: "owner", leaseUntil: now.addingTimeInterval(30), at: now))
    do {
      try await body(pool, store, lease)
    } catch {
      _ = try? await pool.query("DELETE FROM operations_role_leases WHERE environment = \(environment)", logger: concurrencyLogger)
      throw error
    }
    try await pool.query("DELETE FROM operations_role_leases WHERE environment = \(environment)", logger: concurrencyLogger)
  }
}

private enum LockObservationFailure: Error {
  case notObserved
}
