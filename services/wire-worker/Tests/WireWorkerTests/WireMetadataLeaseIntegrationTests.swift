import Foundation
import Logging
import PostgresNIO
import Testing

@testable import WireWorkerCore

extension WirePostgresIntegrationTests {
  @Test("metadata outcomes require the current unexpired claim", arguments: ["success", "notModified", "failure"], ["active", "expired", "reclaimed", "renewed"])
  func metadataCompletionLeaseFencing(outcome: String, leaseState: String) async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-metadata-lease.integration")
    let configuration = try PostgresWireConfig.make(from: url, maximumConnections: 4, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let task = Task { await pool.run() }
    defer { task.cancel() }
    let key = "metadata-lease-\(UUID().uuidString.lowercased())"
    // Whole seconds keep deadline-boundary assertions independent of Date's
    // precision conversion to PostgreSQL microseconds.
    let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let store = PostgresWireLinkMetadataStore(pool: pool, logger: logger)
    do {
      try await pool.query(
        """
        INSERT INTO wire_items
          (canonical_key, canonical_url, source_domain, source_name, title,
           language_code, first_seen_at, last_seen_at, expires_at)
        VALUES (\(key), 'https://example.com/article', 'example.com', 'Example',
                'Original title', 'en', \(now), \(now), \(now.addingTimeInterval(86_400)))
        """, logger: logger)
      try await pool.query(
        """
        INSERT INTO wire_link_metadata_cache
          (canonical_key, canonical_url, title, source, status, retry_after, language_checked_at)
        VALUES (\(key), 'https://example.com/article', 'Original title', 'open_graph',
                'pending', \(now.addingTimeInterval(-60)), \(now))
        """, logger: logger)
      let claims = try await store.claimDue(limit: 250, asOf: now)
      let claim = try #require(claims.first { $0.canonicalKey == key })
      let deadline = try #require(claim.leaseExpiresAt)
      #expect(deadline == now.addingTimeInterval(300))
      // Active leases are excluded from both lanes even if another worker polls.
      let activeClaims = try await store.claimDue(limit: 250, asOf: now.addingTimeInterval(1))
      #expect(!activeClaims.contains { $0.canonicalKey == key })
      let completedAt: Date
      var renewedClaim: WireLinkMetadataTarget?
      if leaseState == "active" {
        completedAt = now.addingTimeInterval(60)
      } else if leaseState == "expired" {
        completedAt = deadline
      } else if leaseState == "renewed" {
        // Starting queued work after its old deadline first acquires a fresh
        // fenced lease; a duplicate renewal with the old token loses.
        renewedClaim = try await store.renewClaim(claim, asOf: deadline)
        let renewed = try #require(renewedClaim)
        #expect(renewed.leaseExpiresAt == deadline.addingTimeInterval(300))
        #expect(try await store.renewClaim(claim, asOf: deadline) == nil)
        completedAt = deadline.addingTimeInterval(1)
      } else {
        let laterClaims = try await store.claimDue(limit: 250, asOf: deadline)
        let replacement = try #require(laterClaims.first { $0.canonicalKey == key })
        #expect(replacement.leaseExpiresAt != claim.leaseExpiresAt)
        #expect(try await store.renewClaim(claim, asOf: deadline) == nil)
        completedAt = deadline.addingTimeInterval(1)
      }
      let before = try await metadataLeaseSnapshot(pool: pool, key: key, logger: logger)
      switch outcome {
      case "success":
        try await store.store(
          canonicalKey: key,
          metadata: WireLinkMetadata(
            canonicalURL: "https://example.com/article", title: "Enriched title", description: nil,
            imageURL: nil, siteName: nil, authorName: nil, publishedAt: nil, iconURL: nil,
            etag: "new-etag", lastModified: nil, source: .openGraph),
          asOf: completedAt, leaseExpiresAt: claim.leaseExpiresAt)
      case "notModified":
        try await store.markNotModified(
          canonicalKey: key, etag: "new-etag", lastModified: nil,
          asOf: completedAt, leaseExpiresAt: claim.leaseExpiresAt)
      default:
        try await store.markFailure(
          canonicalKey: key, negative: false,
          asOf: completedAt, leaseExpiresAt: claim.leaseExpiresAt)
      }
      let after = try await metadataLeaseSnapshot(pool: pool, key: key, logger: logger)
      if leaseState != "active" {
        // Includes physical tuple identity: a fenced completion emits no updates
        // to either cache or item, rather than undoing a stale write afterward.
        #expect(after == before)
      } else {
        #expect(after.status == (outcome == "failure" ? "retry" : "fresh"))
        #expect(after.updatedAt == completedAt)
        #expect(after.retryAfter == completedAt.addingTimeInterval(outcome == "failure" ? 900 : 86_400))
        #expect(after.itemTitle == (outcome == "success" ? "Enriched title" : "Original title"))
        #expect(after.failureCount == (outcome == "failure" ? 1 : 0))
      }
      if let renewedClaim {
        try await store.markNotModified(
          canonicalKey: key, etag: "renewal-winner", lastModified: nil,
          asOf: completedAt, leaseExpiresAt: renewedClaim.leaseExpiresAt)
        let winner = try await metadataLeaseSnapshot(pool: pool, key: key, logger: logger)
        #expect(winner.status == "fresh")
        #expect(winner.retryAfter == completedAt.addingTimeInterval(86_400))
        #expect(try await store.renewClaim(renewedClaim, asOf: completedAt) == nil)
      }
    } catch {
      _ = try? await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
      throw error
    }
    try await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
  }


