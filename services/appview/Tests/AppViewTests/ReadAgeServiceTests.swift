import Foundation
import GatewayCore
import GRDB
import Logging
import Testing
import ThinAppViewCore

@testable import AppView

@Suite("Read age scoped snapshots")
struct ReadAgeServiceTests {
  @Test("scans every unread page before marking, uses publication dates, and preserves newer stories")
  func fullSnapshotAndExclusiveCutoff() async throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("read-age-\(UUID().uuidString).sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try SQLiteThinAppViewStore(path: path, logger: Logger(label: "read-age.test"))
    let service = ReadAgeService(store: store, projectionCache: nil)
    let row = publication(author: "did:plc:author")
    let outsider = publication(author: "did:plc:outsider")
    let now = date("2026-09-02T17:00:00Z")
    let cutoff = date("2026-09-02T05:00:00Z")
    var oldIds: [String] = []
    for index in 0..<205 {
      let id = "at://did:plc:author/site.standard.document/old-\(index)"
      oldIds.append(id)
      try await store.upsertContentItem(item(
        id: id, row: row,
        createdAt: now.addingTimeInterval(Double(index)),
        publishedAt: date("2026-09-01T12:00:00Z")
      ))
    }
    let todayId = "at://did:plc:author/site.standard.document/today"
    let otherId = "at://did:plc:outsider/site.standard.document/old"
    let readId = "at://did:plc:author/site.standard.document/already-read"
    for (id, publication, published) in [
      (todayId, row, cutoff),
      (otherId, outsider, cutoff.addingTimeInterval(-100)),
      (readId, row, cutoff.addingTimeInterval(-200)),
    ] {
      try await store.upsertContentItem(item(
        id: id, row: publication, createdAt: now.addingTimeInterval(500), publishedAt: published
      ))
    }
    try await store.upsertReadMark(viewerDid: "did:plc:viewer", subjectUri: readId, createdAt: now)

    let options = try await service.options(
      viewerDid: "did:plc:viewer", rows: [row, row], timeZone: "America/Chicago", now: now
    )
    #expect(options.options.map(\.days) == [1])
    #expect(options.options.map(\.count) == [205])
    let marked = try await service.markBefore(
      viewerDid: "did:plc:viewer", rows: [row, row], before: "2026-09-02T05:00:00Z", now: now
    )
    #expect(marked.marked == 205)
    #expect(Set(marked.entryIds) == Set(oldIds))
    #expect(marked.unreadCounts[row.publicationId] == 1)
    #expect(try await store.hasReadMark(viewerDid: "did:plc:viewer", subjectUri: todayId) == false)
    #expect(try await store.hasReadMark(viewerDid: "did:plc:viewer", subjectUri: otherId) == false)
    #expect(try await store.hasReadMark(viewerDid: "did:plc:other-viewer", subjectUri: oldIds[0]) == false)
    #expect(try await store.readBoundary(viewerDid: "did:plc:viewer", publicationId: row.publicationId) == nil)

    let repeatResult = try await service.markBefore(
      viewerDid: "did:plc:viewer", rows: [row], before: "2026-09-02T05:00:00Z", now: now
    )
    #expect(repeatResult.marked == 0)
    #expect(repeatResult.unreadCounts[row.publicationId] == 1)
  }

  @Test("empty authorized scope has no options and marks nothing")
  func emptyScope() async throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("read-age-empty-\(UUID().uuidString).sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try SQLiteThinAppViewStore(path: path, logger: Logger(label: "read-age-empty.test"))
    let service = ReadAgeService(store: store, projectionCache: nil)
    let now = date("2026-09-02T17:00:00Z")
    #expect(try await service.options(viewerDid: "did:plc:viewer", rows: [], timeZone: "UTC", now: now).options.isEmpty)
    let result = try await service.markBefore(viewerDid: "did:plc:viewer", rows: [], before: "2026-09-02T00:00:00Z", now: now)
    #expect(result.marked == 0)
    #expect(result.unreadCounts.isEmpty)
  }

