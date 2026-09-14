import Foundation
import PostgresNIO
import Testing

@testable import ThinAppViewCore

@Suite("Postgres feed pagination", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["THIN_APPVIEW_TEST_DATABASE_URL"] != nil))
struct PostgresFeedIntegrationTests {
  @Test("late hydration preserves deduplication, read precedence, cursor ties, and empty feeds")
  func lateHydrationParity() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let viewer = "\(fixture.sourceGeneration)-read-viewer"
      let author = "\(fixture.sourceGeneration)-read-author"
      let publication = "at://\(author)/site.standard.publication/main"
      let wildcardPublication = "at://\(author)/site.standard.publication/wildcard"
      let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
      let timestamp = now.addingTimeInterval(-100)
      let prefix = "at://\(author)/site.standard.document/"
      func uri(_ key: String) -> String { prefix + key }
      func execute(_ query: PostgresQuery) async throws {
        for try await _ in try await fixture.pool.query(query, logger: fixture.logger) {}
      }
      // The inbox fixture supplies the common read tables. Install only the two feed tables it
      // does not need, using the same lock so this also runs against its minimal CI schema.
      try await fixture.pool.withTransaction(logger: fixture.logger) { connection in
        try await connection.query(
          "SELECT pg_advisory_xact_lock(hashtextextended('thin-appview-test-schema', 0))",
          logger: fixture.logger)
        try await connection.query("""
          CREATE TABLE IF NOT EXISTS appview_publication_scope_keys (
            viewer_did TEXT NOT NULL, publication_id TEXT NOT NULL, author_did TEXT NOT NULL,
            scope_key TEXT NOT NULL, PRIMARY KEY (viewer_did, publication_id, scope_key)
          )
          """, logger: fixture.logger)
        try await connection.query("""
          CREATE TABLE IF NOT EXISTS appview_feed_publications (
            viewer_did TEXT NOT NULL, feed_kind TEXT NOT NULL, feed_id TEXT NOT NULL,
            publication_id TEXT NOT NULL,
            PRIMARY KEY (viewer_did, feed_kind, feed_id, publication_id)
          )
          """, logger: fixture.logger)
      }
      do {
        try await execute("""
          INSERT INTO appview_viewer_feeds (viewer_did, feed_kind, feed_id, updated_at)
          VALUES (\(viewer), 'subscribed', '', \(now)), (\(viewer), 'folder', 'empty', \(now))
          """)
        // A scoped author and a wildcard author exercise both matched_content branches.
        for (id, scopedAuthor, key) in [(publication, author, publication),
          (wildcardPublication, author + "-wild", "")] {
          try await execute("""
            INSERT INTO appview_publication_scopes
              (viewer_did, publication_id, author_did, publication_at_uri, scope_keys, updated_at)
            VALUES (\(viewer), \(id), \(scopedAuthor), \(id), jsonb_build_array(\(key)::text), \(now))
            """)
          try await execute("""
            INSERT INTO appview_publication_scope_keys (viewer_did, publication_id, author_did, scope_key)
            VALUES (\(viewer), \(id), \(scopedAuthor), \(key))
            ON CONFLICT (viewer_did, publication_id, scope_key) DO NOTHING
            """)
          try await execute("""
            INSERT INTO appview_feed_publications (viewer_did, feed_kind, feed_id, publication_id)
            VALUES (\(viewer), 'subscribed', '', \(id))
            """)
        }
        let records: [(String, Int, String?, String, Date)] = [
          ("new-duplicate", 60, "https://example.com/shared", author, now.addingTimeInterval(3600)),
          ("old-duplicate", 50, "https://example.com/shared", author, now.addingTimeInterval(3600)),
          ("b", 40, nil, author, now.addingTimeInterval(3600)),
          ("a", 40, "", author, now.addingTimeInterval(3600)),
          ("override", 30, nil, author, now.addingTimeInterval(3600)),
          ("old", 20, nil, author, now.addingTimeInterval(3600)),
          ("wild", 10, nil, author + "-wild", now.addingTimeInterval(3600)),
          ("expired", 70, nil, author, now.addingTimeInterval(-1)),
          ("outside", 80, nil, author + "-outside", now.addingTimeInterval(3600)),
        ]
        let summary = String(repeating: "Full selected row payload. ", count: 2048) + "End."
        for (key, offset, articleURL, recordAuthor, expiresAt) in records {
          let render = ContentRenderFields(title: key,
            publishedAt: ISO8601DateFormatter().string(from: timestamp), summary: summary,
            thumbnailUrl: "https://example.com/\(key).jpg", articleUrl: articleURL)
          let json = String(decoding: try JSONEncoder().encode(render), as: UTF8.self)
          try await execute("""
            INSERT INTO content_items
              (uri, cid, author_did, collection, created_at, indexed_at, publication_site, render_json, expires_at)
            VALUES (\(uri(key)), 'cid', \(recordAuthor), 'site.standard.document',
              \(timestamp.addingTimeInterval(Double(offset))), \(now), \(publication), \(json)::jsonb, \(expiresAt))
            """)
        }
        try await execute("""
          INSERT INTO read_marks (viewer_did, subject_uri, created_at)
          VALUES (\(viewer), \(uri("new-duplicate")), \(now)), (\(viewer), \(uri("override")), \(now))
          """)
        try await execute("""
          INSERT INTO appview_unread_overrides (viewer_did, subject_uri, created_at)
          VALUES (\(viewer), \(uri("override")), \(now))
          """)
        try await execute("""
          INSERT INTO appview_publication_read_floors
            (viewer_did, publication_id, read_floor_at, read_floor_uri, generation, updated_at)
          VALUES (\(viewer), \(publication), \(timestamp.addingTimeInterval(40)), \(uri("a")), 1, \(now))
          """)
        let selector = AppViewFeedSelector(kind: .subscribed)
        for (filter, expected) in [
          (EntryListFilter.all, ["new-duplicate", "b", "a", "override", "old", "wild"]),
          (.unread, ["b", "override", "wild"]),
          (.read, ["new-duplicate", "a", "old"]),
        ] {
          let page = try #require(try await AppViewFeedQueryDeadline.$current.withValue(.init()) {
            try await fixture.store.listFeedEntries(
              viewerDid: viewer, selector: selector, filter: filter, cursor: nil, limit: 100)
          })
          #expect(page.membershipUpdatedAt == now)
          #expect(page.response.entries.map(\.entryId) == expected.map(uri))
          #expect(page.response.cursor == nil)
          for entry in page.response.entries {
            #expect(entry.summary == summary)
            #expect(entry.thumbnailUrl == "https://example.com/\(entry.title).jpg")
            #expect(entry.publicationId == (entry.title == "wild" ? wildcardPublication : publication))
            #expect(entry.isRead == ["new-duplicate", "a", "old"].contains(entry.title))
          }
        }
        let first = try #require(try await fixture.store.listFeedEntries(
          viewerDid: viewer, selector: selector, filter: .all, cursor: nil, limit: 2))
        #expect(first.response.entries.map(\.entryId) == [uri("new-duplicate"), uri("b")])
        let cursor = try #require(first.response.cursor)
        #expect(ThinAppViewCursor.decode(cursor)?.uri == uri("b"))
        let second = try #require(try await fixture.store.listFeedEntries(
          viewerDid: viewer, selector: selector, filter: .all, cursor: cursor, limit: 2))
        #expect(second.response.entries.map(\.entryId) == [uri("a"), uri("override")])
        // The existing contract applies the cursor before deduplication. Preserve that boundary:
        // an older copy below a cursor can be the winning copy for the next page.
        let duplicateCursor = ThinAppViewCursor.encode(
          createdAt: timestamp.addingTimeInterval(60), uri: uri("new-duplicate"))
        let belowDuplicate = try #require(try await fixture.store.listFeedEntries(
          viewerDid: viewer, selector: selector, filter: .unread, cursor: duplicateCursor, limit: 1))
        #expect(belowDuplicate.response.entries.map(\.entryId) == [uri("old-duplicate")])
        let publicationPage = try #require(try await fixture.store.listFeedEntries(
          viewerDid: viewer, selector: .init(kind: .publication, id: publication),
          filter: .all, cursor: nil, limit: 100))
        #expect(publicationPage.response.entries.count == 5)
        let empty = try #require(try await fixture.store.listFeedEntries(
          viewerDid: viewer, selector: .init(kind: .folder, id: "empty"),
          filter: .all, cursor: nil, limit: 2))
        #expect(empty.response.entries.isEmpty && empty.response.cursor == nil)
        #expect(try await fixture.store.listFeedEntries(
          viewerDid: viewer, selector: .init(kind: .folder, id: "unknown"),
          filter: .all, cursor: nil, limit: 2) == nil)
        #expect(try await fixture.store.listFeedEntries(
          viewerDid: viewer + "-other", selector: selector,
          filter: .all, cursor: nil, limit: 2) == nil)
      } catch {
        try? await cleanup(fixture, viewer: viewer, author: author)
        throw error
      }
      try await cleanup(fixture, viewer: viewer, author: author)
    }
  }

  private func cleanup(_ fixture: PostgresInboxFixture, viewer: String, author: String) async throws {
    for try await _ in try await fixture.pool.query(
      "DELETE FROM appview_feed_publications WHERE viewer_did = \(viewer)", logger: fixture.logger) {}
    for try await _ in try await fixture.pool.query(
      "DELETE FROM appview_publication_scope_keys WHERE viewer_did = \(viewer)", logger: fixture.logger) {}
    for try await _ in try await fixture.pool.query(
      "DELETE FROM appview_viewer_feeds WHERE viewer_did = \(viewer)", logger: fixture.logger) {}
    for try await _ in try await fixture.pool.query(
      "DELETE FROM content_items WHERE author_did = ANY(\([author, author + "-wild", author + "-outside"]))",
      logger: fixture.logger) {}
    // The shared fixture removes read state, floors, and scopes for this viewer.
  }
}
