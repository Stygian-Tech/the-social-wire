import Foundation
import Logging
import PostgresNIO
import Testing
import ThinAppViewCore
import WireCore

@testable import AppView

@Suite(
  "Your Circle PostgreSQL and Redis ownership",
  .enabled(
    if: ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] != nil,
    "Set WIRE_TEST_DATABASE_URL to a disposable migrated PostgreSQL database."
  )
)
struct CirclePostgresCacheIntegrationTests {
  @Test("Redis failure preserves durable hides without writing PostgreSQL caches")
  func durableHidesDuringCacheOutage() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "circle-cache.integration")
    let pool = PostgresClient(
      configuration: try makePostgresConfig(from: url, logger: logger), backgroundLogger: logger
    )
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }
    let commands = CircleRedisTestCommands()
    let now = Date()
    let cache = RedisCircleDisposableCache(commands: commands, environment: "test", now: { now })
    let hasher = try WireActorHasher(secret: Data(repeating: 1, count: 32))
    let state = PostgresCirclePrivateStateStore(
      pool: pool, cache: cache, actorHasher: hasher, logger: logger)
    let viewer = "did:plc:\(UUID().uuidString.lowercased())"
    let viewerHash = try hasher.hash(viewer)
    let snapshotID = UUID()
    try await state.store(
      CircleGraphSnapshot(
        snapshotID: snapshotID, viewerDID: viewer, directMembers: [], oneHopMembers: [],
        directCandidateCount: 0, oneHopCandidateCount: 0, oneHopExpansionComplete: true,
        generatedAt: now),
      excludedDIDs: []
    )
    try await state.storeEdition(
      viewerDID: viewer, snapshotID: snapshotID, generationID: "one", language: "en",
      hiddenStoryIDs: [], expiresAt: now.addingTimeInterval(60), payload: Data("old".utf8))
    await commands.setUnavailable(true)
    try await state.setHidden(viewerDID: viewer, storyID: "story", hidden: true, now: now)
    #expect(try await state.hiddenStoryIDs(viewerDID: viewer) == ["story"])
    #expect(try await state.load(viewerDID: viewer, excludedDIDs: []) == nil)
    let rows = try await pool.query(
      """
      SELECT
        (SELECT COUNT(*) FROM appview_circle_graph_snapshots WHERE viewer_key_hash = \(viewerHash)) +
        (SELECT COUNT(*) FROM appview_circle_edition_cache WHERE viewer_key_hash = \(viewerHash))
      """, logger: logger
    )
    for try await row in rows { #expect(try row.decode(Int64.self) == 0) }
    // Another replica still sees the durable hide after the first cache failed.
    let other = PostgresCirclePrivateStateStore(pool: pool, actorHasher: hasher, logger: logger)
    #expect(try await other.hiddenStoryIDs(viewerDID: viewer) == ["story"])
    await commands.setUnavailable(false)
    let recoveredCache = RedisCircleDisposableCache(
      commands: commands, environment: "test", now: { now })
    #expect(
      await recoveredCache.cachedEdition(
        viewerDID: viewer, snapshotID: snapshotID, generationID: "one", language: "en",
        hiddenStoryIDs: ["story"], now: now) == nil)
    let recovered = PostgresCirclePrivateStateStore(
      pool: pool, cache: recoveredCache, actorHasher: hasher, logger: logger)
    try await recovered.purge(viewerDID: viewer)
    #expect(try await other.hiddenStoryIDs(viewerDID: viewer).isEmpty)
    #expect(await commands.keys().isEmpty)
  }

  @Test("legacy expiry obeys one total batch budget and preserves fresh caches and hides")
  func legacyCacheExpiry() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "circle-cache.cleanup-integration")
    let pool = PostgresClient(
      configuration: try makePostgresConfig(from: url, logger: logger), backgroundLogger: logger
    )
    let runTask = Task { await pool.run() }
    await Task.yield()
    defer { runTask.cancel() }
    let store = PostgresThinAppViewStore(pool: pool, logger: logger)
    let prefix = UUID().uuidString.lowercased()
    // A historical cutoff isolates this test from other suites' current fixtures.
    let cutoff = Date(timeIntervalSince1970: 1_000_000)
    for index in 0..<4 {
      let viewer = "\(prefix)-\(index)"
      let expiry = cutoff.addingTimeInterval(index < 3 ? -1 : 60)
      try await pool.query(
        """
        INSERT INTO appview_circle_graph_snapshots
          (viewer_key_hash, snapshot_id, graph_digest, direct_count, one_hop_count,
           actor_facts, generated_at, fresh_until, stale_until)
        VALUES (\(viewer), \(UUID()), \(prefix), 0, 0, '{}'::jsonb,
                \(cutoff.addingTimeInterval(-120)), \(cutoff.addingTimeInterval(-60)), \(expiry))
        """, logger: logger
      )
      try await pool.query(
        """
        INSERT INTO appview_circle_edition_cache
          (viewer_key_hash, snapshot_id, generation_id, language_code, expires_at, payload)
        VALUES (\(viewer), \(UUID()), 'cleanup-generation', 'en', \(expiry), '{}'::jsonb)
        """, logger: logger
      )
      try await pool.query(
        """
        INSERT INTO appview_circle_hidden_items (viewer_key_hash, canonical_key)
        VALUES (\(viewer), 'durable-hide')
        """, logger: logger
      )
    }
    #expect(try await store.deleteExpiredCircleCaches(before: cutoff, batchSize: 2) == 2)
    #expect(try await store.deleteExpiredCircleCaches(before: cutoff, batchSize: 2) == 2)
    #expect(try await store.deleteExpiredCircleCaches(before: cutoff, batchSize: 2) == 2)
    #expect(try await store.deleteExpiredCircleCaches(before: cutoff, batchSize: 2) == 0)
    let rows = try await pool.query(
      """
      SELECT
        (SELECT COUNT(*) FROM appview_circle_graph_snapshots WHERE viewer_key_hash LIKE \(prefix + "%")),
        (SELECT COUNT(*) FROM appview_circle_edition_cache WHERE viewer_key_hash LIKE \(prefix + "%")),
        (SELECT COUNT(*) FROM appview_circle_hidden_items WHERE viewer_key_hash LIKE \(prefix + "%"))
      """, logger: logger
    )
    for try await row in rows {
      let counts = try row.decode((Int64, Int64, Int64).self)
      #expect(counts.0 == 1)
      #expect(counts.1 == 1)
      #expect(counts.2 == 4)
    }
    try await pool.query(
      "DELETE FROM appview_circle_graph_snapshots WHERE viewer_key_hash LIKE \(prefix + "%")",
      logger: logger)
    try await pool.query(
      "DELETE FROM appview_circle_edition_cache WHERE viewer_key_hash LIKE \(prefix + "%")",
      logger: logger)
    try await pool.query(
      "DELETE FROM appview_circle_hidden_items WHERE viewer_key_hash LIKE \(prefix + "%")",
      logger: logger)
  }

}