  @Test("marks every older record hidden behind a shared article URL across pages")
  func suppressedArticleDuplicates() async throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("read-age-duplicates-\(UUID().uuidString).sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try SQLiteThinAppViewStore(path: path, logger: Logger(label: "read-age-duplicates.test"))
    let service = ReadAgeService(store: store, projectionCache: nil)
    let row = publication(author: "did:plc:author")
    let viewer = "did:plc:viewer"
    let now = date("2026-09-02T17:00:00Z")
    let articleUrl = "https://example.com/shared-story"
    var oldIds: [String] = []
    for index in 0..<205 {
      let id = "at://did:plc:author/site.standard.document/duplicate-\(index)"
      oldIds.append(id)
      try await store.upsertContentItem(item(
        id: id, row: row, createdAt: now.addingTimeInterval(Double(index)),
        publishedAt: date("2026-09-01T12:00:00Z"), articleUrl: articleUrl
      ))
    }
    let todayId = "at://did:plc:author/site.standard.document/newer-duplicate"
    try await store.upsertContentItem(item(
      id: todayId, row: row, createdAt: now.addingTimeInterval(500),
      publishedAt: date("2026-09-02T05:00:00Z"), articleUrl: articleUrl
    ))

    let scope = AppViewUnreadCounterSupport.publicationScope(
      viewerDid: viewer, publicationId: row.publicationId, authorDid: row.authorDid,
      publicationAtUri: row.publicationId, publicationScopeAtUris: [row.publicationId],
      publicationSiteUrls: [], sectionKeys: []
    )
    let presentation = try await store.listAggregateEntries(
      viewerDid: viewer, scopes: [scope], filter: .unread, cursor: nil, limit: 100
    )
    #expect(presentation.response.entries.map(\.entryId) == [todayId])
    #expect(presentation.diagnostics.duplicatesSuppressed == 205)

    let options = try await service.options(
      viewerDid: viewer, rows: [row], timeZone: "America/Chicago", now: now
    )
    #expect(options.options.map(\.count) == [205])
    let result = try await service.markBefore(
      viewerDid: viewer, rows: [row], before: "2026-09-02T05:00:00Z", now: now
    )
    #expect(Set(result.entryIds) == Set(oldIds))
    #expect(result.unreadCounts[row.publicationId] == 1)
    #expect(try await store.hasReadMark(viewerDid: viewer, subjectUri: todayId) == false)
    #expect(try await service.options(
      viewerDid: viewer, rows: [row], timeZone: "America/Chicago", now: now
    ).options.isEmpty)
  }

  @Test("a failed recount preserves committed IDs and leaves dirty counters recoverable")
  func recountFailurePreservesSuccess() async throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("read-age-recount-\(UUID().uuidString).sqlite").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try SQLiteThinAppViewStore(path: path, logger: Logger(label: "read-age-recount.test"))
    let database = try DatabaseQueue(path: path)
    let service = ReadAgeService(store: store, projectionCache: nil)
    let row = publication(author: "did:plc:author")
    let viewer = "did:plc:viewer"
    let now = date("2026-09-02T17:00:00Z")
    let id = "at://did:plc:author/site.standard.document/old"
    try await store.upsertContentItem(item(
      id: id, row: row, createdAt: now, publishedAt: date("2026-09-01T12:00:00Z")
    ))
    try await store.upsertPublicationScopes([
      AppViewUnreadCounterSupport.publicationScope(
        viewerDid: viewer, publicationId: row.publicationId, authorDid: row.authorDid,
        publicationAtUri: row.publicationId, publicationScopeAtUris: [row.publicationId],
        publicationSiteUrls: [], sectionKeys: ["subscribed"]
      ),
    ])
    let unreadScope = PublicationUnreadScope(
      publicationId: row.publicationId, authorDid: row.authorDid,
      publicationAtUri: row.publicationId, publicationScopeAtUris: [row.publicationId],
      publicationSiteUrls: []
    )
    _ = try await store.refreshUnreadCounters(viewerDid: viewer, scopes: [unreadScope])
    try await database.write { db in
      try db.execute(sql: """
        CREATE TRIGGER fail_recount BEFORE INSERT ON appview_unread_counters
        WHEN NEW.dirty = 0
        BEGIN SELECT RAISE(ABORT, 'injected recount failure'); END;
        """)
    }

    let result = try await service.markBefore(
      viewerDid: viewer, rows: [row], before: "2026-09-02T05:00:00Z", now: now
    )
    #expect(result.marked == 1)
    #expect(result.entryIds == [id])
    #expect(result.unreadCounts.isEmpty)
    #expect(try await store.hasReadMark(viewerDid: viewer, subjectUri: id))
    let dirtyCounters = try await store.fetchUnreadCounters(viewerDid: viewer, publicationIds: [row.publicationId])
    #expect(dirtyCounters.first?.dirty == true)
    try await database.write { db in try db.execute(sql: "DROP TRIGGER fail_recount") }
    let recovered = try await store.refreshUnreadCounters(viewerDid: viewer, scopes: [unreadScope])
    #expect(recovered.first?.unreadCount == 0)
    #expect(recovered.first?.dirty == false)
  }

  private func publication(author: String) -> SidebarPublicationRow {
    let id = "at://\(author)/site.standard.publication/main"
    return SidebarPublicationRow(
      publicationId: id, subscriptionPublicationId: nil, authorDid: author,
      authorHandle: nil, title: "Fixture", iconUrl: nil, avatarUrl: nil,
      discoveredAt: Date(),
      appViewScope: PublicationAppViewScope(
        authorDid: author, publicationAtUri: id,
        publicationScopeAtUris: [id], publicationSiteUrls: []
      )
    )
  }

  private func item(
    id: String, row: SidebarPublicationRow, createdAt: Date, publishedAt: Date,
    articleUrl: String? = nil
  ) -> IndexedContentItem {
    IndexedContentItem(
      uri: id, cid: "fixture", authorDid: row.authorDid,
      collection: "site.standard.document", createdAt: createdAt, indexedAt: Date(),
      publicationSite: row.publicationId,
      render: ContentRenderFields(
        title: id, publishedAt: ReadAgeCalendar.timestamp(publishedAt), articleUrl: articleUrl
      ),
      expiresAt: Date().addingTimeInterval(3600)
    )
  }

  private func date(_ raw: String) -> Date {
    ISO8601DateFormatter().date(from: raw)!
  }
}
