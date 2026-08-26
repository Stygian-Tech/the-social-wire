import Foundation
import Logging
import PostgresNIO
import Testing
import ThinAppViewCore
import WireCore
@testable import AppView

@Suite(
  "The Wire PostgreSQL serving integration",
  .serialized,
  .enabled(
    if: ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] != nil,
    "Set WIRE_TEST_DATABASE_URL to an explicitly disposable migrated PostgreSQL database."
  )
)
struct WirePostgresServingIntegrationTests {
  @Test("an expired active generation remains available during an ingestion outage")
  func expiredActiveGenerationContinuity() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-appview-postgres.continuity-integration")
    var configuration = try makePostgresConfig(from: url, logger: logger)
    configuration.options.maximumConnections = 2
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let namespace = UUID().uuidString.lowercased()
    let generation = UUID()
    let now = Date()
    let key = "url:\(namespace)-continuity"
    let labelSource = "did:example:labeler:\(namespace)"
    do {
      try await setBaselineLabelState(
        sourceDID: labelSource,
        successfulAt: now,
        pool: pool,
        logger: logger
      )
      try await pool.query(
        """
        INSERT INTO wire_items
          (canonical_key, canonical_url, source_domain, source_name, title, language_code,
           provenance, first_seen_at, last_seen_at, source_confidence, eligible, expires_at)
        VALUES
          (\(key), \("https://example.com/\(namespace)/continuity"), 'example.com',
           'Example', 'Continuity Story', 'und', '["standard_site"]'::jsonb,
           \(now), \(now), 0.9, TRUE, \(now.addingTimeInterval(86_400)))
        """,
        logger: logger
      )
      try await insertGeneration(
        generation,
        keys: [key],
        generatedAt: now.addingTimeInterval(-7_200),
        expiresAt: now.addingTimeInterval(-3_600),
        active: true,
        pool: pool,
        logger: logger
      )

      let store = try PostgresWireFeedStore(
        pool: pool,
        logger: logger,
        cursorSecret: String(repeating: "c", count: 32),
        mode: .visible,
        moderationCache: WireViewerModerationCache()
      )
      let page = try await store.getFeed(
        cursor: nil,
        limit: 10,
        language: nil,
        viewerDid: nil,
        now: now
      )
      #expect(page.generationID == generation.uuidString.lowercased())
      #expect(page.source == .staleGeneration)
      #expect(page.degraded)
      #expect(page.items.map(\.itemID) == [key])
      let catalog = try await store.getCatalog(now: now)
      #expect(catalog.available)
      #expect(catalog.latestGenerationID == generation.uuidString.lowercased())
    } catch {
      Issue.record("PostgreSQL continuity integration failed: \(String(reflecting: error))")
    }

