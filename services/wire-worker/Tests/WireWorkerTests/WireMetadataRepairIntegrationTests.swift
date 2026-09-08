import Foundation
import Logging
import PostgresNIO
import Testing
import WireCore

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("metadata repair bounds cached scans, persists progress and skips a locked cursor")
  func metadataRepairBoundsAndProgress() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-metadata-repair.integration")
    let pool = PostgresClient(
      configuration: try PostgresWireConfig.make(from: url, maximumConnections: 4, logger: logger),
      backgroundLogger: logger)
    let task = Task { await pool.run() }
    defer { task.cancel() }
    let prefix = "!repair-\(UUID().uuidString.lowercased())-"
    let now = Date()
    let store = PostgresWireLinkMetadataStore(pool: pool, logger: logger)
    try await pool.query(
      """
      INSERT INTO wire_items
        (canonical_key, canonical_url, source_domain, source_name, title, language_code, first_seen_at, last_seen_at, expires_at)
      SELECT \(prefix) || LPAD(n::text, 5, '0'),
        'https://example.com/' || \(prefix) || n, 'example.com', 'Example', 'Story', 'en', \(now), \(now),
        \(now.addingTimeInterval(86_400)) FROM generate_series(1, 20000) n
      """, logger: logger)
    do {
      try await pool.query(
        """
        INSERT INTO wire_link_metadata_cache (canonical_key, canonical_url, source, status, retry_after)
        SELECT canonical_key, canonical_url, 'open_graph', 'fresh', \(now.addingTimeInterval(86_400))
        FROM wire_items WHERE canonical_key LIKE \(prefix + "%")
          AND canonical_key <> \(prefix + "20000")
        """, logger: logger)
      try await pool.query(
        "UPDATE wire_metadata_repair_cursor SET canonical_key = \(prefix) WHERE singleton",
        logger: logger)
      try await pool.query("ANALYZE wire_items", logger: logger)
      try await pool.query("ANALYZE wire_link_metadata_cache", logger: logger)
      // All 1,000 candidates exist. The cursor still advances, and the actual
      // production SQL must use bounded primary-key probes without a sort/scan.
      let query = PostgresWireLinkMetadataStore.metadataRepairQuery(asOf: now, pageSize: 1_000)
      let explained = try await pool.query(
        PostgresQuery(unsafeSQL: "EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) " + query.sql, binds: query.binds),
        logger: logger)
      var plan = ""
      for try await row in explained { plan += try row.decode(String.self) + "\n" }
      #expect(plan.contains("Index Scan using wire_items_pkey"))
      #expect(!plan.contains("Seq Scan on wire_items"))
      #expect(!plan.contains("Seq Scan on wire_link_metadata_cache"))
      #expect(!plan.contains("temp read="))
      #expect(!plan.contains("temp written="))
      print("Bounded metadata repair plan:\n\(plan)")
      for try await row in try await pool.query(
        "SELECT canonical_key FROM wire_metadata_repair_cursor WHERE singleton", logger: logger)
      { #expect(try row.decode(String.self) == prefix + "01000") }

      try await pool.withTransaction(logger: logger) { connection in
        try await connection.query(
          "SELECT canonical_key FROM wire_metadata_repair_cursor WHERE singleton FOR UPDATE", logger: logger)
        try await store.repairMissingMetadata(asOf: now)
        for try await row in try await connection.query(
          "SELECT canonical_key FROM wire_metadata_repair_cursor WHERE singleton", logger: logger)
        { #expect(try row.decode(String.self) == prefix + "01000") }
      }
      // A new store has no in-memory cursor and resumes from the persisted page.
      let restarted = PostgresWireLinkMetadataStore(pool: pool, logger: logger)
      for _ in 0..<19 { try await restarted.repairMissingMetadata(asOf: now) }
      for try await row in try await pool.query(
        "SELECT source FROM wire_link_metadata_cache WHERE canonical_key = \(prefix + "20000")",
        logger: logger)
      { #expect(try row.decode(String.self) == "fallback") }
      // An empty tail wraps. A hole behind the cursor is repaired next pass.
      try await pool.query(
        "UPDATE wire_metadata_repair_cursor SET canonical_key = (SELECT MAX(canonical_key) FROM wire_items) WHERE singleton", logger: logger)
      try await restarted.repairMissingMetadata(asOf: now)
      for try await row in try await pool.query(
        "SELECT canonical_key FROM wire_metadata_repair_cursor WHERE singleton", logger: logger)
      { #expect(try row.decode(String.self) == "") }
      try await pool.query(
        "DELETE FROM wire_link_metadata_cache WHERE canonical_key = \(prefix + "00001")", logger: logger)
      enum Rollback: Error { case requested }
      do {
        try await pool.withTransaction(logger: logger) { connection in
          try await connection.query(
            PostgresWireLinkMetadataStore.metadataRepairQuery(asOf: now, pageSize: 1_000), logger: logger)
          throw Rollback.requested
        }
      } catch let error as PostgresTransactionError {
        #expect(error.closureError is Rollback)
        #expect(error.rollbackError == nil)
      }
      for try await row in try await pool.query(
        "SELECT canonical_key FROM wire_metadata_repair_cursor WHERE singleton", logger: logger)
      { #expect(try row.decode(String.self) == "") }
      for try await row in try await pool.query(
        "SELECT COUNT(*) FROM wire_link_metadata_cache WHERE canonical_key = \(prefix + "00001")", logger: logger)
      { #expect(try row.decode(Int64.self) == 0) }
      try await restarted.repairMissingMetadata(asOf: now)
      for try await row in try await pool.query(
        "SELECT COUNT(*) FROM wire_link_metadata_cache WHERE canonical_key = \(prefix + "00001")",
        logger: logger)
      { #expect(try row.decode(Int64.self) == 1) }
    } catch {
      _ = try? await pool.query("DELETE FROM wire_items WHERE canonical_key LIKE \(prefix + "%")", logger: logger)
      throw error
    }
    try await pool.query("DELETE FROM wire_items WHERE canonical_key LIKE \(prefix + "%")", logger: logger)
    try await pool.query("UPDATE wire_metadata_repair_cursor SET canonical_key = '' WHERE singleton", logger: logger)
  }

  @Test("metadata repair respects eligibility and embedded metadata outranks fallback only")
  func metadataRepairEligibilityAndEmbeddedPrecedence() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-metadata-repair-precedence.integration")
    let pool = PostgresClient(
      configuration: try PostgresWireConfig.make(from: url, logger: logger), backgroundLogger: logger)
    let task = Task { await pool.run() }
    defer { task.cancel() }
    let prefix = "!repair-precedence-\(UUID().uuidString.lowercased())-"
    let now = Date()
    let store = PostgresWireLinkMetadataStore(pool: pool, logger: logger)
    let names = ["active", "expired", "ineligible", "http"]
    for name in names {
      try await pool.query(
        """
        INSERT INTO wire_items
          (canonical_key, canonical_url, source_domain, source_name, title, eligible, first_seen_at, last_seen_at, expires_at)
        VALUES (\(prefix + name), \((name == "http" ? "http" : "https") + "://example.com/" + prefix + name),
          'example.com', 'Example', 'Story', \(name != "ineligible"), \(now), \(now),
          \(now.addingTimeInterval(name == "expired" ? -60 : 86_400)))
        """, logger: logger)
    }
    do {
      try await pool.query(
        "UPDATE wire_metadata_repair_cursor SET canonical_key = \(prefix) WHERE singleton", logger: logger)
      try await store.repairMissingMetadata(asOf: now)
      var keys: [String] = []
      for try await row in try await pool.query(
        "SELECT canonical_key FROM wire_link_metadata_cache WHERE canonical_key LIKE \(prefix + "%")",
        logger: logger) { keys.append(try row.decode(String.self)) }
      #expect(keys == [prefix + "active"])
      let embedded = WireLinkMetadata(
        canonicalURL: "https://example.com/" + prefix + "active", title: "Embedded title",
        description: nil, imageURL: nil, siteName: "Embedded site", authorName: nil,
        publishedAt: nil, iconURL: "https://example.com/icon.png", etag: nil, lastModified: nil, source: .embeddedCard)
      try await store.seedEmbedded(canonicalKey: prefix + "active", metadata: embedded, asOf: now)
      for try await row in try await pool.query(
        "SELECT source, title, site_name, icon_url FROM wire_link_metadata_cache WHERE canonical_key = \(prefix + "active")",
        logger: logger) {
        let value = try row.decode((String, String, String, String).self)
        #expect(value.0 == "embedded_card")
        #expect(value.1 == "Embedded title")
        #expect(value.2 == "Embedded site")
        #expect(value.3 == "https://example.com/icon.png")
      }
      try await pool.query(
        """
        UPDATE wire_link_metadata_cache SET source = 'open_graph', status = 'fresh', title = 'Fetched title',
          site_name = 'Fetched site', icon_url = 'https://example.com/fetched-icon.png',
          fresh_until = \(now.addingTimeInterval(3_600)), stale_until = \(now.addingTimeInterval(86_400))
        WHERE canonical_key = \(prefix + "active")
        """, logger: logger)
      try await store.seedEmbedded(canonicalKey: prefix + "active", metadata: embedded, asOf: now)
      for try await row in try await pool.query(
        "SELECT source, title, status, site_name, icon_url FROM wire_link_metadata_cache WHERE canonical_key = \(prefix + "active")",
        logger: logger) {
        let value = try row.decode((String, String, String, String, String).self)
        #expect(value.0 == "open_graph")
        #expect(value.1 == "Fetched title")
        #expect(value.2 == "fresh")
        #expect(value.3 == "Fetched site")
        #expect(value.4 == "https://example.com/fetched-icon.png")
      }
      // Expiry cleanup retains active metadata so it refreshes normally instead
      // of discarding useful content and repeatedly seeding another fallback.
      try await pool.query(
        """
        UPDATE wire_link_metadata_cache SET fresh_until = \(now.addingTimeInterval(-120)),
          stale_until = \(now.addingTimeInterval(-60)) WHERE canonical_key = \(prefix + "active")
        """, logger: logger)
      try await PostgresWireTalkedAccountMentionStore(pool: pool, logger: logger).pruneExpired(asOf: now)
      for try await row in try await pool.query(
        "SELECT COUNT(*) FROM wire_link_metadata_cache WHERE canonical_key = \(prefix + "active")", logger: logger)
      { #expect(try row.decode(Int64.self) == 1) }
    } catch {
      _ = try? await pool.query("DELETE FROM wire_items WHERE canonical_key LIKE \(prefix + "%")", logger: logger)
      throw error
    }
    try await pool.query("DELETE FROM wire_items WHERE canonical_key LIKE \(prefix + "%")", logger: logger)
    try await pool.query("UPDATE wire_metadata_repair_cursor SET canonical_key = '' WHERE singleton", logger: logger)
  }
}

extension WirePostgresIntegrationTests {
  @Test("failed metadata seed rolls back item write and preserves inbox for retry")
  func metadataSeedAndItemWriteAreAtomic() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-metadata-seed-atomic.integration")
    let pool = PostgresClient(
      configuration: try PostgresWireConfig.make(from: url, logger: logger), backgroundLogger: logger)
    let task = Task { await pool.run() }
    defer { task.cancel() }
    let suffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    let environment = "metadata-atomic-" + suffix
    let articleURL = "https://example.com/atomic/" + suffix
    let canonical = try #require(WireCanonicalizer.canonicalize(articleURL))
    let constraint = "metadata_atomic_" + suffix
    let now = Date()
    let payload = """
      {"commit":{"record":{"$type":"app.bsky.feed.post","text":"Article","embed":{"external":{"uri":"\(articleURL)","title":"Article"}}}}}
      """
    // Only the generated synthetic key is rejected. NOT VALID leaves unrelated
    // fixtures untouched while enforcing the constraint for this new write.
    let escapedKey = canonical.canonicalKey.replacingOccurrences(of: "'", with: "''")
    try await pool.query(PostgresQuery(unsafeSQL:
      "ALTER TABLE wire_link_metadata_cache ADD CONSTRAINT \(constraint) CHECK (canonical_key <> '\(escapedKey)') NOT VALID"), logger: logger)
    do {
      try await pool.query(
        """
        INSERT INTO wire_ingestion_inbox
          (environment, source_generation, seq, source_host, cursor_kind, event_kind, repo_did,
           collection, operation, repo_rev, record_key, payload, event_time)
        VALUES (\(environment), 'atomic-v1', 1, 'test', 'jetstream_v2_seq', 'commit',
          \("did:plc:" + suffix), 'app.bsky.feed.post', 'create', 'one', 'post', \(payload)::jsonb, \(now))
        """, logger: logger)
      let processor = try PostgresWireInboxProcessor(
        pool: pool, logger: logger, actorSecret: String(repeating: "s", count: 32),
        sourceScope: WireInboxSourceScope(environment: environment, sourceGenerations: ["atomic-v1"]))
      let failed = try await processor.processWithMetrics(asOf: now.addingTimeInterval(1))
      #expect(failed.appliedEventCount == 0)
      for try await row in try await pool.query(
        "SELECT COUNT(*) FROM wire_items WHERE canonical_key = \(canonical.canonicalKey)", logger: logger)
      { #expect(try row.decode(Int64.self) == 0) }
      for try await row in try await pool.query(
        "SELECT status FROM wire_ingestion_inbox WHERE environment = \(environment)", logger: logger)
      { #expect(try row.decode(String.self) == "retry") }
      try await pool.query(PostgresQuery(unsafeSQL:
        "ALTER TABLE wire_link_metadata_cache DROP CONSTRAINT \(constraint)"), logger: logger)
      let recovered = try await processor.processWithMetrics(asOf: now.addingTimeInterval(3_600))
      #expect(recovered.appliedEventCount == 1)
      for try await row in try await pool.query(
        """
        SELECT COUNT(*) FROM wire_items item JOIN wire_link_metadata_cache cache USING (canonical_key)
        WHERE item.canonical_key = \(canonical.canonicalKey) AND cache.source = 'embedded_card'
        """, logger: logger)
      { #expect(try row.decode(Int64.self) == 1) }
    } catch {
      _ = try? await pool.query(PostgresQuery(unsafeSQL:
        "ALTER TABLE wire_link_metadata_cache DROP CONSTRAINT IF EXISTS \(constraint)"), logger: logger)
      _ = try? await pool.query("DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)", logger: logger)
      _ = try? await pool.query("DELETE FROM wire_items WHERE canonical_key = \(canonical.canonicalKey)", logger: logger)
      throw error
    }
    try await pool.query("DELETE FROM wire_ingestion_inbox WHERE environment = \(environment)", logger: logger)
    try await pool.query("DELETE FROM wire_items WHERE canonical_key = \(canonical.canonicalKey)", logger: logger)
    let actorHash = try WireActorHasher(secret: Data(String(repeating: "s", count: 32).utf8)).hash("did:plc:" + suffix)
    try await pool.query("DELETE FROM wire_active_actors WHERE actor_key_hash = \(actorHash)", logger: logger)
  }
}
