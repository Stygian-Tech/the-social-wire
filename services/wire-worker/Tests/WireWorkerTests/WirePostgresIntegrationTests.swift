import Foundation
import Logging
import PostgresNIO
import Testing
import WireCore
@testable import WireWorker

@Suite(
  "The Wire PostgreSQL integration",
  .serialized,
  .enabled(
    if: ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] != nil,
    "Set WIRE_TEST_DATABASE_URL to an explicitly disposable migrated PostgreSQL database."
  )
)
struct WirePostgresIntegrationTests {
  @Test("a partial label refresh retains labels for unqueried candidates")
  func partialLabelRefreshScope() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-label-snapshot-postgres.integration")
    let configuration = try PostgresWireConfig.make(from: url, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let namespace = UUID().uuidString.lowercased()
    let queriedKey = "url:\(namespace)-queried"
    let unqueriedKey = "url:\(namespace)-unqueried"
    let sourceDID = "did:example:labeler:\(namespace)"
    let labelSource = "\(sourceDID)|subject-hash|spam"
    let now = Date()
    for key in [queriedKey, unqueriedKey] {
      try await pool.query(
        """
        INSERT INTO wire_items
          (canonical_key, canonical_url, source_domain, source_name, title,
           first_seen_at, last_seen_at, expires_at)
        VALUES
          (\(key), \("https://example.com/\(key)"), 'example.com', 'Example', 'Story',
           \(now), \(now), \(now.addingTimeInterval(86_400)))
        """,
        logger: logger
      )
      try await pool.query(
        """
        INSERT INTO wire_labels
          (canonical_key, label_key, label_value, source, applied_at, expires_at)
        VALUES
          (\(key), 'moderation', 'spam', \(labelSource), \(now),
           \(now.addingTimeInterval(86_400)))
        """,
        logger: logger
      )
    }
    let labeler = try #require(
      WireLabelerEndpoint.parse("\(sourceDID)|https://labels.example").first
    )
    let store = PostgresWireBaselineLabelStore(pool: pool, logger: logger)
    try await store.replaceSnapshot(
      labels: [],
      labelers: [labeler],
      refreshedCanonicalKeys: [queriedKey],
      targetCount: 1,
      refreshedAt: now
    )

    let rows = try await pool.query(
      """
      SELECT canonical_key FROM wire_labels
      WHERE source = \(labelSource)
      ORDER BY canonical_key
      """,
      logger: logger
    )
    var remaining: [String] = []
    for try await row in rows { remaining.append(try row.decode(String.self)) }
    #expect(remaining == [unqueriedKey])

    try await pool.query(
      "DELETE FROM wire_label_refresh_state WHERE source_did = \(sourceDID)",
      logger: logger
    )
    for key in [queriedKey, unqueriedKey] {
      try await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
    }
  }

  @Test("applies an article, builds exact rollups, and retracts its signal")
  func articleLifecycle() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-postgres.integration")
    let configuration = try PostgresWireConfig.make(from: url, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let environment = "wire-test-\(UUID().uuidString.lowercased())"
    let generation = "wire-test-v1"
    let did = "did:plc:wiretest"
    let recordKey = UUID().uuidString.lowercased()
    let articleURL = "https://example.com/story?utm_source=test&id=\(recordKey)"
    let createPayload = """
      {"did":"\(did)","time_us":1,"kind":"commit","commit":{"operation":"create","collection":"site.standard.document","rkey":"\(recordKey)","rev":"one","record":{"$type":"site.standard.document","url":"\(articleURL)","title":"The Wire Integration Story","createdAt":"2026-08-20T12:00:00Z"}}}
      """
    let now = Date()
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
         collection, operation, repo_rev, record_key, payload, event_time)
      VALUES
        (\(environment), \(generation), 1, 'test', 'jetstream_v2_seq', 'commit', \(did),
         'site.standard.document', 'create', 'one', \(recordKey), \(createPayload)::jsonb, \(now))
      """,
      logger: logger
    )
    let processor = try PostgresWireInboxProcessor(
      pool: pool,
      logger: logger,
      actorSecret: String(repeating: "s", count: 32)
    )
    let createProcessAt = Date()
    let createdCount: Int
    do {
      createdCount = try await processor.process(asOf: createProcessAt)
    } catch {
      Issue.record("Create processing failed: \(String(reflecting: error))")
      return
    }
    #expect(createdCount == 1)

    let canonical = WireCanonicalizer.canonicalize(articleURL)!
    let itemRows = try await pool.query(
      "SELECT title FROM wire_items WHERE canonical_key = \(canonical.canonicalKey)",
      logger: logger
    )
    var title: String?
    for try await row in itemRows { title = try row.decode(String.self) }
    #expect(title == "The Wire Integration Story")
    let rollupRows = try await pool.query(
      "SELECT shares_24h, signals_7d FROM wire_signal_rollups WHERE canonical_key = \(canonical.canonicalKey)",
      logger: logger
    )
    var rollup: (Int, Int)?
    for try await row in rollupRows { rollup = try row.decode((Int, Int).self) }
    #expect(rollup?.0 == 1)
    #expect(rollup?.1 == 1)

    let deletePayload = """
      {"did":"\(did)","time_us":2,"kind":"commit","commit":{"operation":"delete","collection":"site.standard.document","rkey":"\(recordKey)","rev":"two"}}
      """
    try await pool.query(
      """
      INSERT INTO wire_ingestion_inbox
        (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
         collection, operation, repo_rev, record_key, payload, event_time)
      VALUES
        (\(environment), \(generation), 2, 'test', 'jetstream_v2_seq', 'commit', \(did),
         'site.standard.document', 'delete', 'two', \(recordKey), \(deletePayload)::jsonb, \(now))
      """,
      logger: logger
    )
    let deleteProcessAt = Date()
    let deletedCount: Int
    do {
      deletedCount = try await processor.process(asOf: deleteProcessAt)
    } catch {
      Issue.record("Delete processing failed: \(String(reflecting: error))")
      return
    }
    #expect(deletedCount == 1)
    let signalRows = try await pool.query(
      "SELECT COUNT(*)::bigint FROM wire_signal_events WHERE canonical_key = \(canonical.canonicalKey)",
      logger: logger
    )
    for try await row in signalRows { #expect(try row.decode(Int64.self) == 0) }

    try await pool.query(
      "DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)", logger: logger)
    try await pool.query(
      "DELETE FROM wire_items WHERE canonical_key = \(canonical.canonicalKey)", logger: logger)
    let actorHash = try WireActorHasher(secret: Data(String(repeating: "s", count: 32).utf8)).hash(did)
    try await pool.query(
      "DELETE FROM wire_active_actors WHERE actor_key_hash = \(actorHash)", logger: logger)
  }
}
