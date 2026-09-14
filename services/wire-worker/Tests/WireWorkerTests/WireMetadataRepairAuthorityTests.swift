import Foundation
import Logging
import OperationsCore
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("expired and replaced Coordinators cannot commit repaired rows or advance the sweep",
    arguments: [false, true])
  func metadataRepairRejectsStaleAuthority(withSuccessor: Bool) async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-metadata-repair-authority.tests")
    let pool = PostgresClient(
      configuration: try PostgresWireConfig.make(from: url, maximumConnections: 4, logger: logger),
      backgroundLogger: logger)
    let running = Task { await pool.run() }
    defer { running.cancel() }
    let suffix = UUID().uuidString.lowercased()
    let prefix = "!repair-authority-\(suffix)-"
    let environment = "repair-\(suffix.prefix(12))"
    let role = "indexing.wire-materializer"
    let now = Date()
    let control = PostgresOperationsStore(pool: pool, environment: environment, logger: logger)
    let grant = try #require(try await control.acquireRoleLease(
      role: role, ownerID: "old", leaseUntil: now.addingTimeInterval(30), at: now))
    let predecessor = PostgresWireLinkMetadataStore(pool: pool, logger: logger,
      roleLeaseAuthority: RoleLeaseAuthority(
        environment: environment, role: role, ownerID: "old", fencingToken: grant.fencingToken))
    try await pool.query(
      """
      INSERT INTO wire_items
        (canonical_key, canonical_url, source_domain, source_name, title, eligible,
         first_seen_at, last_seen_at, expires_at)
      SELECT \(prefix) || n, 'https://example.com/' || \(prefix) || n,
        'example.com', 'Example', 'Story', TRUE, \(now), \(now), \(now.addingTimeInterval(86_400))
      FROM generate_series(1, 3) n
      """, logger: logger)
    do {
      try await pool.query(
        "UPDATE wire_metadata_repair_cursor SET canonical_key = \(prefix) WHERE singleton", logger: logger)
      let first = try await predecessor.repairMetadataPage(asOf: now, pageSize: 1)
      #expect(first.scanned == 1 && first.repaired == 1)
      try await pool.query(
        """
        UPDATE operations_role_leases
        SET acquired_at = clock_timestamp() - INTERVAL '2 seconds',
            lease_expires_at = clock_timestamp() - INTERVAL '1 second'
        WHERE environment = \(environment) AND role = \(role)
        """, logger: logger)
      var committedPages: Int64 = 1
      if withSuccessor {
        let replacement = try #require(try await control.acquireRoleLease(
          role: role, ownerID: "new", leaseUntil: now.addingTimeInterval(30), at: now))
        let successor = PostgresWireLinkMetadataStore(pool: pool, logger: logger,
          roleLeaseAuthority: RoleLeaseAuthority(
            environment: environment, role: role, ownerID: "new", fencingToken: replacement.fencingToken))
        let next = try await successor.repairMetadataPage(asOf: now, pageSize: 1)
        #expect(next.scanned == 1 && next.repaired == 1)
        committedPages = 2
      }
      do {
        _ = try await predecessor.repairMetadataPage(asOf: now, pageSize: 1)
        Issue.record("Stale repair page must fail its commit fence")
      } catch let error as PostgresTransactionError {
        #expect(error.closureError as? OperationsStoreError == .leaseConflict)
        #expect(error.rollbackError == nil)
      }
      for try await row in try await pool.query(
        "SELECT canonical_key FROM wire_metadata_repair_cursor WHERE singleton", logger: logger) {
        #expect(try row.decode(String.self) == prefix + String(committedPages))
      }
      for try await row in try await pool.query(
        "SELECT COUNT(*) FROM wire_link_metadata_cache WHERE canonical_key LIKE \(prefix + "%")",
        logger: logger) {
        #expect(try row.decode(Int64.self) == committedPages)
      }
    } catch {
      try? await cleanupMetadataRepairAuthority(pool: pool, logger: logger, prefix: prefix, environment: environment)
      throw error
    }
    try await cleanupMetadataRepairAuthority(pool: pool, logger: logger, prefix: prefix, environment: environment)
  }

  private func cleanupMetadataRepairAuthority(
    pool: PostgresClient, logger: Logger, prefix: String, environment: String
  ) async throws {
    try await pool.query("DELETE FROM wire_items WHERE canonical_key LIKE \(prefix + "%")", logger: logger)
    try await pool.query("DELETE FROM wire_link_metadata_cache WHERE canonical_key LIKE \(prefix + "%")", logger: logger)
    try await pool.query("DELETE FROM operations_role_leases WHERE environment = \(environment)", logger: logger)
    try await pool.query("UPDATE wire_metadata_repair_cursor SET canonical_key = '' WHERE singleton", logger: logger)
  }
}
