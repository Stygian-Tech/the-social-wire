import Foundation
import Logging
import PostgresNIO
import Testing
import WireCore

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test(
    "deep repository queues skip locked heads without bypassing FIFO",
    arguments: [false, true], [false, true]
  )
  func deepRepositoryHeads(scoped: Bool, repositoryAdmission: Bool) async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-deep-repository.integration")
    let configuration = try PostgresWireConfig.make(from: url, maximumConnections: 8, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let environment = "wire-deep-\(UUID().uuidString.lowercased())"
    let generation = "live"
    let now = Date()
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind,
         repo_did, payload, event_time, next_attempt_at)
      SELECT \(environment), \(generation), sequence, 'test', 'jetstream_v2_seq', 'identity',
             'did:example:deep-' || ((sequence - 1) / 30000)::text, '{}'::jsonb, \(now),
             \(now.addingTimeInterval(-1))
      FROM generate_series(1, 120000) sequence
      """, logger: logger)
    try await pool.query(
      """
      UPDATE wire_ingestion_inbox SET status = 'retry', next_attempt_at = \(now.addingTimeInterval(60))
      WHERE environment = \(environment) AND seq = 30001
      """, logger: logger)
    try await pool.query(
      """
      UPDATE wire_ingestion_inbox
      SET status = 'leased', lease_owner = 'previous-worker', lease_token = 'expired-token',
          lease_expires_at = \(now.addingTimeInterval(-1))
      WHERE environment = \(environment) AND seq = 60001
      """, logger: logger)
    try await pool.query(
      """
      UPDATE wire_ingestion_inbox SET status = 'applied', applied_at = \(now)
      WHERE environment = \(environment) AND seq = 90001
      """, logger: logger)
    let processor = try PostgresWireInboxProcessor(
      pool: pool, logger: logger, actorSecret: String(repeating: "s", count: 32),
      batchSize: 16, maximumConcurrentEvents: 8,
      sourceScope: scoped
        ? WireInboxSourceScope(environment: environment, sourceGenerations: [generation]) : nil)

    if repositoryAdmission {
      try await pool.query("VACUUM ANALYZE wire_ingestion_inbox", logger: logger)
      enum PlanRollback: Error { case complete }
      let cursors: [WireInboxRepository?] = [nil, .init(
        environment: environment, sourceGeneration: generation, repoDID: "did:example:deep-1")]
      for cursor in cursors {
        do {
          try await pool.withTransaction(logger: logger) { connection in
            // Exercise the reusable-plan setting used after statements warm up.
            try await connection.query("SET LOCAL plan_cache_mode = force_generic_plan", logger: logger)
            let query = processor.repositoryHeadsQuery(asOf: now, limit: 8, after: cursor)
            let rows = try await connection.query(
              PostgresQuery(unsafeSQL: "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + query.sql, binds: query.binds),
              logger: logger)
            for try await row in rows {
              let json = try row.decode(String.self)
              let plans = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
              let plan = try #require(plans.first?["Plan"] as? [String: Any])
              let hits = try #require(plan["Shared Hit Blocks"] as? Int)
              let reads = try #require(plan["Shared Read Blocks"] as? Int)
              // Admission must seek four repository heads, not walk 120k queued events.
              #expect(hits + reads < 5_000)
              #expect(!json.contains("Seq Scan"))
              print("Deep repository admission: \(hits + reads) shared blocks")
            }
            throw PlanRollback.complete
          }
        } catch let error as PostgresTransactionError {
          guard error.closureError is PlanRollback, error.rollbackError == nil else { throw error }
        }
      }
    }

    // Exercise the continuously replenished runtime's admission path as well
    // as the older batch API against the same deep FIFO and lease barriers.
    func process(asOf: Date) async throws -> Int {
      guard repositoryAdmission else { return try await processor.process(asOf: asOf) }
      let batch = try await processor.claimWork(asOf: asOf, limit: 8)
      for event in batch.events {
        #expect(try await processor.applyClaimed(event, asOf: asOf) == .applied)
      }
      return batch.events.count + batch.appliedPassiveEventCount
    }

    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        """
        SELECT seq FROM wire_ingestion_inbox
        WHERE environment = \(environment) AND source_generation = \(generation) AND seq = 1
        FOR UPDATE
        """, logger: logger)
      #expect(try await process(asOf: now) == 2)
    }
    let rows = try await pool.query(
      """
      SELECT seq FROM wire_ingestion_inbox
      WHERE environment = \(environment) AND status = 'applied' ORDER BY seq
      """, logger: logger)
    var applied: [Int64] = []
    for try await row in rows { applied.append(try row.decode(Int64.self)) }
    #expect(applied == [60001, 90001, 90002])
    #expect(try await process(asOf: now.addingTimeInterval(120)) == 4)
    try await pool.query(
      "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)", logger: logger)
  }
}
