import Foundation
import Logging
import PostgresNIO
import Testing

@testable import WireWorkerCore

@Suite(
  "Wire embedded metadata writes",
  .serialized,
  .enabled(
    if: ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] != nil,
    "Requires an explicitly disposable migrated PostgreSQL database."
  )
)
struct WireEmbeddedMetadataWriteIntegrationTests {
  @Test("one hundred unchanged mentions avoid row versions while expiry and improvements still advance")
  func coalescesRepeatedMentions() async throws {
    try await withMetadata { store, pool, logger, key, now in
      let metadata = Self.metadata(key: key)
      try await store.seedEmbedded(canonicalKey: key, metadata: metadata, asOf: now)
      let original = try await snapshot(key: key, pool: pool, logger: logger)
      var changedRows = 0
      for offset in 1...100 {
        try await store.seedEmbedded(
          canonicalKey: key, metadata: metadata, asOf: now.addingTimeInterval(Double(offset)))
        let repeated = try await snapshot(key: key, pool: pool, logger: logger)
        if repeated.version != original.version { changedRows += 1 }
        #expect(repeated.version == original.version)
        #expect(repeated.retryAfter == original.retryAfter)
        #expect(repeated.updatedAt == original.updatedAt)
      }
      let nextHour = now.addingTimeInterval(3_600)
      try await store.seedEmbedded(canonicalKey: key, metadata: metadata, asOf: nextHour)
      let renewed = try await snapshot(key: key, pool: pool, logger: logger)
      #expect(renewed.version != original.version)
      let expiry = try #require(renewed.staleUntil)
      let minimumExpiry = nextHour.addingTimeInterval(7 * 86_400)
      #expect(expiry >= minimumExpiry && expiry.timeIntervalSince(minimumExpiry) < 3_600)
      #expect(renewed.retryAfter == original.retryAfter)
      let improved = Self.metadata(key: key, title: "Improved title")
      try await store.seedEmbedded(canonicalKey: key, metadata: improved, asOf: nextHour.addingTimeInterval(1))
      let changed = try await snapshot(key: key, pool: pool, logger: logger)
      #expect(changed.version != renewed.version && changed.title == "Improved title")
      #expect(changed.staleUntil == renewed.staleUntil)
      #expect(changed.retryAfter == original.retryAfter)
      // An older mention cannot shorten expiry or rewind a previously established schedule.
      try await store.seedEmbedded(canonicalKey: key, metadata: improved, asOf: now.addingTimeInterval(-86_400))
      #expect(try await snapshot(key: key, pool: pool, logger: logger).version == changed.version)
      print("Embedded metadata replay: 100 unchanged mentions, \(changedRows) changed row versions; hourly expiry and material improvement each changed one row.")
    }
  }

  @Test("embedded mentions preserve established fetch leases and retry deadlines", arguments: [
    "pending", "fetching", "retry", "negative", "fresh", "stale", "failed",
  ])
  func preservesFetchScheduling(status: String) async throws {
    try await withMetadata { store, pool, logger, key, now in
      let metadata = Self.metadata(key: key)
      try await store.seedEmbedded(canonicalKey: key, metadata: metadata, asOf: now)
      let deadline = now.addingTimeInterval(6 * 3_600)
      let freshUntil = now.addingTimeInterval(3_600)
      try await pool.query(
        """
        UPDATE wire_link_metadata_cache SET status = \(status), retry_after = \(deadline),
          fresh_until = \(freshUntil), failure_count = 3 WHERE canonical_key = \(key)
        """, logger: logger)
      let original = try await snapshot(key: key, pool: pool, logger: logger)
      try await store.seedEmbedded(canonicalKey: key, metadata: metadata, asOf: now.addingTimeInterval(60))
      #expect(try await snapshot(key: key, pool: pool, logger: logger).version == original.version)
      try await store.seedEmbedded(
        canonicalKey: key, metadata: Self.metadata(key: key, title: "New embedded title"),
        asOf: now.addingTimeInterval(120))
      let improved = try await snapshot(key: key, pool: pool, logger: logger)
      #expect(improved.title == "New embedded title" && improved.version != original.version)
      #expect(improved.status == status && improved.retryAfter == deadline)
      #expect(improved.freshUntil == freshUntil && improved.failureCount == 3)
    }
  }

  @Test("missing legacy schedules are initialized once without discarding backoff state")
  func initializesMissingSchedule() async throws {
    try await withMetadata { store, pool, logger, key, now in
      let metadata = Self.metadata(key: key)
      try await store.seedEmbedded(canonicalKey: key, metadata: metadata, asOf: now)
      try await pool.query(
        "UPDATE wire_link_metadata_cache SET retry_after = NULL, failure_count = 2 WHERE canonical_key = \(key)",
        logger: logger)
      let unscheduled = try await snapshot(key: key, pool: pool, logger: logger)
      let scheduledAt = now.addingTimeInterval(60)
      try await store.seedEmbedded(canonicalKey: key, metadata: metadata, asOf: scheduledAt)
      let scheduled = try await snapshot(key: key, pool: pool, logger: logger)
      #expect(scheduled.version != unscheduled.version && scheduled.retryAfter == scheduledAt)
      #expect(scheduled.status == "pending" && scheduled.failureCount == 2)
      try await store.seedEmbedded(canonicalKey: key, metadata: metadata, asOf: scheduledAt.addingTimeInterval(60))
      #expect(try await snapshot(key: key, pool: pool, logger: logger).version == scheduled.version)
    }
  }

