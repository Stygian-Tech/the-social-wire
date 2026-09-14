import Foundation
import Logging
import PostgresNIO
import Testing

@testable import OperationsCore

@Suite("Operations inbox retention PostgreSQL", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"] != nil,
    "Requires an explicitly disposable migrated PostgreSQL database."))
struct PostgresInboxRetentionIntegrationTests {
  @Test("retention preserves recovery work and skips a locked terminal row without stalling the batch")
  func protectedWorkAndLockedTerminalRows() async throws {
    let url = try #require(URL(string: ProcessInfo.processInfo.environment["OPERATIONS_TEST_DATABASE_URL"] ?? ""))
    let logger = Logger(label: "operations-inbox-retention.tests")
    var config = PostgresClient.Configuration(
      host: try #require(url.host), port: url.port ?? 5432,
      username: try #require(url.user), password: url.password,
      database: String(url.path.dropFirst()), tls: .disable)
    config.options.maximumConnections = 3
    // A missing SKIP LOCKED must fail this test, never hang the runner indefinitely.
    config.options.additionalStartupParameters = [("statement_timeout", "3000")]
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let runner = Task { await pool.run() }
    defer { runner.cancel() }
    let store = PostgresOperationsStore(pool: pool, environment: "prod", logger: logger)
    let generation = "retention-test-\(UUID())"
    // Keep this test's clock before normal fixture data so the public cleanup method
    // does not expire unrelated current telemetry in the disposable database.
    let cutoff = Date(timeIntervalSince1970: 86_400)
    try await pool.query("""
      INSERT INTO appview_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind,
         repo_did, payload, event_time, status, lease_owner, lease_token, lease_expires_at,
         applied_at, dead_lettered_at, reconciled_at, expires_at,
         filtered_scope_policy, filtered_scope_at)
      SELECT CASE WHEN seq = 13 THEN 'dev' ELSE 'prod' END, \(generation), seq,
        'fixture', 'jetstream_v2_seq', 'commit', 'did:plc:retention', '{}', \(cutoff), status,
        CASE WHEN status = 'leased' THEN 'worker' END,
        CASE WHEN status = 'leased' THEN 'lease-token' END,
        CASE WHEN status = 'leased' THEN \(cutoff) + (CASE WHEN seq = 4 THEN 60 ELSE -60 END) * INTERVAL '1 second' END,
        CASE WHEN status = 'applied' THEN \(cutoff) END,
        CASE WHEN status = 'dead_letter' THEN \(cutoff) END,
        CASE WHEN seq = 9 THEN \(cutoff) END,
        CASE WHEN seq IN (1, 12) THEN NULL
          WHEN seq = 10 THEN \(cutoff) + INTERVAL '1 second' ELSE \(cutoff) END,
        CASE WHEN status = 'filtered_scope' THEN 'test-policy' END,
        CASE WHEN status = 'filtered_scope' THEN \(cutoff) END
      FROM (VALUES (1, 'pending'), (2, 'pending'), (3, 'retry'), (4, 'leased'),
        (5, 'leased'), (6, 'dead_letter'), (7, 'applied'), (8, 'filtered_scope'),
        (9, 'dead_letter'), (10, 'applied'), (11, 'applied'), (12, 'applied'),
        (13, 'applied')) fixture(seq, status)
      """, logger: logger)
    do {
      try await pool.withTransaction(logger: logger) { blocker in
        _ = try await blocker.query("""
          SELECT seq FROM appview_ingestion_inbox
          WHERE environment = 'prod' AND source_generation = \(generation) AND seq = 7
          FOR UPDATE
          """, logger: logger)
        #expect(try await store.cleanupExpired(at: cutoff, batchSize: 2) == 2)
        #expect(try await retained(pool, logger, generation) == [1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 13])
        #expect(try await store.cleanupExpired(at: cutoff, batchSize: 2) == 1)
        #expect(try await store.cleanupExpired(at: cutoff, batchSize: 2) == 0)
        // The locked row is still retained while later eligible rows were collected.
        #expect(try await retained(pool, logger, generation) == [1, 2, 3, 4, 5, 6, 7, 10, 12, 13])
      }
      #expect(try await store.cleanupExpired(at: cutoff, batchSize: 2) == 1)
      #expect(try await retained(pool, logger, generation) == [1, 2, 3, 4, 5, 6, 10, 12, 13])
      #expect(try await store.cleanupExpired(at: cutoff, batchSize: 2) == 0)
    } catch {
      _ = try? await pool.query("DELETE FROM appview_ingestion_inbox WHERE source_generation = \(generation)", logger: logger)
      throw error
    }
    try await pool.query("DELETE FROM appview_ingestion_inbox WHERE source_generation = \(generation)", logger: logger)
  }

  private func retained(_ pool: PostgresClient, _ logger: Logger, _ generation: String) async throws -> [Int64] {
    let rows = try await pool.query("""
      SELECT seq FROM appview_ingestion_inbox WHERE source_generation = \(generation) ORDER BY seq
      """, logger: logger)
    var result: [Int64] = []
    for try await row in rows { result.append(try row.decode(Int64.self)) }
    return result
  }
}
