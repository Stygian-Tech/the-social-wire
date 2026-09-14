import Foundation
import Logging
import PostgresNIO
import Testing
@testable import OperationsCore

@Suite("Coordinator recovery commit authority", .enabled(
  if: ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"] != nil))
struct PostgresCoordinatorBackfillFenceTests {
  @Test("a replaced Coordinator cannot claim, renew, checkpoint, or complete recovery")
  func rejectsStaleRecoveryControl() async throws {
    let raw = try #require(ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"])
    let url = try #require(URL(string: raw))
    let logger = Logger(label: "coordinator-fence.tests")
    let config = PostgresClient.Configuration(
      host: try #require(url.host), port: url.port ?? 5432,
      username: try #require(url.user), password: url.password,
      database: String(url.path.dropFirst()), tls: .disable)
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let running = Task { await pool.run() }
    defer { running.cancel() }
    let environment = "dev"
    let role = "indexing.appview-coordinator-\(UUID().uuidString)"
    let now = Date()
    let control = PostgresOperationsStore(pool: pool, environment: environment, logger: logger)
    let grant = try #require(try await control.acquireRoleLease(
      role: role, ownerID: "old", leaseUntil: now.addingTimeInterval(30), at: now))
    let worker = PostgresOperationsStore(
      pool: pool, environment: environment,
      coordinatorAuthority: RoleLeaseAuthority(
        environment: environment, role: role, ownerID: "old", fencingToken: grant.fencingToken),
      logger: logger)
    let jobID = UUID().uuidString
    try await pool.query(
      """
      INSERT INTO appview_backfill_jobs
        (environment, id, source_mode, status, batch_size, rate_limit, max_concurrency,
         requested_by_did, audit_note, created_at, updated_at)
      VALUES (\(environment), \(jobID), 'pds_reconciliation', 'queued', 100, 10, 1,
        'did:example:test', 'fence integration fixture', \(now), \(now))
      """, logger: logger)
    let job = try #require(try await worker.claimNextBackfill(
      workerId: "worker", leaseUntil: now.addingTimeInterval(60), at: now))
    try await pool.query(
      "UPDATE operations_role_leases SET acquired_at = clock_timestamp() - INTERVAL '2 seconds', lease_expires_at = clock_timestamp() - INTERVAL '1 second' WHERE environment = \(environment) AND role = \(role)",
      logger: logger)
    _ = try await control.acquireRoleLease(
      role: role, ownerID: "new", leaseUntil: now.addingTimeInterval(30), at: now)
    await #expect(throws: (any Error).self) {
      _ = try await worker.claimNextBackfill(workerId: "worker", leaseUntil: now.addingTimeInterval(60), at: now)
    }
    await #expect(throws: (any Error).self) {
      _ = try await worker.renewBackfillLease(id: job.id, workerId: "worker",
        expectedVersion: job.version, leaseUntil: now.addingTimeInterval(60), at: now)
    }
    await #expect(throws: (any Error).self) {
      _ = try await worker.checkpointBackfill(id: job.id, workerId: "worker",
        expectedVersion: job.version, cursor: nil, processed: 1, failed: 0,
        reconciled: 0, leaseUntil: now.addingTimeInterval(60), at: now)
    }
    await #expect(throws: (any Error).self) {
      _ = try await worker.recordBackfillAuthorResults(id: job.id, workerId: "worker",
        expectedVersion: job.version, results: [], at: now)
    }
    await #expect(throws: (any Error).self) {
      _ = try await worker.transitionBackfill(id: job.id, to: .failed,
        expectedVersion: job.version, operatorDid: "system:worker",
        idempotencyKey: UUID().uuidString, note: nil, failureReason: "test", at: now)
    }
    let unchanged = try #require(try await control.fetchBackfill(id: job.id))
    #expect(unchanged.version == job.version)
    #expect(unchanged.status == .running && unchanged.processedCount == 0)
  }
}
