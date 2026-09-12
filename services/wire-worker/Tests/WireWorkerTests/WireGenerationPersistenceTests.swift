import Foundation
import Logging
import OperationsCore
import PostgresNIO
import Testing
import WireCore

@testable import WireWorkerCore

// Retention advances a database-wide cleanup clock, including signal expiry.
// Share the ingestion/rollup suite's serialization boundary so these tests
// cannot remove another fixture's still-live signal or projection rows.
extension WirePostgresIntegrationTests {
  @Test("an expired or replaced Coordinator cannot publish or leave partial generation rows",
    arguments: [false, true])
  func rejectsStaleCoordinator(withSuccessor: Bool) async throws {
    try await withStore { store, pool, logger in
      let now = Date()
      let suffix = UUID().uuidString.lowercased()
      let environment = "fence-\(suffix.prefix(12))"
      let role = "indexing.wire-materializer"
      let keys = ["fence-item-\(suffix)"]
      try await seedItems(keys, at: now, pool: pool, logger: logger)
      let control = PostgresOperationsStore(pool: pool, environment: environment, logger: logger)
      let lease = try #require(try await control.acquireRoleLease(
        role: role, ownerID: "old", leaseUntil: now.addingTimeInterval(30), at: now))
      var predecessor = store
      predecessor.roleLeaseAuthority = RoleLeaseAuthority(
        environment: environment, role: role, ownerID: "old", fencingToken: lease.fencingToken)
      var generation = makeGeneration(keys: keys, at: now, feed: "fence-feed-\(suffix)")
      try await predecessor.commit(generation)
      var activeID = generation.generationID
      try await pool.query(
        "UPDATE operations_role_leases SET acquired_at = clock_timestamp() - INTERVAL '2 seconds', lease_expires_at = clock_timestamp() - INTERVAL '1 second' WHERE environment = \(environment) AND role = \(role)",
        logger: logger)
      if withSuccessor {
        let replacement = try #require(try await control.acquireRoleLease(
          role: role, ownerID: "new", leaseUntil: now.addingTimeInterval(30), at: now))
        var successor = store
        successor.roleLeaseAuthority = RoleLeaseAuthority(
          environment: environment, role: role, ownerID: "new", fencingToken: replacement.fencingToken)
        generation.generationID = UUID()
        try await successor.commit(generation)
        activeID = generation.generationID
      }
      generation.generationID = UUID()
      await #expect(throws: (any Error).self) { try await predecessor.commit(generation) }
      let state = try await pool.query(
        "SELECT active_generation_id FROM wire_feed_state WHERE feed_key = \(generation.feedKey)",
        logger: logger)
      for try await row in state { #expect(try row.decode(UUID.self) == activeID) }
      let partial = try await pool.query(
        "SELECT COUNT(*)::bigint FROM wire_rank_generations WHERE generation_id = \(generation.generationID)",
        logger: logger)
      for try await row in partial { #expect(try row.decode(Int64.self) == 0) }
    }
  }

  @Test("bulk rows preserve ranking order, scores, reasons and both edition variants")
  func bulkGenerationAndRollback() async throws {
    try await withStore { store, pool, logger in
      let now = Date()
      let suffix = UUID().uuidString.lowercased()
      let keys = (0..<75).map { "bulk-\(suffix)-\($0)" }
      try await seedItems(keys, at: now, pool: pool, logger: logger)
      let accountDID = "did:example:bulk-\(suffix)"
      try await pool.query(
        """
        INSERT INTO wire_talked_accounts (subject_did, handle, status, fetched_at, expires_at)
        VALUES (\(accountDID), 'person.example', 'fresh', \(now), \(now.addingTimeInterval(86400)))
        """, logger: logger)
      try await pool.query(
        """
        INSERT INTO wire_item_mentions
          (source_uri, canonical_key, subject_did, speaker_key_hash, occurred_at, expires_at)
        SELECT 'at://mention/' || key || '/' || speaker, key, \(accountDID),
               'speaker-hash-for-test-' || speaker, \(now), \(now.addingTimeInterval(86400))
        FROM unnest(\(Array(keys.prefix(2)))::text[]) AS key CROSS JOIN generate_series(1, 3) AS speaker
        """, logger: logger)
      var generation = makeGeneration(keys: keys, at: now, feed: "bulk-\(suffix)")
      try await store.commit(generation)
      try await store.recordCycleDuration(milliseconds: 42.5, generationID: generation.generationID)
      let durationRows = try await pool.query(
        """
        SELECT (diagnostics->>'cycleDurationMilliseconds')::double precision,
               (diagnostics->>'candidateCount')::integer
        FROM wire_rank_generations WHERE generation_id = \(generation.generationID)
        """, logger: logger)
      for try await row in durationRows {
        let duration = try row.decode((Double, Int).self)
        #expect(duration.0 == 42.5 && duration.1 == keys.count)
      }

      let rows = try await pool.query(
        """
        SELECT position, canonical_key, score, reason_codes::text
        FROM wire_ranked_items WHERE generation_id = \(generation.generationID)
        ORDER BY position
        """, logger: logger)
      var saved: [(Int, String, Double, String)] = []
      for try await row in rows { saved.append(try row.decode((Int, String, Double, String).self)) }
      #expect(saved.map(\.0) == Array(keys.indices))
      #expect(saved.map(\.1) == keys)
      #expect(saved.map(\.2) == generation.result.items.map(\.score))
      for row in saved {
        #expect(try JSONDecoder().decode([String].self, from: Data(row.3.utf8)) == ["fresh_publication"])
      }
      let moduleRows = try await pool.query(
        """
        SELECT COUNT(*) FILTER (WHERE position < 1000)::bigint,
               COUNT(*) FILTER (WHERE position >= 1000)::bigint
        FROM wire_edition_modules WHERE generation_id = \(generation.generationID)
        """, logger: logger)
      for try await row in moduleRows {
        let counts = try row.decode((Int64, Int64).self)
        #expect(counts.0 > 0)
        #expect(counts.0 == counts.1)
      }
      let accountRows = try await pool.query(
        """
        SELECT position, subject_did FROM wire_edition_talked_accounts
        WHERE generation_id = \(generation.generationID)
        """, logger: logger)
      var accounts: [String] = []
      for try await row in accountRows {
        let account = try row.decode((Int, String).self)
        #expect(account.0 == 0)
        accounts.append(account.1)
      }
      #expect(accounts == [accountDID])
      let publicationRows = try await pool.query(
        """
        SELECT publication_homepage_url, publication_icon_url FROM wire_edition_modules
        WHERE generation_id = \(generation.generationID) AND module_kind = 'publication_spotlight'
        """, logger: logger)
      var publicationCount = 0
      for try await row in publicationRows {
        let publication = try row.decode((String, String).self)
        #expect(publication.0 == "https://publication.example")
        #expect(publication.1 == "https://publication.example/icon.png")
        publicationCount += 1
      }
      #expect(publicationCount > 0)
      let itemRows = try await pool.query(
        """
        SELECT COUNT(*)::bigint
        FROM wire_edition_module_items item
        JOIN wire_ranked_items ranked ON ranked.generation_id = item.generation_id
          AND ranked.canonical_key = item.canonical_key
        WHERE item.generation_id = \(generation.generationID) AND ranked.position >= 50
        """, logger: logger)
      for try await row in itemRows { #expect(try row.decode(Int64.self) == 0) }

      // A failed bulk insert must leave the original active generation and all its edition rows.
      let activeID = generation.generationID
      generation.generationID = UUID()
      generation.result.items[0].candidate.canonicalKey = "missing-\(suffix)"
      await #expect(throws: (any Error).self) { try await store.commit(generation) }
      let stateRows = try await pool.query(
        "SELECT active_generation_id FROM wire_feed_state WHERE feed_key = \(generation.feedKey)",
        logger: logger)
      for try await row in stateRows { #expect(try row.decode(UUID.self) == activeID) }
      let failedRows = try await pool.query(
        "SELECT COUNT(*)::bigint FROM wire_rank_generations WHERE generation_id = \(generation.generationID)",
        logger: logger)
      for try await row in failedRows { #expect(try row.decode(Int64.self) == 0) }

      // Empty shadow results have valid empty SQL arrays and do not replace the active feed.
      generation.generationID = UUID()
      generation.activate = false
      generation.result.items = []
      try await store.commit(generation)
      let emptyRows = try await pool.query(
        "SELECT COUNT(*)::bigint FROM wire_ranked_items WHERE generation_id = \(generation.generationID)",
        logger: logger)
      for try await row in emptyRows { #expect(try row.decode(Int64.self) == 0) }
    }
  }

  @Test("retention drains more than one bounded generation batch and preserves active and unexpired rows")
  func boundedRetention() async throws {
    try await withStore { store, pool, logger in
      let now = Date()
      let feed = "retention-\(UUID().uuidString.lowercased())"
      let expiredIDs = (0..<13).map { _ in UUID() }
      try await pool.query(
        """
        INSERT INTO wire_rank_generations
          (generation_id, feed_key, language_bucket, status, is_active, config_version,
           generated_at, expires_at)
        SELECT id, \(feed), 'und', 'superseded', FALSE, 'test', \(now), \(now.addingTimeInterval(-1))
        FROM unnest(\(expiredIDs)::uuid[]) AS id
        """, logger: logger)
      let activeID = UUID()
      let unexpiredID = UUID()
      try await pool.query(
        """
        INSERT INTO wire_rank_generations
          (generation_id, feed_key, language_bucket, status, is_active, config_version,
           generated_at, expires_at)
        VALUES (\(activeID), \(feed), 'und', 'committed', TRUE, 'test', \(now), \(now.addingTimeInterval(-1))),
               (\(unexpiredID), \(feed), 'und', 'shadow', FALSE, 'test', \(now), \(now.addingTimeInterval(3600)))
        """, logger: logger)
      try await store.deleteExpired(asOf: now, batchSize: 5000)
      let rows = try await pool.query(
        "SELECT generation_id FROM wire_rank_generations WHERE feed_key = \(feed)", logger: logger)
      var remaining = Set<UUID>()
      for try await row in rows { remaining.insert(try row.decode(UUID.self)) }
      #expect(remaining == [activeID, unexpiredID])
    }
  }

  @Test("one-hour retention honors old promises, exact expiry and complete active generations")
  func shorterRetentionTransition() async throws {
    try await withStore { store, pool, logger in
      let start = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
      let suffix = UUID().uuidString.lowercased()
      let feed = "transition-\(suffix)"
      let keys = (0..<20).map { "transition-\(suffix)-\($0)" }
      try await seedItems(keys, at: start, pool: pool, logger: logger)
      let old = makeGeneration(keys: keys, at: start, feed: feed)
      try await store.commit(old)
      var firstNew = makeGeneration(keys: keys, at: start.addingTimeInterval(300), feed: feed)
      firstNew.expiresAt = firstNew.generatedAt.addingTimeInterval(3600)
      try await store.commit(firstNew)
      var active = makeGeneration(keys: keys, at: start.addingTimeInterval(600), feed: feed)
      active.expiresAt = active.generatedAt.addingTimeInterval(3600)
      try await store.commit(active)

      // Changing the configured lifetime must not rewrite older promises or delete early.
      try await store.deleteExpired(asOf: firstNew.expiresAt.addingTimeInterval(-1), batchSize: 5000)
      let beforeRows = try await pool.query(
        "SELECT generation_id, expires_at FROM wire_rank_generations WHERE feed_key = \(feed)",
        logger: logger)
      var before: [UUID: Date] = [:]
      for try await row in beforeRows {
        let value = try row.decode((UUID, Date).self)
        before[value.0] = value.1
      }
      #expect(before == [old.generationID: old.expiresAt,
                         firstNew.generationID: firstNew.expiresAt, active.generationID: active.expiresAt])

      // At the exact new boundary, only the expired superseded generation and its children go.
      try await store.deleteExpired(asOf: firstNew.expiresAt, batchSize: 5000)
      let retainedRows = try await pool.query(
        "SELECT generation_id FROM wire_rank_generations WHERE feed_key = \(feed)", logger: logger)
      var retained = Set<UUID>()
      for try await row in retainedRows { retained.insert(try row.decode(UUID.self)) }
      #expect(retained == [old.generationID, active.generationID])
      let deletedChildren = try await pool.query(
        """
        SELECT (SELECT COUNT(*) FROM wire_ranked_items WHERE generation_id = \(firstNew.generationID)),
               (SELECT COUNT(*) FROM wire_edition_modules WHERE generation_id = \(firstNew.generationID)),
               (SELECT COUNT(*) FROM wire_edition_module_items WHERE generation_id = \(firstNew.generationID))
        """, logger: logger)
      for try await row in deletedChildren {
        let counts = try row.decode((Int64, Int64, Int64).self)
        #expect(counts.0 == 0 && counts.1 == 0 && counts.2 == 0)
      }

      // Even past its own expiry, the complete active edition stays until a replacement commits.
      try await store.deleteExpired(asOf: old.expiresAt, batchSize: 5000)
      let activeRows = try await pool.query(
        """
        SELECT state.active_generation_id,
               (SELECT COUNT(*) FROM wire_rank_generations WHERE feed_key = \(feed)),
               (SELECT COUNT(*) FROM wire_ranked_items WHERE generation_id = state.active_generation_id),
               (SELECT COUNT(*) FROM wire_edition_modules WHERE generation_id = state.active_generation_id),
               (SELECT COUNT(*) FROM wire_edition_module_items WHERE generation_id = state.active_generation_id)
        FROM wire_feed_state state WHERE feed_key = \(feed)
        """, logger: logger)
      for try await row in activeRows {
        let value = try row.decode((UUID, Int64, Int64, Int64, Int64).self)
        #expect(value.0 == active.generationID && value.1 == 1 && value.2 == Int64(keys.count))
        #expect(value.3 > 0 && value.4 > 0)
      }
    }
  }

  @Test("identical metadata refreshes coalesce hourly expiry extensions")
  func metadataNoOp() async throws {
    try await withStore { _, pool, logger in
      let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 3_600) * 3_600 + 60)
      let suffix = UUID().uuidString.lowercased()
      let key = "metadata-\(suffix)"
      try await seedItems([key], at: now, pool: pool, logger: logger)
      let metadata = WireLinkMetadata(
        canonicalURL: "https://\(key).example/item", title: "A Title", description: nil,
        imageURL: nil, siteName: nil, authorName: nil, publishedAt: nil, iconURL: nil,
        etag: nil, lastModified: nil, source: .embeddedCard)
      let cache = PostgresWireLinkMetadataStore(pool: pool, logger: logger)
      try await cache.seedEmbedded(canonicalKey: key, metadata: metadata, asOf: now)
      let originalVersion = try await metadataVersion(key: key, pool: pool, logger: logger)
      try await cache.seedEmbedded(canonicalKey: key, metadata: metadata, asOf: now)
      #expect(try await metadataVersion(key: key, pool: pool, logger: logger) == originalVersion)
      try await cache.seedEmbedded(canonicalKey: key, metadata: metadata, asOf: now.addingTimeInterval(60))
      #expect(try await metadataVersion(key: key, pool: pool, logger: logger) == originalVersion)
      try await cache.seedEmbedded(canonicalKey: key, metadata: metadata, asOf: now.addingTimeInterval(3_600))
      #expect(try await metadataVersion(key: key, pool: pool, logger: logger) != originalVersion)
    }
  }

  private func metadataVersion(key: String, pool: PostgresClient, logger: Logger) async throws -> String? {
    let rows = try await pool.query(
      "SELECT xmin::text FROM wire_link_metadata_cache WHERE canonical_key = \(key)", logger: logger)
    for try await row in rows { return try row.decode(String.self) }
    return nil
  }

  private func makeGeneration(keys: [String], at: Date, feed: String) -> WireGenerationCommit {
    let items = keys.enumerated().map { index, key in
      WireScoredCandidate(
        candidate: WireCandidate(
          canonicalKey: key, canonicalURL: "https://\(key).example/item", representativeURI: nil,
          sourceDomain: "\(key).example", firstSeenAt: at, sourceConfidence: 1),
        score: Double(keys.count - index) / 10,
        reasonCodes: [.freshPublication])
    }
    return WireGenerationCommit(
      generationID: UUID(), feedKey: feed, languageBucket: "und",
      configVersion: WireRankingConfig().version, generatedAt: at,
      expiresAt: at.addingTimeInterval(7200), activate: true,
      result: WireRankingResult(
        items: items,
        diagnostics: WireRankingDiagnostics(
          candidateCount: keys.count, eligibleCount: keys.count, rejectedForAge: 0,
          rejectedForQuality: 0, rejectedForSignalFloor: 0, diversityDeferrals: 0)))
  }

  private func seedItems(_ keys: [String], at: Date, pool: PostgresClient, logger: Logger) async throws {
    try await pool.query(
      """
      INSERT INTO wire_items
        (canonical_key, canonical_url, source_domain, source_name, title, first_seen_at,
         last_seen_at, published_at, expires_at, publication_homepage_url, publication_icon_url)
      SELECT key, 'https://' || key || '.example/item', 'publication.example', 'Source',
             'Story ' || key, \(at), \(at), \(at), \(at.addingTimeInterval(86400)),
             'https://publication.example', 'https://publication.example/icon.png'
      FROM unnest(\(keys)::text[]) AS key
      """, logger: logger)
  }

  private func withStore(
    _ body: (PostgresWireGenerationStore, PostgresClient, Logger) async throws -> Void
  ) async throws {
    let url = try #require(ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"])
    let logger = Logger(label: "wire-bulk-persistence.tests")
    let config = try PostgresWireConfig.make(from: url, logger: logger)
    let pool = PostgresClient(configuration: config, backgroundLogger: logger)
    let runTask = Task { await pool.run() }
    defer { runTask.cancel() }
    try await body(PostgresWireGenerationStore(pool: pool, logger: logger), pool, logger)
  }
}
