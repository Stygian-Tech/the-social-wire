import Foundation
import Logging
import PostgresNIO
import Testing
@testable import WireCorpusEdge

@Suite("Corpus Redis authoritative validation", .serialized, .enabled(
  if: ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] != nil,
  "Requires an explicitly disposable migrated PostgreSQL database."))
struct WireCorpusCacheIntegrationTests {
  @Test("cache hits preserve moderation, item edits, expiry and cursor authority")
  func authoritativeValidation() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-corpus.cache-test")
    let config = try WireCorpusEdgePostgresConfig.make(from: url, maximumConnections: 2, logger: logger)
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let running = Task { await pool.run() }
    defer { running.cancel() }
    let key = UUID().uuidString.lowercased()
    let labeler = "did:example:\(key)"
    let generation = UUID()
    let now = Date()
    let commands = CorpusCacheCommands()
    let cached = PostgresWireCorpusStore(pool: pool, logger: logger,
      payloadCache: WireCorpusPayloadCache(commands: commands, environment: "test"))
    let plain = PostgresWireCorpusStore(pool: pool, logger: logger)
    do {
      try await pool.query("""
        INSERT INTO wire_label_refresh_state
          (source_did, endpoint_host, last_attempted_at, last_successful_at, target_count, label_count, is_current)
        VALUES (\(labeler), 'labels.example', \(now), \(now), 0, 0, TRUE)
        """, logger: logger)
      try await pool.query("""
        INSERT INTO wire_items (canonical_key, canonical_url, source_domain, source_name, title,
          first_seen_at, last_seen_at, expires_at, language_code)
        VALUES (\(key), \("https://example.com/" + key), 'example.com', 'Example', 'Before',
          \(now), \(now), \(now.addingTimeInterval(3600)), 'en')
        """, logger: logger)
      try await pool.query("""
        INSERT INTO wire_rank_generations
          (generation_id, feed_key, language_bucket, status, is_active, config_version,
           generated_at, committed_at, expires_at, candidate_count, ranked_count)
        VALUES (\(generation), 'wire', 'en', 'committed', TRUE, 'wire-v1', \(now), \(now),
          \(now.addingTimeInterval(3600)), 1, 1)
        """, logger: logger)
      try await pool.query("""
        INSERT INTO wire_feed_state (feed_key, language_bucket, active_generation_id, updated_at)
        VALUES ('wire', 'en', \(generation), \(now))
        """, logger: logger)
      try await pool.query("""
        INSERT INTO wire_ranked_items (generation_id, position, canonical_key, score)
        VALUES (\(generation), 0, \(key), 1)
        """, logger: logger)
      try await pool.query("""
        INSERT INTO wire_edition_generations (generation_id, language_bucket, continuation_ordinal)
        VALUES (\(generation), 'en', 1)
        """, logger: logger)
      try await pool.query("""
        INSERT INTO wire_edition_modules (generation_id, module_key, module_kind, position)
        VALUES (\(generation), 'top', 'top_stories', 0)
        """, logger: logger)
      try await pool.query("""
        INSERT INTO wire_edition_module_items (generation_id, module_key, position, canonical_key)
        VALUES (\(generation), 'top', 0, \(key))
        """, logger: logger)
      for _ in 0..<2 {
        let feed = try await cached.feed(language: "en", generationID: generation, startOrdinal: 0, limit: 10, now: now)
        let baseline = try await plain.feed(language: "en", generationID: generation, startOrdinal: 0, limit: 10, now: now)
        // Recovery state is deliberately live and can change between these two
        // reads; compare the cached payload and pinned generation separately.
        #expect(feed.rows == baseline.rows)
        #expect(feed.generationID == baseline.generationID)
        #expect(feed.generatedAt == baseline.generatedAt)
        #expect(feed.rows.count == 1)
        #expect(try await cached.edition(language: "en", region: nil, now: now).leadStories.count == 1)
        #expect(try await cached.item(id: key, now: now)?.item.title == "Before")
      }
      #expect(await commands.writes == 3)
      try await pool.query("UPDATE wire_items SET title = 'After' WHERE canonical_key = \(key)", logger: logger)
      #expect(try await cached.item(id: key, now: now)?.item.title == "After")
      #expect(try await cached.edition(language: "en", region: nil, now: now).leadStories.first?.title == "After")
      try await pool.query("""
        INSERT INTO wire_labels (canonical_key, label_key, label_value, source, applied_at, expires_at)
        VALUES (\(key), 'block', 'block', 'test', \(now), \(now.addingTimeInterval(3600)))
        """, logger: logger)
      #expect(try await cached.item(id: key, now: now) == nil)
      #expect(try await cached.feed(language: "en", generationID: generation, startOrdinal: 0, limit: 10, now: now).rows.isEmpty)
      #expect(try await cached.edition(language: "en", region: nil, now: now).leadStories.isEmpty)
      try await pool.query("DELETE FROM wire_labels WHERE canonical_key = \(key)", logger: logger)
      #expect(try await cached.edition(language: "en", region: nil, now: now).leadStories.count == 1)
      try await pool.query("UPDATE wire_items SET expires_at = NOW() - INTERVAL '1 second' WHERE canonical_key = \(key)", logger: logger)
      #expect(try await cached.item(id: key, now: now) == nil)
      #expect(try await cached.feed(language: "en", generationID: generation, startOrdinal: 0, limit: 10, now: now).rows.isEmpty)
      try await pool.query("UPDATE wire_rank_generations SET expires_at = \(now.addingTimeInterval(-1)) WHERE generation_id = \(generation)", logger: logger)
      await #expect(throws: WireCorpusEdgeStoreError.cursorExpired) {
        try await cached.feed(language: "en", generationID: generation, startOrdinal: 0, limit: 10, now: now)
      }
    } catch {
      Issue.record("Corpus cache fixture failed: \(String(reflecting: error))")
    }
    try await pool.query("DELETE FROM wire_feed_state WHERE active_generation_id = \(generation)", logger: logger)
    try await pool.query("DELETE FROM wire_rank_generations WHERE generation_id = \(generation)", logger: logger)
    try await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
    try await pool.query("DELETE FROM wire_label_refresh_state WHERE source_did = \(labeler)", logger: logger)
  }
}
