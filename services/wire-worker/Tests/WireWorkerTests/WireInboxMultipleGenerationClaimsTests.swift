import Foundation
import Logging
import PostgresNIO
import Testing
import WireCore

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("repository seeks preserve multiple source generations and cursor boundaries")
  func multipleGenerationRepositoryClaims() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-multiple-generation.integration")
    let pool = PostgresClient(
      configuration: try PostgresWireConfig.make(from: url, maximumConnections: 4, logger: logger),
      backgroundLogger: logger)
    let task = Task { await pool.run() }
    defer { task.cancel() }
    let environment = "wire-multi-\(UUID().uuidString.lowercased())"
    let now = Date()
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind,
         repo_did, payload, event_time, next_attempt_at)
      SELECT \(environment), generation, seq, 'test', 'jetstream_v2_seq', 'identity',
        'did:example:repo-' || ((seq - 1) / 1000)::text, '{}'::jsonb, \(now), \(now)
      FROM unnest(ARRAY['a', 'b', 'excluded']) generation CROSS JOIN generate_series(1, 2000) seq
      """, logger: logger)
    do {
      let processor = try PostgresWireInboxProcessor(
        pool: pool, logger: logger, actorSecret: String(repeating: "s", count: 32),
        sourceScope: WireInboxSourceScope(environment: environment, sourceGenerations: ["a", "b"]))
      let after = WireInboxRepository(environment: environment, sourceGeneration: "a", repoDID: "did:example:repo-0")
      let batch = try await processor.claimWork(asOf: now, limit: 8, afterRepository: after)
      #expect(batch.events.map { "\($0.sourceGeneration):\($0.sequence)" } == ["a:1001", "b:1", "b:1001"])
      for event in batch.events { #expect(try await processor.applyClaimed(event, asOf: now) == .applied) }
      let wrapped = try await processor.claimWork(asOf: now, limit: 1,
        afterRepository: .init(environment: environment, sourceGeneration: "z", repoDID: "last"))
      #expect(wrapped.events.first?.sourceGeneration == "a")
      #expect(wrapped.events.first?.sequence == 1)
      let rows = try await pool.query(
        "SELECT count(*) FROM wire_ingestion_inbox WHERE environment = \(environment) AND source_generation = 'excluded' AND status <> 'pending'",
        logger: logger)
      for try await row in rows { #expect(try row.decode(Int64.self) == 0) }
    } catch {
      _ = try? await pool.query("DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)", logger: logger)
      throw error
    }
    try await pool.query("DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)", logger: logger)
  }
}