    try await pool.query(
      "DELETE FROM wire_feed_state WHERE active_generation_id = \(generation)",
      logger: logger
    )
    try await pool.query(
      "DELETE FROM wire_rank_generations WHERE generation_id = \(generation)",
      logger: logger
    )
    try await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
    try await pool.query(
      "DELETE FROM wire_label_refresh_state WHERE source_did = \(labelSource)",
      logger: logger
    )
  }

  @Test("pagination remains bound to its retained generation after activation advances")
  func stableGenerationPagination() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-appview-postgres.integration")
    var configuration = try makePostgresConfig(from: url, logger: logger)
    configuration.options.maximumConnections = 2
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let namespace = UUID().uuidString.lowercased()
    let generationOne = UUID()
    let generationTwo = UUID()
    let now = Date()
    let keys = (0..<3).map { "url:\(namespace)-\($0)" }
    let labelSource = "did:example:labeler:\(namespace)"
    do {
      try await setBaselineLabelState(
        sourceDID: labelSource,
        successfulAt: now,
        pool: pool,
        logger: logger
      )
      for (position, key) in keys.enumerated() {
        try await pool.query(
          """
          INSERT INTO wire_items
            (canonical_key, canonical_url, source_domain, source_name, title, language_code,
             provenance, first_seen_at, last_seen_at, source_confidence, eligible, expires_at)
          VALUES
            (\(key), \("https://example.com/\(namespace)/\(position)"), 'example.com',
             'Example', \("Story \(position)"), 'und', '["standard_site"]'::jsonb,
             \(now), \(now), 0.9, TRUE, \(now.addingTimeInterval(86_400)))
          """,
          logger: logger
        )
      }
      try await insertGeneration(
        generationOne,
        keys: keys,
        generatedAt: now.addingTimeInterval(-(31 * 60)),
        active: true,
        pool: pool,
        logger: logger
      )

      let cache = WireViewerModerationCache()
      let store = try PostgresWireFeedStore(
        pool: pool,
        logger: logger,
        cursorSecret: String(repeating: "c", count: 32),
        mode: .visible,
        moderationCache: cache
      )
      let first = try await store.getFeed(
        cursor: nil,
        limit: 2,
        language: "en-US",
        viewerDid: nil,
        now: now
      )
      #expect(first.generationID == generationOne.uuidString.lowercased())
      #expect(first.items.map(\.itemID) == Array(keys.prefix(2)))
      let cursor = try #require(first.cursor)

      try await pool.withTransaction(logger: logger) { connection in
        try await connection.query(
          "UPDATE wire_rank_generations SET status = 'superseded', is_active = FALSE WHERE generation_id = \(generationOne)",
          logger: logger
        )
        try await connection.query(
          """
          INSERT INTO wire_rank_generations
            (generation_id, feed_key, language_bucket, status, is_active, config_version,
             generated_at, committed_at, expires_at, candidate_count, ranked_count)
          VALUES
            (\(generationTwo), 'wire', 'und', 'committed', TRUE, 'wire-v1', \(now), \(now),
             \(now.addingTimeInterval(172_800)), 3, 3)
          """,
          logger: logger
        )
        try await connection.query(
          "UPDATE wire_feed_state SET active_generation_id = \(generationTwo), updated_at = \(now) WHERE feed_key = 'wire' AND language_bucket = 'und'",
          logger: logger
        )
      }

      let second = try await store.getFeed(
        cursor: cursor,
        limit: 2,
        language: "en",
        viewerDid: nil,
        now: now
      )
      #expect(second.generationID == generationOne.uuidString.lowercased())
      #expect(second.items.map(\.itemID) == [keys[2]])
      #expect(Set(first.items.map(\.itemID)).isDisjoint(with: second.items.map(\.itemID)))

      await #expect(throws: WireServingError.self) {
        _ = try await store.getFeed(
          cursor: cursor + "tampered",
          limit: 2,
          language: "en",
          viewerDid: nil,
          now: now
        )
      }

      try await pool.query(
        """
        INSERT INTO wire_labels
          (canonical_key, label_key, label_value, source, applied_at, expires_at)
        VALUES (\(keys[0]), 'test:graphic', 'graphic', 'integration', \(now),
                \(now.addingTimeInterval(3_600)))
        """,
        logger: logger
      )
      #expect(try await store.getItem(itemId: keys[0], viewerDid: nil) == nil)
      try await pool.query(
        "DELETE FROM wire_labels WHERE canonical_key = \(keys[0]) AND source = 'integration'",
        logger: logger
      )
    } catch {
      Issue.record("PostgreSQL serving integration failed: \(String(reflecting: error))")
    }

    try await pool.query(
      "DELETE FROM wire_feed_state WHERE active_generation_id IN (\(generationOne), \(generationTwo))",
      logger: logger
    )
    try await pool.query(
      "DELETE FROM wire_rank_generations WHERE generation_id IN (\(generationOne), \(generationTwo))",
      logger: logger
    )
    for key in keys {
      try await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
    }
    try await pool.query(
      "DELETE FROM wire_label_refresh_state WHERE source_did = \(labelSource)",
      logger: logger
    )
  }

  @Test("a sparse requested locale serves the available global fallback corpus")
  func sparseLocaleGlobalFallback() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-appview-postgres.fallback-integration")
    var configuration = try makePostgresConfig(from: url, logger: logger)
    configuration.options.maximumConnections = 2
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let namespace = UUID().uuidString.lowercased()
    let keyPrefix = "url:\(namespace)-fallback-"
    let urlPrefix = "https://example.com/\(namespace)/fallback/"
    let now = Date()
    let labelSource = "did:example:labeler:\(namespace)"
    do {
      try await setBaselineLabelState(
        sourceDID: labelSource,
        successfulAt: now,
        pool: pool,
        logger: logger
      )
      try await pool.query(
        """
        INSERT INTO wire_items
          (canonical_key, canonical_url, source_domain, source_name, title, language_code,
           provenance, first_seen_at, last_seen_at, published_at, source_confidence,
           eligible, expires_at)
        SELECT \(keyPrefix) || sequence::text, \(urlPrefix) || sequence::text,
               'example.com', 'Example', 'Fallback story ' || sequence::text, 'und',
               '["standard_site"]'::jsonb, \(now), \(now), \(now), 0.9, TRUE,
               \(now.addingTimeInterval(86_400))
        FROM generate_series(1, \(WireDataPolicy.minimumGlobalCandidates)) AS generated(sequence)
        """,
        logger: logger
      )
      try await pool.query(
        """
        INSERT INTO wire_signal_rollups
          (canonical_key, shares_24h, recommendations_24h, updated_at)
        SELECT \(keyPrefix) || sequence::text, 3, 1, \(now)
        FROM generate_series(1, \(WireDataPolicy.minimumGlobalCandidates)) AS generated(sequence)
        """,
        logger: logger
      )

      let store = try PostgresWireFeedStore(
        pool: pool,
        logger: logger,
        cursorSecret: String(repeating: "c", count: 32),
        mode: .visible,
        moderationCache: WireViewerModerationCache()
      )
      let catalog = try await store.getCatalog(now: now)
      #expect(catalog.available)

      let page = try await store.getFeed(
        cursor: nil,
        limit: 50,
        language: "en-US",
        viewerDid: nil,
        now: now
      )
      #expect(page.source == .simplifiedFallback)
      #expect(page.language == "und")
      #expect(page.items.count == 50)
      #expect(page.items.allSatisfy { $0.itemID.hasPrefix(keyPrefix) })
    } catch {
      Issue.record("PostgreSQL locale fallback integration failed: \(String(reflecting: error))")
    }

    try await pool.query(
      "DELETE FROM wire_items WHERE canonical_key LIKE \(keyPrefix + "%")",
      logger: logger
    )
    try await pool.query(
      "DELETE FROM wire_label_refresh_state WHERE source_did = \(labelSource)",
      logger: logger
    )
  }

  @Test("a stale localized generation yields to a fresh global generation")
  func staleLocalizedGenerationUsesFreshGlobal() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-appview-postgres.fresh-global-integration")
    var configuration = try makePostgresConfig(from: url, logger: logger)
    configuration.options.maximumConnections = 2
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let namespace = UUID().uuidString.lowercased()
    let key = "url:\(namespace)-fresh-global"
    let localizedGeneration = UUID()
    let globalGeneration = UUID()
    let now = Date()
    let labelSource = "did:example:labeler:\(namespace)"
    do {
      try await setBaselineLabelState(
        sourceDID: labelSource,
        successfulAt: now,
        pool: pool,
        logger: logger
      )
      try await pool.query(
        """
        INSERT INTO wire_items
          (canonical_key, canonical_url, source_domain, source_name, title, language_code,
           provenance, first_seen_at, last_seen_at, published_at, source_confidence,
           eligible, expires_at)
        VALUES
          (\(key), \("https://example.com/\(namespace)/fresh-global"), 'example.com',
           'Example', 'Fresh global story', 'und', '["standard_site"]'::jsonb,
           \(now), \(now), \(now), 0.9, TRUE, \(now.addingTimeInterval(86_400)))
        """,
        logger: logger
      )
      try await insertGeneration(
        globalGeneration,
        keys: [key],
        generatedAt: now,
        active: true,
        pool: pool,
        logger: logger
      )
      try await insertGeneration(
        localizedGeneration,
        keys: [key],
        generatedAt: now.addingTimeInterval(-31 * 60),
        active: true,
        language: "en",
        pool: pool,
        logger: logger
      )

      let store = try PostgresWireFeedStore(
        pool: pool,
        logger: logger,
        cursorSecret: String(repeating: "c", count: 32),
        mode: .visible,
        moderationCache: WireViewerModerationCache()
      )
      let page = try await store.getFeed(
        cursor: nil,
        limit: 1,
        language: "en-US",
        viewerDid: nil,
        now: now
      )
      #expect(page.generationID == globalGeneration.uuidString.lowercased())
      #expect(page.language == "und")
      #expect(page.source == .ranked)
      #expect(!page.degraded)
    } catch {
      Issue.record("PostgreSQL fresh-global integration failed: \(String(reflecting: error))")
    }

    try await pool.query(
      "DELETE FROM wire_feed_state WHERE active_generation_id IN (\(localizedGeneration), \(globalGeneration))",
      logger: logger
    )
    try await pool.query(
      "DELETE FROM wire_rank_generations WHERE generation_id IN (\(localizedGeneration), \(globalGeneration))",
      logger: logger
    )
    try await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
    try await pool.query(
      "DELETE FROM wire_label_refresh_state WHERE source_did = \(labelSource)",
      logger: logger
    )
  }

  @Test("serving and catalog fail closed after the baseline label snapshot is thirty minutes stale")
  func staleBaselineFailsClosed() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-appview-postgres.label-freshness-integration")
    var configuration = try makePostgresConfig(from: url, logger: logger)
    configuration.options.maximumConnections = 2
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }

    let now = Date()
    let labelSource = "did:example:labeler:\(UUID().uuidString.lowercased())"
    try await setBaselineLabelState(
      sourceDID: labelSource,
      successfulAt: now.addingTimeInterval(-(30 * 60 + 1)),
      pool: pool,
      logger: logger
    )
    let store = try PostgresWireFeedStore(
      pool: pool,
      logger: logger,
      cursorSecret: String(repeating: "c", count: 32),
      mode: .visible,
      moderationCache: WireViewerModerationCache()
    )

    await #expect(throws: WireServingError.moderationUnavailable) {
      _ = try await store.getCatalog(now: now)
    }
    await #expect(throws: WireServingError.moderationUnavailable) {
      _ = try await store.getFeed(
        cursor: nil,
        limit: 30,
        language: "und",
        viewerDid: nil,
        now: now
      )
    }
    await #expect(throws: WireServingError.moderationUnavailable) {
      _ = try await store.getItem(itemId: "missing", viewerDid: nil)
    }

    try await pool.query(
      "DELETE FROM wire_label_refresh_state WHERE source_did = \(labelSource)",
      logger: logger
    )
  }

  private func setBaselineLabelState(
    sourceDID: String,
    successfulAt: Date,
    pool: PostgresClient,
    logger: Logger
  ) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        "UPDATE wire_label_refresh_state SET is_current = FALSE WHERE is_current = TRUE",
        logger: logger
      )
      try await connection.query(
        """
        INSERT INTO wire_label_refresh_state
          (source_did, endpoint_host, last_attempted_at, last_successful_at,
           target_count, label_count, is_current)
        VALUES
          (\(sourceDID), 'labels.example', \(successfulAt), \(successfulAt), 0, 0, TRUE)
        ON CONFLICT (source_did) DO UPDATE SET
          last_attempted_at = EXCLUDED.last_attempted_at,
          last_successful_at = EXCLUDED.last_successful_at,
          is_current = TRUE
        """,
        logger: logger
      )
    }
  }

  private func insertGeneration(
    _ id: UUID,
    keys: [String],
    generatedAt: Date,
    expiresAt: Date? = nil,
    active: Bool,
    language: String = "und",
    pool: PostgresClient,
    logger: Logger
  ) async throws {
    try await pool.withTransaction(logger: logger) { connection in
      try await connection.query(
        """
        INSERT INTO wire_rank_generations
          (generation_id, feed_key, language_bucket, status, is_active, config_version,
           generated_at, committed_at, expires_at, candidate_count, ranked_count)
        VALUES
          (\(id), 'wire', \(language), 'committed', \(active), 'wire-v1', \(generatedAt),
           \(generatedAt), \(expiresAt ?? generatedAt.addingTimeInterval(172_800)),
           \(keys.count), \(keys.count))
        """,
        logger: logger
      )
      for (position, key) in keys.enumerated() {
        try await connection.query(
          """
          INSERT INTO wire_ranked_items
            (generation_id, position, canonical_key, score, reason_codes, diversity_metadata)
          VALUES (\(id), \(position), \(key), \(Double(keys.count - position)), '[]'::jsonb, '{}'::jsonb)
          """,
          logger: logger
        )
      }
      try await connection.query(
        """
        INSERT INTO wire_feed_state (feed_key, language_bucket, active_generation_id, updated_at)
        VALUES ('wire', \(language), \(id), \(generatedAt))
        ON CONFLICT (feed_key, language_bucket) DO UPDATE
        SET active_generation_id = EXCLUDED.active_generation_id, updated_at = EXCLUDED.updated_at
        """,
        logger: logger
      )
    }
  }
}