  @Test("fetched metadata retains every protected field and its refresh schedule")
  func preservesFetchedPrecedence() async throws {
    try await withMetadata { store, pool, logger, key, now in
      try await store.seedEmbedded(canonicalKey: key, metadata: Self.metadata(key: key), asOf: now)
      let deadline = now.addingTimeInterval(86_400)
      try await pool.query(
        """
        UPDATE wire_link_metadata_cache SET source = 'open_graph', status = 'fresh',
          title = 'Fetched title', description = 'Fetched description', image_url = 'https://example.com/fetched.png',
          author_name = 'Fetched author', published_at = \(now), site_name = 'Fetched site',
          icon_url = 'https://example.com/fetched-icon.png', retry_after = \(deadline),
          fresh_until = \(deadline), language_code = 'en', language_checked_at = \(now)
        WHERE canonical_key = \(key)
        """, logger: logger)
      let original = try await snapshot(key: key, pool: pool, logger: logger)
      let metadata = Self.metadata(key: key, title: "Conflicting embedded title")
      try await store.seedEmbedded(canonicalKey: key, metadata: metadata, asOf: now.addingTimeInterval(60))
      #expect(try await snapshot(key: key, pool: pool, logger: logger).version == original.version)
      try await store.seedEmbedded(canonicalKey: key, metadata: metadata, asOf: now.addingTimeInterval(3_600))
      let renewed = try await snapshot(key: key, pool: pool, logger: logger)
      #expect(renewed.fields == original.fields && renewed.source == "open_graph")
      #expect(renewed.status == "fresh" && renewed.retryAfter == deadline && renewed.freshUntil == deadline)
      #expect(renewed.version != original.version)
    }
  }

  private static func metadata(key: String, title: String = "Embedded title") -> WireLinkMetadata {
    WireLinkMetadata(
      canonicalURL: "https://example.com/" + key, title: title, description: "Embedded description",
      imageURL: "https://example.com/embedded.png", siteName: "Embedded site", authorName: "Embedded author",
      publishedAt: Date(timeIntervalSince1970: 1_700_000_000), iconURL: "https://example.com/embedded-icon.png",
      etag: nil, lastModified: nil, source: .embeddedCard)
  }

  private func snapshot(key: String, pool: PostgresClient, logger: Logger) async throws
    -> (version: String, status: String, source: String, retryAfter: Date?, freshUntil: Date?,
        staleUntil: Date?, failureCount: Int, updatedAt: Date, title: String?, fields: String)
  {
    let rows = try await pool.query(
      """
      SELECT xmin::text || ':' || ctid::text, status, source, retry_after, fresh_until, stale_until,
        failure_count, updated_at, title,
        jsonb_build_array(canonical_url, title, description, image_url, site_name, author_name,
          published_at, icon_url, language_code, language_checked_at, fetched_at, etag, last_modified)::text
      FROM wire_link_metadata_cache WHERE canonical_key = \(key)
      """, logger: logger)
    var value: (String, String, String, Date?, Date?, Date?, Int, Date, String?, String)?
    for try await row in rows {
      value = try row.decode((String, String, String, Date?, Date?, Date?, Int, Date, String?, String).self)
    }
    return try #require(value)
  }

  private func withMetadata(
    _ body: (PostgresWireLinkMetadataStore, PostgresClient, Logger, String, Date) async throws -> Void
  ) async throws {
    let url = try #require(ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"])
    let logger = Logger(label: "wire-embedded-metadata-writes.tests")
    let pool = PostgresClient(
      configuration: try PostgresWireConfig.make(from: url, maximumConnections: 4, logger: logger),
      backgroundLogger: logger)
    let running = Task { await pool.run() }
    defer { running.cancel() }
    let key = "embedded-writes-" + UUID().uuidString.lowercased()
    let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 3_600) * 3_600 + 60)
    try await pool.query(
      """
      INSERT INTO wire_items
        (canonical_key, canonical_url, source_domain, source_name, title, first_seen_at, last_seen_at, expires_at)
      VALUES (\(key), \("https://example.com/" + key), 'example.com', 'Example', 'Story', \(now), \(now),
        \(now.addingTimeInterval(14 * 86_400)))
      """, logger: logger)
    do {
      try await body(PostgresWireLinkMetadataStore(pool: pool, logger: logger), pool, logger, key, now)
    } catch {
      _ = try? await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
      throw error
    }
    try await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
  }
}
