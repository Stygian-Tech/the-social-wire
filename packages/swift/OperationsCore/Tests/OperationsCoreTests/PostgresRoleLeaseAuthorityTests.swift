import Foundation
import Logging
import PostgresNIO
import Testing
@testable import OperationsCore

@Suite("Postgres lease authority and budgets", .enabled(
  if: ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"] != nil))
struct PostgresRoleLeaseAuthorityTests {
  private let logger = Logger(label: "role-authority.tests")

  @Test("skewed process clocks cannot create or revive a lease")
  func databaseClock() async throws {
    try await withPool { pool, store in
      let skewed = Date(timeIntervalSince1970: 1)
      let before = Date()
      let first = try #require(try await store.acquireRoleLease(
        role: "wire", ownerID: "one", leaseUntil: skewed.addingTimeInterval(30), at: skewed))
      #expect(abs(first.updatedAt.timeIntervalSince(before)) < 3)
      #expect(abs(first.expiresAt.timeIntervalSince(first.updatedAt) - 30) < 0.001)
      let future = Date().addingTimeInterval(1_000_000)
      let renewed = try await store.renewRoleLease(role: "wire", ownerID: "one", fencingToken: first.fencingToken,
        leaseUntil: future.addingTimeInterval(30), at: future)
      #expect(abs(renewed.updatedAt.timeIntervalSince(Date())) < 3)
      try await pool.query("UPDATE operations_role_leases SET acquired_at = clock_timestamp() - INTERVAL '2 seconds', lease_expires_at = clock_timestamp() - INTERVAL '1 second' WHERE environment = \(first.environment)", logger: logger)
      do {
        _ = try await store.renewRoleLease(role: "wire", ownerID: "one", fencingToken: first.fencingToken,
          leaseUntil: skewed.addingTimeInterval(30), at: skewed)
        Issue.record("Expired authority must not renew with a stale client clock")
      } catch { #expect(RoleLeaseFailure.classify(error) == .leaseConflict) }
      let successor = try #require(try await store.acquireRoleLease(
        role: "wire", ownerID: "two", leaseUntil: skewed.addingTimeInterval(30), at: skewed))
      #expect(successor.fencingToken == first.fencingToken + 1)
    }
  }

  @Test("competing acquisitions have exactly one active owner")
  func acquireRace() async throws {
    try await withPool { _, store in
      let now = Date()
      async let first = store.acquireRoleLease(role: "wire", ownerID: "one", leaseUntil: now.addingTimeInterval(30), at: now)
      async let second = store.acquireRoleLease(role: "wire", ownerID: "two", leaseUntil: now.addingTimeInterval(30), at: now)
      let results = try await [first, second].compactMap { $0 }
      #expect(results.count == 1)
      #expect(results.first?.fencingToken == 1)
    }
  }

  @Test("expiry is checked after waiting for the publication row lock")
  func expiryAfterLock() async throws {
    try await withPool { pool, store in
      let now = Date()
      let lease = try #require(try await store.acquireRoleLease(role: "wire", ownerID: "one", leaseUntil: now.addingTimeInterval(30), at: now))
      let locked = LeaseDatabaseGate()
      let blocker = Task {
        try await pool.withConnection { connection in
          try await connection.withTransaction(logger: logger) { connection in
            try await connection.query("UPDATE operations_role_leases SET lease_expires_at = clock_timestamp() + INTERVAL '50 milliseconds' WHERE environment = \(lease.environment)", logger: logger)
            await locked.open()
            let rows = try await PostgresRoleLeaseBudget.query("SELECT pg_sleep(0.2)", connection: connection, logger: logger)
            for _ in rows {}
          }
        }
      }
      await locked.wait()
      do {
        try await store.withRoleLeaseFence(role: "wire", ownerID: "one", fencingToken: lease.fencingToken, at: now) {
          Issue.record("Expired owner entered a fenced operation")
        }
        Issue.record("Expected expired fence failure after waiting")
      } catch { #expect(RoleLeaseFailure.classify(error) == .leaseConflict) }
      try await blocker.value
    }
  }

  @Test("row contention fails at the lock budget and preserves later connectivity")
  func lockBudget() async throws {
    try await withPool { pool, store in
      let now = Date()
      let lease = try #require(try await store.acquireRoleLease(role: "wire", ownerID: "one", leaseUntil: now.addingTimeInterval(30), at: now))
      let locked = LeaseDatabaseGate()
      let release = LeaseDatabaseGate()
      let blocker = Task {
        try await pool.withConnection { connection in
          try await connection.withTransaction(logger: logger) { connection in
            let rows = try await PostgresRoleLeaseBudget.query("SELECT fencing_token FROM operations_role_leases WHERE environment = \(lease.environment) FOR UPDATE", connection: connection, logger: logger)
            for _ in rows {}
            await locked.open()
            await release.wait()
          }
        }
      }
      await locked.wait()
      let start = ContinuousClock.now
      do {
        _ = try await store.renewRoleLease(role: "wire", ownerID: "one", fencingToken: lease.fencingToken,
          leaseUntil: now.addingTimeInterval(30), at: now)
        Issue.record("Locked renewal must time out")
      } catch { #expect(RoleLeaseFailure.classify(error) == .lockTimeout) }
      let elapsed = start.duration(to: .now)
      #expect(elapsed >= .milliseconds(400) && elapsed < .seconds(3))
      await release.open()
      try await blocker.value
      try await store.ping()
    }
  }

  @Test("statement budget cancels executing SQL and transaction settings do not leak")
  func statementBudget() async throws {
    try await withPool(maximumConnections: 1) { pool, store in
      let start = ContinuousClock.now
      do {
        try await PostgresRoleLeaseBudget.withTransaction(pool: pool, logger: logger) { connection in
          let rows = try await PostgresRoleLeaseBudget.query("SELECT pg_sleep(20)", connection: connection, logger: logger)
          for _ in rows {}
        }
        Issue.record("Slow control SQL must time out")
      } catch { #expect(RoleLeaseFailure.classify(error) == .statementCancelled) }
      #expect(start.duration(to: .now) < .seconds(3))
      try await store.ping()
      let rows = try await pool.query("SHOW statement_timeout", logger: logger)
      for try await row in rows { #expect(try row.decode(String.self) == "0") }
    }
  }

  @Test("cancellation retires an executing control connection without blocking its replacement")
  func cancellationBudget() async throws {
    try await withPool(maximumConnections: 1) { pool, store in
      let entered = LeaseDatabaseGate()
      let task = Task {
        try await PostgresRoleLeaseBudget.withTransaction(pool: pool, logger: logger) { connection in
          await entered.open()
          let rows = try await PostgresRoleLeaseBudget.query("SELECT pg_sleep(20)", connection: connection, logger: logger)
          for _ in rows {}
        }
      }
      await entered.wait()
      let start = ContinuousClock.now
      task.cancel()
      do { try await task.value; Issue.record("Cancelled query unexpectedly succeeded") } catch {}
      #expect(start.duration(to: .now) < .seconds(1))
      try await store.ping()
    }
  }

  @Test("total operation budget includes a saturated connection pool")
  func poolBudget() async throws {
    try await withPool(maximumConnections: 1) { pool, store in
      let held = LeaseDatabaseGate()
      let release = LeaseDatabaseGate()
      let holder = Task {
        try await pool.withConnection { _ in await held.open(); await release.wait() }
      }
      await held.wait()
      let start = ContinuousClock.now
      do {
        let now = Date()
        _ = try await store.acquireRoleLease(role: "wire", ownerID: "one", leaseUntil: now.addingTimeInterval(30), at: now)
        Issue.record("Pool wait must time out")
      } catch { #expect(RoleLeaseFailure.classify(error) == .operationTimedOut) }
      #expect(start.duration(to: .now) < .seconds(4))
      await release.open()
      try await holder.value
      try await store.ping()
    }
  }

  @Test("an executor-delayed operation cannot commit after its deadline", arguments: [false, true])
  func absoluteCommitDeadline(expired: Bool) async throws {
    try await withPool { pool, _ in
      let clock = LeaseOperationTestClock()
      let deadline = RoleLeaseOperationDeadline(startedAt: clock.now, now: { clock.now })
      let environment = "deadline-\(UUID().uuidString.prefix(12))"
      do {
        try await PostgresRoleLeaseBudget.withTransaction(pool: pool, logger: logger, deadline: deadline) { connection in
          _ = try await PostgresRoleLeaseBudget.query(
            """
            INSERT INTO operations_role_leases
              (environment, role, owner_id, fencing_token, acquired_at, lease_expires_at, updated_at)
            VALUES (\(environment), 'deadline', 'owner', 1, clock_timestamp(),
              clock_timestamp() + INTERVAL '30 seconds', clock_timestamp())
            """, connection: connection, logger: logger)
          // Advance authority time, not wall time: the timer task has not fired.
          clock.advance(expired ? .seconds(3) : .seconds(2))
        }
        #expect(!expired)
      } catch {
        #expect(expired)
        #expect(RoleLeaseFailure.classify(error) == .operationTimedOut)
      }
      let rows = try await pool.query(
        "SELECT COUNT(*) FROM operations_role_leases WHERE environment = \(environment)", logger: logger)
      for try await row in rows { #expect(try row.decode(Int64.self) == (expired ? 0 : 1)) }
    }
  }

  @Test("a control attempt already out of time cannot acquire a pool connection")
  func expiredAdmission() async throws {
    try await withPool(maximumConnections: 1) { pool, _ in
      let clock = LeaseOperationTestClock()
      let deadline = RoleLeaseOperationDeadline(startedAt: clock.now, now: { clock.now })
      clock.advance(.seconds(3))
      _ = try await pool.withConnection { _ in
        await #expect(throws: RoleLeaseFailure.operationTimedOut) {
          try await PostgresRoleLeaseBudget.withTransaction(pool: pool, logger: logger, deadline: deadline) { _ in
            Issue.record("Expired attempt must not enter transaction body")
          }
        }
      }
    }
  }

  private func withPool(
    maximumConnections: Int = 4,
    _ body: @Sendable (PostgresClient, PostgresOperationsStore) async throws -> Void
  ) async throws {
    let raw = try #require(ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"])
    let url = try #require(URL(string: raw))
    var config = PostgresClient.Configuration(host: try #require(url.host), port: url.port ?? 5432,
      username: try #require(url.user), password: url.password,
      database: String(url.path.dropFirst()), tls: .disable)
    config.options.maximumConnections = maximumConnections
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let running = Task { await pool.run() }
    defer { running.cancel() }
    let store = PostgresOperationsStore(pool: pool, environment: "lease-\(UUID().uuidString.prefix(20))", logger: logger)
    try await body(pool, store)
  }
}

private actor LeaseDatabaseGate {
  private var opened = false
  private var continuations: [CheckedContinuation<Void, Never>] = []
  func wait() async { if !opened { await withCheckedContinuation { continuations.append($0) } } }
  func open() { opened = true; let pending = continuations; continuations = []; pending.forEach { $0.resume() } }
}
