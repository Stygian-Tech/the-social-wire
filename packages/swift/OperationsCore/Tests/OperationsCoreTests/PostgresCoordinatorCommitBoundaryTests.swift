import Foundation
import Logging
import PostgresNIO
import Testing
@testable import OperationsCore

@Suite("Coordinator final commit fence", .enabled(
  if: ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"] != nil))
struct PostgresCoordinatorCommitBoundaryTests {
  private let logger = Logger(label: "coordinator-commit.tests")

  @Test("prepared recovery writes do not block role renewal")
  func renewalDuringPreparation() async throws {
    try await withFixture { pool, control, worker, grant, jobID in
      try await worker.withCoordinatorTransaction { connection in
        let rows = try await connection.query(
          "UPDATE appview_backfill_jobs SET processed_count = 1 WHERE environment = 'dev' AND id = \(jobID) RETURNING id",
          logger: logger)
        for try await _ in rows {}
        // This call must finish while the recovery transaction remains open.
        // An early role fence instead makes it fail with the 500 ms lock timeout.
        let now = Date()
        let renewed = try await control.renewRoleLease(
          role: grant.role, ownerID: grant.ownerID, fencingToken: grant.fencingToken,
          leaseUntil: now.addingTimeInterval(30), at: now)
        #expect(renewed.fencingToken == grant.fencingToken)
        let pending = try await pool.query(
          "SELECT processed_count FROM appview_backfill_jobs WHERE environment = 'dev' AND id = \(jobID)", logger: logger)
        for try await row in pending { #expect(try row.decode(Int.self) == 0) }
      }
      let committed = try #require(try await control.fetchBackfill(id: jobID))
      #expect(committed.processedCount == 1)
    }
  }

  @Test("takeover during preparation rolls back recovery writes")
  func stalePreparedMutationRollsBack() async throws {
    try await withFixture { _, control, worker, grant, jobID in
      let original = try #require(try await control.fetchBackfill(id: jobID))
      do {
        try await worker.withCoordinatorTransaction { connection in
          let rows = try await connection.query(
            "UPDATE appview_backfill_jobs SET processed_count = 1, version = version + 1 WHERE environment = 'dev' AND id = \(jobID) RETURNING id",
            logger: logger)
          for try await _ in rows {}
          try await replaceOwner(control, grant: grant)
        }
        Issue.record("A stale prepared mutation must not commit")
      } catch {
        #expect(RoleLeaseFailure.classify(error) == .leaseConflict)
      }
      let unchanged = try #require(try await control.fetchBackfill(id: jobID))
      #expect(unchanged.processedCount == 0)
      #expect(unchanged.version == original.version)
    }
  }

  @Test("empty and replay results still require final authority", arguments: [false, true])
  func earlyResultsAreFenced(replay: Bool) async throws {
    try await withFixture { _, control, worker, grant, _ in
      do {
        let _: String? = try await worker.withCoordinatorTransaction { _ in
          try await replaceOwner(control, grant: grant)
          return replay ? "previous-result" : nil
        }
        Issue.record("A successful early result must still validate authority")
      } catch {
        #expect(RoleLeaseFailure.classify(error) == .leaseConflict)
      }
    }
  }

  private func replaceOwner(_ control: PostgresOperationsStore, grant: FencedRoleLease) async throws {
    let now = Date()
    try await control.releaseRoleLease(
      role: grant.role, ownerID: grant.ownerID, fencingToken: grant.fencingToken, at: now)
    let successor = try #require(try await control.acquireRoleLease(
      role: grant.role, ownerID: "successor", leaseUntil: now.addingTimeInterval(30), at: now))
    #expect(successor.fencingToken > grant.fencingToken)
  }

  private func withFixture(
    _ body: (PostgresClient, PostgresOperationsStore, PostgresOperationsStore, FencedRoleLease, String) async throws -> Void
  ) async throws {
    let raw = try #require(ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"])
    let url = try #require(URL(string: raw))
    var config = PostgresClient.Configuration(
      host: try #require(url.host), port: url.port ?? 5432,
      username: try #require(url.user), password: url.password,
      database: String(url.path.dropFirst()), tls: .disable)
    config.options.maximumConnections = 4
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let running = Task { await pool.run() }
    defer { running.cancel() }
    let control = PostgresOperationsStore(pool: pool, environment: "dev", logger: logger)
    let now = Date()
    let grant = try #require(try await control.acquireRoleLease(
      role: "commit-\(UUID().uuidString)", ownerID: "original", leaseUntil: now.addingTimeInterval(30), at: now))
    let worker = PostgresOperationsStore(
      pool: pool, environment: "dev",
      coordinatorAuthority: RoleLeaseAuthority(
        environment: "dev", role: grant.role, ownerID: grant.ownerID, fencingToken: grant.fencingToken),
      logger: logger)
    let jobID = UUID().uuidString
    try await pool.query(
      """
      INSERT INTO appview_backfill_jobs
        (environment, id, source_mode, status, batch_size, rate_limit, max_concurrency,
         requested_by_did, audit_note, created_at, updated_at)
      VALUES ('dev', \(jobID), 'pds_reconciliation', 'completed', 100, 10, 1,
        'did:example:test', 'commit boundary fixture', \(now), \(now))
      """, logger: logger)
    do {
      try await body(pool, control, worker, grant, jobID)
    } catch {
      _ = try? await pool.query("DELETE FROM appview_backfill_jobs WHERE environment = 'dev' AND id = \(jobID)", logger: logger)
      throw error
    }
    try await pool.query("DELETE FROM appview_backfill_jobs WHERE environment = 'dev' AND id = \(jobID)", logger: logger)
  }
}
