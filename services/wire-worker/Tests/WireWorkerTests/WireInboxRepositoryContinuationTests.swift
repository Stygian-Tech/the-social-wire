import Foundation
import Logging
import PostgresNIO
import Testing
import WireCore

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test(
    "repository admission honors batch size and wraps its fairness cursor",
    arguments: [false, true]
  )
  func repositoryAdmissionBatchAndCursor(scoped: Bool) async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-repository-admission.integration")
    let configuration = try PostgresWireConfig.make(from: url, maximumConnections: 8, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }
    // Quotes ensure scope and cursor values remain SQL bindings in both paths.
    let environment = "wire-admission-'\(UUID().uuidString.lowercased())"
    let generation = "live'fixture"
    let now = Date()
    let processor = try PostgresWireInboxProcessor(
      pool: pool, logger: logger, actorSecret: String(repeating: "s", count: 32),
      batchSize: 1, maximumConcurrentEvents: 8,
      sourceScope: scoped
        ? WireInboxSourceScope(environment: environment, sourceGenerations: [generation]) : nil)
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind,
         repo_did, payload, event_time, next_attempt_at)
      SELECT \(environment), \(generation), sequence, 'test', 'jetstream_v2_seq', 'identity',
             repository, '{}'::jsonb, \(now), \(now)
      FROM (VALUES (1, 'did:example:admission-a'), (2, 'did:example:admission-a'),
                   (3, 'did:example:admission-b'), (4, 'did:example:admission-b'),
                   (5, 'did:example:admission-c'), (6, 'did:example:admission-c'))
        fixture(sequence, repository)
      """, logger: logger)
    do {
      var cursor: WireInboxRepository?
      for expectedSequence: Int64 in [1, 3, 5, 2] {
        let batch = try await processor.claimWork(asOf: now, limit: 8, afterRepository: cursor)
        #expect(batch.events.count == 1)
        let event = try #require(batch.events.first)
        #expect(event.sequence == expectedSequence)
        #expect(batch.nextRepositoryCursor == event.repository)
        #expect(try await processor.applyClaimed(event, asOf: now) == .applied)
        cursor = batch.nextRepositoryCursor
      }
    } catch {
      _ = try? await pool.query(
        "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)", logger: logger)
      throw error
    }
    try await pool.query(
      "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)", logger: logger)
  }

  @Test("repository continuation preserves scope, readiness and exact head ordering")
  func repositoryContinuationFencing() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-repository-continuation.integration")
    let configuration = try PostgresWireConfig.make(from: url, maximumConnections: 8, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }
    let environment = "wire-continuation-\(UUID().uuidString.lowercased())"
    let now = Date()
    let processor = try PostgresWireInboxProcessor(
      pool: pool, logger: logger, actorSecret: String(repeating: "s", count: 32),
      sourceScope: WireInboxSourceScope(environment: environment, sourceGenerations: ["live"]))
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind,
         repo_did, payload, event_time, next_attempt_at)
      SELECT \(environment), generation, sequence, 'test', 'jetstream_v2_seq', 'identity',
             repository, '{}'::jsonb, \(now), \(now.addingTimeInterval(-1))
      FROM (VALUES
        ('live', 1, 'did:example:ordered'), ('live', 2, 'did:example:ordered'),
        ('live', 3, 'did:example:retry'), ('live', 4, 'did:example:retry'),
        ('live', 5, 'did:example:leased'), ('live', 6, 'did:example:leased'),
        ('live', 7, 'did:example:expired'), ('live', 8, 'did:example:expired'),
        ('history', 9, 'did:example:ordered'),
        ('live', 10, 'did:example:terminal'), ('live', 11, 'did:example:terminal'))
        fixture(generation, sequence, repository)
      """, logger: logger)
    try await pool.query(
      """
      UPDATE wire_ingestion_inbox SET status = 'retry', next_attempt_at = \(now.addingTimeInterval(60))
      WHERE environment = \(environment) AND seq = 3
      """, logger: logger)
    try await pool.query(
      """
      UPDATE wire_ingestion_inbox
      SET status = 'leased', lease_owner = 'previous', lease_token = 'previous-token',
          lease_expires_at = CASE WHEN seq = 5 THEN \(now.addingTimeInterval(60))
                                 ELSE \(now.addingTimeInterval(-1)) END
      WHERE environment = \(environment) AND seq IN (5, 7)
      """, logger: logger)
    try await pool.query(
      """
      UPDATE wire_ingestion_inbox
      SET event_kind = 'commit', collection = 'site.standard.document',
          operation = 'create', record_key = 'malformed'
      WHERE environment = \(environment) AND seq = 10
      """, logger: logger)
    let ordered = WireInboxRepository(
      environment: environment, sourceGeneration: "live", repoDID: "did:example:ordered")
    let outsideGeneration = WireInboxRepository(
      environment: environment, sourceGeneration: "history", repoDID: "did:example:ordered")
    let outsideEnvironment = WireInboxRepository(
      environment: "different-environment", sourceGeneration: "live", repoDID: ordered.repoDID)
    #expect(try await processor.claimNext(in: outsideGeneration, asOf: now) == nil)
    #expect(try await processor.claimNext(in: outsideEnvironment, asOf: now) == nil)
    for blocked in ["retry", "leased"] {
      let repository = WireInboxRepository(
        environment: environment, sourceGeneration: "live", repoDID: "did:example:\(blocked)")
      #expect(try await processor.claimNext(in: repository, asOf: now) == nil)
    }
    let first = try #require(try await processor.claimNext(in: ordered, asOf: now))
    #expect(first.sequence == 1)
    #expect(try await processor.claimNext(in: ordered, asOf: now) == nil)
    #expect(try await processor.applyClaimed(first, asOf: now) == .applied)
    let second = try #require(try await processor.claimNext(in: ordered, asOf: now))
    #expect(second.sequence == 2)
    let expired = WireInboxRepository(
      environment: environment, sourceGeneration: "live", repoDID: "did:example:expired")
    let recovered = try #require(try await processor.claimNext(in: expired, asOf: now))
    #expect(recovered.sequence == 7)
    #expect(recovered.leaseToken != "previous-token")
    let terminal = WireInboxRepository(
      environment: environment, sourceGeneration: "live", repoDID: "did:example:terminal")
    let malformed = try #require(try await processor.claimNext(in: terminal, asOf: now))
    #expect(try await processor.applyClaimed(malformed, asOf: now) == .terminal)
    #expect(try await processor.claimNext(in: terminal, asOf: now)?.sequence == 11)
    try await pool.query(
      "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)", logger: logger)
  }

  @Test("retry and lost acknowledgments preserve the repository barrier and replacement lease")
  func repositoryContinuationRetryAndLeaseLoss() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-repository-retry.integration")
    let configuration = try PostgresWireConfig.make(from: url, maximumConnections: 8, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }
    let environment = "wire-continuation-retry-\(UUID().uuidString.lowercased())"
    let now = Date()
    let processor = try PostgresWireInboxProcessor(
      pool: pool, logger: logger, actorSecret: String(repeating: "s", count: 32),
      sourceScope: WireInboxSourceScope(environment: environment, sourceGenerations: ["live"]))
    let repository = WireInboxRepository(
      environment: environment, sourceGeneration: "live", repoDID: "did:example:retry")
    let payload = """
      {"commit":{"record":{"document":"at://did:example:missing/site.standard.document/\(environment)"}}}
      """
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind,
         repo_did, collection, operation, record_key, payload, event_time, next_attempt_at)
      VALUES
        (\(environment), 'live', 1, 'test', 'jetstream_v2_seq', 'commit', \(repository.repoDID),
         'site.standard.graph.recommend', 'create', 'first', \(payload)::jsonb, \(now), \(now)),
        (\(environment), 'live', 2, 'test', 'jetstream_v2_seq', 'identity', \(repository.repoDID),
         NULL, NULL, NULL, '{}'::jsonb, \(now), \(now))
      """, logger: logger)
    let first = try #require(try await processor.claimNext(in: repository, asOf: now))
    #expect(try await processor.applyClaimed(first, asOf: now) == .retry)
    #expect(try await processor.claimNext(in: repository, asOf: now) == nil)
    let retried = try #require(
      try await processor.claimNext(in: repository, asOf: now.addingTimeInterval(31)))
    #expect(retried.sequence == 1)
    try await pool.query(
      """
      UPDATE wire_ingestion_inbox SET lease_token = 'replacement-owner-token'
      WHERE environment = \(environment) AND seq = 1
      """, logger: logger)
    #expect(try await processor.applyClaimed(retried, asOf: now.addingTimeInterval(31)) == .leaseLost)
    let states = try await pool.query(
      """
      SELECT seq, status, lease_token, attempt_count FROM wire_ingestion_inbox
      WHERE environment = \(environment) ORDER BY seq
      """, logger: logger)
    var rows: [(Int64, String, String?, Int)] = []
    for try await row in states { rows.append(try row.decode((Int64, String, String?, Int).self)) }
    #expect(rows.count == 2)
    #expect(rows.first?.1 == "leased")
    #expect(rows.first?.2 == "replacement-owner-token")
    #expect(rows.last?.1 == "pending")
    #expect(rows.last?.3 == 0)
    try await pool.query(
      "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)", logger: logger)
  }
}
