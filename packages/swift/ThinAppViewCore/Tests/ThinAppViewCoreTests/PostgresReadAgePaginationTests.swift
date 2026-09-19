import Foundation
import PostgresNIO
import Testing

@testable import ThinAppViewCore

extension PostgresJetstreamInboxIntegrationTests {
  @Test("Larger read-age pages preserve exact PDS snapshots and timestamp ties")
  func largerReadAgePages() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let viewer = "\(fixture.sourceGeneration)-read-viewer"
      let author = "\(fixture.sourceGeneration)-read-author"
      let publication = "at://\(author)/site.standard.publication/main"
      let prefix = "at://\(author)/site.standard.document/"
      let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
      let timestamp = now.addingTimeInterval(-3600)
      let scope = AppViewUnreadCounterSupport.publicationScope(
        viewerDid: viewer, publicationId: publication, authorDid: author,
        publicationAtUri: publication, publicationScopeAtUris: [publication],
        publicationSiteUrls: [], sectionKeys: [])
      func execute(_ query: PostgresQuery) async throws {
        for try await _ in try await fixture.pool.query(query, logger: fixture.logger) {}
      }
      func restoreLegacyAuthority() async throws {
        try await execute("DELETE FROM appview_pds_read_state_exact WHERE viewer_did = \(viewer)")
        try await execute("""
          UPDATE appview_pds_read_state_authority SET manifest = NULL, manifest_cid = NULL
          WHERE viewer_did = \(viewer)
          """)
      }
      do {
        try await execute("""
          INSERT INTO content_items
            (uri, cid, author_did, collection, created_at, indexed_at, publication_site, render_json, expires_at)
          SELECT \(prefix) || lpad(n::text, 4, '0'), 'cid', \(author), 'site.standard.document',
            \(timestamp), \(now), \(publication),
            jsonb_build_object('title', 'entry-' || n,
              'publishedAt', CASE WHEN n % 3 = 0 THEN 'malformed' ELSE \(ISO8601DateFormatter().string(from: now))::text END,
              'articleUrl', 'https://example.com/shared', 'summary', repeat('large display payload ', 1000)),
            \(now.addingTimeInterval(3600))
          FROM generate_series(1, 1007) AS n
          """)
        // An active PDS generation must override the retained legacy floor on every page.
        try await execute("""
          INSERT INTO appview_publication_read_floors
            (viewer_did, publication_id, read_floor_at, read_floor_uri, generation, updated_at)
          VALUES (\(viewer), \(publication), \(now), NULL, 1, \(now))
          """)
        try await execute("""
          UPDATE appview_pds_read_state_authority
          SET manifest = '{}'::jsonb, manifest_cid = 'wide-read-age-fixture', projection_ready = TRUE
          WHERE viewer_did = \(viewer)
          """)
        try await execute("""
          INSERT INTO appview_pds_read_state_exact (viewer_did, subject_uri, sequence, is_read, acted_at)
          VALUES (\(viewer), \(prefix + "0001"), 1, TRUE, \(now))
          """)
        func snapshot(limit: Int) async throws -> [UnreadReadMutationEntry] {
          var cursor: String?
          var entries: [UnreadReadMutationEntry] = []
          repeat {
            let page = try await fixture.store.listUnreadEntriesForReadMutation(
              viewerDid: viewer, scopes: [scope], cursor: cursor, limit: limit)
            entries.append(contentsOf: page.entries)
            cursor = page.cursor
          } while cursor != nil
          return entries
        }
        let original = try await snapshot(limit: 100)
        let larger = try await snapshot(limit: 1000)
        #expect(larger == original)
        #expect(larger.count == 1006)
        #expect(Set(larger.map(\.entryId)).count == 1006)
        #expect(larger.allSatisfy { $0.feedPositionAt == timestamp && $0.publicationId == publication })
        #expect(larger.first { $0.entryId == prefix + "0003" }?.publishedAt == timestamp)
        #expect(larger.first { $0.entryId == prefix + "0002" }?.publishedAt == now)
        let capped = try await fixture.store.listUnreadEntriesForReadMutation(
          viewerDid: viewer, scopes: [scope], cursor: nil, limit: 10_000)
        #expect(capped.entries.count == 1000)
        #expect(capped.entries == Array(larger.prefix(1000)))
        #expect(ThinAppViewCursor.decode(try #require(capped.cursor))?.uri == prefix + "0008")
      } catch {
        try? await restoreLegacyAuthority()
        throw error
      }
      try await restoreLegacyAuthority()
    }
  }
}