  @Test("concurrent renewals elect one owner and fence the original claim")
  func metadataConcurrentRenewalHasSingleWinner() async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-metadata-renewal-race.integration")
    let configuration = try PostgresWireConfig.make(from: url, maximumConnections: 4, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let task = Task { await pool.run() }
    defer { task.cancel() }
    let key = "metadata-renewal-race-\(UUID().uuidString.lowercased())"
    let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let store = PostgresWireLinkMetadataStore(pool: pool, logger: logger)
    do {
      try await pool.query(
        """
        INSERT INTO wire_items
          (canonical_key, canonical_url, source_domain, source_name, title,
           language_code, first_seen_at, last_seen_at, expires_at)
        VALUES (\(key), 'https://example.com/article', 'example.com', 'Example',
                'Original title', 'en', \(now), \(now), \(now.addingTimeInterval(86_400)))
        """, logger: logger)
      try await pool.query(
        """
        INSERT INTO wire_link_metadata_cache
          (canonical_key, canonical_url, title, source, status, retry_after, language_checked_at)
        VALUES (\(key), 'https://example.com/article', 'Original title', 'open_graph',
                'pending', \(now.addingTimeInterval(-60)), \(now))
        """, logger: logger)
      let claims = try await store.claimDue(limit: 250, asOf: now)
      let original = try #require(claims.first { $0.canonicalKey == key })
      let renewalAt = try #require(original.leaseExpiresAt)
      // Both callers use the same observed ownership and clock. The assertion
      // accepts either winner, without sleeps or relying on executor ordering.
      async let first = store.renewClaim(original, asOf: renewalAt)
      async let second = store.renewClaim(original, asOf: renewalAt)
      let (firstResult, secondResult) = try await (first, second)
      let winners = [firstResult, secondResult].compactMap { $0 }
      #expect(winners.count == 1)
      let winner = try #require(winners.first)
      #expect(winner.leaseExpiresAt == renewalAt.addingTimeInterval(300))
      let completedAt = renewalAt.addingTimeInterval(1)
      let before = try await metadataLeaseSnapshot(pool: pool, key: key, logger: logger)
      try await store.markFailure(
        canonicalKey: key, negative: true, asOf: completedAt,
        leaseExpiresAt: original.leaseExpiresAt)
      let afterLoser = try await metadataLeaseSnapshot(pool: pool, key: key, logger: logger)
      #expect(afterLoser == before)
      try await store.store(
        canonicalKey: key,
        metadata: WireLinkMetadata(
          canonicalURL: "https://example.com/article", title: "Winner title", description: nil,
          imageURL: nil, siteName: nil, authorName: nil, publishedAt: nil, iconURL: nil,
          etag: "winner-etag", lastModified: nil, source: .openGraph),
        asOf: completedAt, leaseExpiresAt: winner.leaseExpiresAt)
      let accepted = try await metadataLeaseSnapshot(pool: pool, key: key, logger: logger)
      #expect(accepted.status == "fresh")
      #expect(accepted.itemTitle == "Winner title")
      #expect(accepted.retryAfter == completedAt.addingTimeInterval(86_400))
      #expect(accepted.failureCount == 0)
      try await store.markNotModified(
        canonicalKey: key, etag: "loser-etag", lastModified: nil,
        asOf: completedAt.addingTimeInterval(1), leaseExpiresAt: original.leaseExpiresAt)
      let afterLateLoser = try await metadataLeaseSnapshot(pool: pool, key: key, logger: logger)
      #expect(afterLateLoser == accepted)
    } catch {
      _ = try? await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
      throw error
    }
    try await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
  }

