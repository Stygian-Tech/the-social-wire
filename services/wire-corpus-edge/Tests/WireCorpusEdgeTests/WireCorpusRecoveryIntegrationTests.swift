import Foundation
import Logging
import PostgresNIO
import Testing
@testable import WireCorpusEdge

// Share serialization with the other fixtures that mutate global Wire feed state.
extension WireCorpusCacheIntegrationTests {
  @Test("fresh feed, cursor and edition disclose incomplete archive reconstruction")
  func recoveryRemainsDegradedUntilReplayCompletes() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-corpus.recovery-test")
    let config = try WireCorpusEdgePostgresConfig.make(from: url, maximumConnections: 2, logger: logger)
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let task = Task { await pool.run() }
    await Task.yield()
    defer { task.cancel() }
    let source = UUID().uuidString.lowercased()
    let generation = UUID()
    let now = Date()
    let labeler = "did:example:\(source)"
    do {
      try await pool.query(
        """
        INSERT INTO wire_label_refresh_state
          (source_did, endpoint_host, last_attempted_at, last_successful_at, target_count, label_count, is_current)
        VALUES (\(labeler), 'labels.example', \(now), \(now), 0, 0, TRUE)
        """, logger: logger)
      try await pool.query(
        """
        INSERT INTO wire_rank_generations
          (generation_id, feed_key, language_bucket, status, is_active, config_version,
           generated_at, committed_at, expires_at, candidate_count, ranked_count)
        VALUES (\(generation), 'wire', 'und', 'committed', TRUE, 'wire-v1', \(now), \(now),
          \(now.addingTimeInterval(3600)), 0, 0)
        """, logger: logger)
      try await pool.query(
        """
        INSERT INTO wire_feed_state (feed_key, language_bucket, active_generation_id, updated_at)
        VALUES ('wire', 'und', \(generation), \(now))
        """, logger: logger)
      try await pool.query(
        """
        INSERT INTO wire_edition_generations
          (generation_id, algorithm_version, language_bucket, continuation_ordinal, materialized_at)
        VALUES (\(generation), 'wire-v1', 'und', 0, \(now))
        """, logger: logger)
      try await pool.query("""
        INSERT INTO wire_items (canonical_key, canonical_url, source_domain, source_name, title,
          first_seen_at, last_seen_at, expires_at, language_code)
        VALUES (\(source), \("https://example.com/" + source), 'example.com', 'Example', 'Story',
          \(now), \(now), \(now.addingTimeInterval(3600)), 'und')
        """, logger: logger)
      try await pool.query("INSERT INTO wire_ranked_items (generation_id, position, canonical_key, score) VALUES (\(generation), 0, \(source), 1)", logger: logger)
      try await pool.query("INSERT INTO wire_edition_modules (generation_id, module_key, module_kind, position) VALUES (\(generation), 'top', 'top_stories', 0)", logger: logger)
      try await pool.query("INSERT INTO wire_edition_module_items (generation_id, module_key, position, canonical_key) VALUES (\(generation), 'top', 0, \(source))", logger: logger)
      let store = PostgresWireCorpusStore(pool: pool, logger: logger,
        payloadCache: WireCorpusPayloadCache(commands: CorpusCacheCommands(), environment: "test"))
      let before = try await store.feed(language: "und", generationID: nil, startOrdinal: 0, limit: 10, now: now)
      #expect(!before.degraded)
      try await pool.query(
        """
        INSERT INTO wire_publication_signal_recovery_jobs
          (environment, source_generation, inbox_initialized_at, maximum_source_seq, completed_at)
        VALUES ('test', \(source), \(now), 100, \(now))
        """, logger: logger)
      let feed = try await store.feed(language: "und", generationID: nil, startOrdinal: 0, limit: 10, now: now)
      let cursor = try await store.feed(language: "und", generationID: generation, startOrdinal: 0, limit: 10, now: now)
      let edition = try await store.edition(language: "und", region: nil, now: now).edition
      #expect(feed.source == .ranked)
      #expect(feed.degraded && cursor.degraded && edition.degraded)
      try await pool.query(
        "UPDATE wire_publication_signal_recovery_jobs SET replay_completed_at = \(now) WHERE source_generation = \(source)",
        logger: logger)
      let complete = try await store.edition(language: "und", region: nil, now: now).edition
      #expect(!complete.degraded)
    } catch {
      Issue.record("Corpus recovery fixture failed: \(String(reflecting: error))")
    }
    try await pool.query("DELETE FROM wire_publication_signal_recovery_jobs WHERE source_generation = \(source)", logger: logger)
    try await pool.query("DELETE FROM wire_feed_state WHERE active_generation_id = \(generation)", logger: logger)
    try await pool.query("DELETE FROM wire_rank_generations WHERE generation_id = \(generation)", logger: logger)
    try await pool.query("DELETE FROM wire_items WHERE canonical_key = \(source)", logger: logger)
    try await pool.query("DELETE FROM wire_label_refresh_state WHERE source_did = \(labeler)", logger: logger)
  }
}
