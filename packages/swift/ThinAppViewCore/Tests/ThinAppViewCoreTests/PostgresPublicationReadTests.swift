import Foundation
import PostgresNIO
import Testing

@testable import ThinAppViewCore

@Suite("Postgres publication reads", .serialized,
  .enabled(if: ProcessInfo.processInfo.environment["THIN_APPVIEW_TEST_DATABASE_URL"] != nil))
struct PostgresPublicationReadTests {
  @Test("publication queries preserve read filters, cursor ties, scope, expiry and complete payloads")
  func publicationParity() async throws {
    try await PostgresInboxFixture.withFixture { fixture in
      let author = fixture.sourceGeneration + "-read-author"
      let viewer = fixture.sourceGeneration + "-read-viewer"
      let publication = "at://\(author)/site.standard.publication/main"
      let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
      let createdAt = now.addingTimeInterval(-100)
      let summary = String(repeating: "Retain the full selected article. ", count: 2048) + "End."
      func uri(_ key: String) -> String { "at://\(author)/site.standard.document/\(key)" }
      func execute(_ query: PostgresQuery) async throws {
        for try await _ in try await fixture.pool.query(query, logger: fixture.logger) {}
      }
      for key in ["a", "b", "c", "d", "expired"] {
        let render = ContentRenderFields(title: key, publishedAt: ISO8601DateFormatter().string(from: createdAt), summary: summary)
        let json = String(decoding: try JSONEncoder().encode(render), as: UTF8.self)
        try await execute("""
          INSERT INTO content_items
            (uri, cid, author_did, collection, created_at, indexed_at, publication_site, render_json, expires_at)
          VALUES (\(uri(key)), 'cid', \(author), 'site.standard.document', \(createdAt), \(now),
            \(key == "d" ? publication + "-other" : publication), \(json)::jsonb,
            \(now.addingTimeInterval(key == "expired" ? -1 : 3600)))
          """)
      }
      try await execute("""
        INSERT INTO read_marks (viewer_did, subject_uri, created_at)
        VALUES (\(viewer), \(uri("c")), \(now))
        """)
      try await execute("""
        INSERT INTO appview_unread_overrides (viewer_did, subject_uri, created_at)
        VALUES (\(viewer), \(uri("a")), \(now))
        """)
      try await execute("""
        INSERT INTO appview_publication_read_floors
          (viewer_did, publication_id, read_floor_at, read_floor_uri, generation, updated_at)
        VALUES (\(viewer), \(publication), \(createdAt), \(uri("b")), 1, \(now))
        """)
      let boundary = try await fixture.store.readBoundary(viewerDid: viewer, publicationId: publication)
      for scoped in [false, true] {
        for filter in [EntryListFilter.all, .read, .unread] {
          let expected: [String]
          switch filter {
          case .all: expected = scoped ? ["c", "b", "a"] : ["d", "c", "b", "a"]
          case .read: expected = ["c", "b"]
          case .unread: expected = scoped ? ["a"] : ["d", "a"]
          }
          var cursor: String?
          var entries: [AppViewEntryListItem] = []
          repeat {
            let page = try await AppViewFeedQueryDeadline.$current.withValue(.init()) {
              try await fixture.store.listEntries(viewerDid: viewer, authorDid: author,
                publicationAtUri: scoped ? publication : nil, publicationScopeAtUris: [],
                publicationSiteUrls: [], filter: filter, cursor: cursor, limit: 1,
                readBoundary: boundary)
            }
            entries += page.entries
            cursor = page.cursor
            #expect(entries.count <= expected.count)
            if entries.count > expected.count { break }
          } while cursor != nil
          #expect(entries.map(\.entryId) == expected.map(uri))
          #expect(entries.allSatisfy { $0.summary == summary })
          let states = try await AppViewFeedQueryDeadline.$current.withValue(.init()) {
            try await fixture.store.readStates(viewerDid: viewer,
              entries: entries.map { $0.withPublicationId(publication) })
          }
          for entry in entries {
            #expect(states[entry.entryId] == [uri("b"), uri("c")].contains(entry.entryId))
          }
        }
      }
      try await execute("DELETE FROM content_items WHERE author_did = \(author)")
    }
  }

  @Test("publication and read-state queries stop waiting for a saturated pool at their original deadline",
    arguments: ["scoped", "author", "boundary", "states"])
  func saturatedPool(path: String) async throws {
    try await PostgresInboxFixture.withFixture(maximumConnections: 1) { fixture in
      let entry = AppViewEntryListItem(entryId: "deadline-fixture", title: "Test", publishedAt: Date())
      let task = try await fixture.pool.withConnection { held in
        let deadline = AppViewFeedQueryDeadline(duration: .milliseconds(150))
        let task = Task {
          try await AppViewFeedQueryDeadline.$current.withValue(deadline) {
            switch path {
            case "boundary":
              _ = try await fixture.store.readBoundary(viewerDid: "deadline-viewer", publicationId: "test")
            case "states":
              _ = try await fixture.store.readStates(viewerDid: "deadline-viewer", entries: [entry])
            default:
              _ = try await fixture.store.listEntries(viewerDid: "deadline-viewer", authorDid: "test",
                publicationAtUri: path == "scoped" ? "at://test/site.standard.publication/main" : nil,
                publicationScopeAtUris: [], publicationSiteUrls: [], filter: .all,
                cursor: nil, limit: 1, readBoundary: nil)
            }
          }
        }
        // Release automatically so the old unbounded implementation fails rather than hangs.
        try await Task.sleep(for: .milliseconds(450))
        #expect(!held.isClosed)
        _ = try await held.query("SELECT 1", logger: fixture.logger)
        return task
      }
      do { try await task.value; Issue.record("Read escaped its request deadline: \(path)") }
      catch { #expect(error is AppViewFeedQueryDeadline.Failure) }
      try await fixture.store.ping()
      for try await row in try await fixture.pool.query("SHOW statement_timeout", logger: fixture.logger) {
        #expect(try row.decode(String.self) == "0")
      }
    }
  }
}