  @Test("lease tokens survive PostgreSQL fractional timestamp round trips", arguments: [
    "current", "000001", "000002", "000003", "123456", "500001", "999998", "999999",
  ])
  func metadataFractionalLeaseTokens(fraction: String) async throws {
    guard let url = ProcessInfo.processInfo.environment["WIRE_TEST_DATABASE_URL"] else { return }
    let logger = Logger(label: "wire-metadata-fractional-lease.integration")
    let configuration = try PostgresWireConfig.make(from: url, maximumConnections: 4, logger: logger)
    let pool = PostgresClient(configuration: configuration, backgroundLogger: logger)
    let task = Task { await pool.run() }
    defer { task.cancel() }
    let key = "metadata-fractional-lease-\(UUID().uuidString.lowercased())"
    let now = Date()
    let store = PostgresWireLinkMetadataStore(pool: pool, logger: logger)
    let exactTimestamp: String? = fraction == "current" ? nil : "2026-09-12 00:05:00." + fraction + "+00"
    do {
      try await pool.query(
        """
        INSERT INTO wire_items
          (canonical_key, canonical_url, source_domain, source_name, title,
           language_code, first_seen_at, last_seen_at, expires_at)
        VALUES (\(key), 'https://example.com/article', 'example.com', 'Example',
                'Original title', 'en', \(now), \(now), \(now.addingTimeInterval(86_400)))
        """, logger: logger)
      try await pool.query(
        """
        INSERT INTO wire_link_metadata_cache
          (canonical_key, canonical_url, title, source, status, retry_after, language_checked_at)
        VALUES (\(key), 'https://example.com/article', 'Original title', 'open_graph',
                'pending', \(now), \(now))
        """, logger: logger)
      for outcome in ["notModified", "failure", "success", "renew"] {
        // Seed the selected fractions directly in SQL; binding a decoded Date
        // during setup would hide any precision loss in the actual CAS path.
        let rows = try await pool.query(
          """
          UPDATE wire_link_metadata_cache
          SET status = 'fetching', retry_after = COALESCE(\(exactTimestamp)::timestamptz, \(now)),
              failure_count = 0
          WHERE canonical_key = \(key)
          RETURNING retry_after
          """, logger: logger)
        var decoded: Date?
        for try await row in rows { decoded = try row.decode(Date.self) }
        let token = try #require(decoded)
        let target = WireLinkMetadataTarget(
          canonicalKey: key, canonicalURL: "https://example.com/article", etag: nil,
          lastModified: nil, leaseExpiresAt: token)
        let completedAt = token.addingTimeInterval(-100)
        switch outcome {
        case "notModified":
          try await store.markNotModified(
            canonicalKey: key, etag: "fraction-etag", lastModified: nil,
            asOf: completedAt, leaseExpiresAt: token)
        case "failure":
          try await store.markFailure(
            canonicalKey: key, negative: false, asOf: completedAt, leaseExpiresAt: token)
        case "success":
          try await store.store(
            canonicalKey: key,
            metadata: WireLinkMetadata(
              canonicalURL: target.canonicalURL, title: "Fractional title", description: nil,
              imageURL: nil, siteName: nil, authorName: nil, publishedAt: nil, iconURL: nil,
              etag: nil, lastModified: nil, source: .openGraph),
            asOf: completedAt, leaseExpiresAt: token)
        default:
          let renewed = try #require(try await store.renewClaim(target, asOf: completedAt))
          #expect(renewed.leaseExpiresAt != token)
          try await store.markNotModified(
            canonicalKey: key, etag: "fraction-renewal", lastModified: nil,
            asOf: completedAt, leaseExpiresAt: renewed.leaseExpiresAt)
        }
        let snapshot = try await metadataLeaseSnapshot(pool: pool, key: key, logger: logger)
        #expect(snapshot.status == (outcome == "failure" ? "retry" : "fresh"))
      }
    } catch {
      _ = try? await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
      throw error
    }
    try await pool.query("DELETE FROM wire_items WHERE canonical_key = \(key)", logger: logger)
  }
}

private struct MetadataLeaseSnapshot: Equatable {
  let cacheVersion: String
  let status: String
  let retryAfter: Date
  let updatedAt: Date
  let failureCount: Int
  let itemVersion: String
  let itemTitle: String
}

private func metadataLeaseSnapshot(
  pool: PostgresClient, key: String, logger: Logger
) async throws -> MetadataLeaseSnapshot {
  let rows = try await pool.query(
    """
    SELECT cache.xmin::text || ':' || cache.ctid::text, cache.status,
           cache.retry_after, cache.updated_at, cache.failure_count,
           item.xmin::text || ':' || item.ctid::text, item.title
    FROM wire_link_metadata_cache cache JOIN wire_items item USING (canonical_key)
    WHERE cache.canonical_key = \(key)
    """, logger: logger)
  var snapshot: MetadataLeaseSnapshot?
  for try await row in rows {
    let value = try row.decode((String, String, Date, Date, Int, String, String).self)
    snapshot = MetadataLeaseSnapshot(
      cacheVersion: value.0, status: value.1, retryAfter: value.2, updatedAt: value.3,
      failureCount: value.4, itemVersion: value.5, itemTitle: value.6)
  }
  return try #require(snapshot)
}
