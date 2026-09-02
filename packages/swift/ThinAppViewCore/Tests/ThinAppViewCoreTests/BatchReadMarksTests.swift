import Foundation
import GRDB
import Logging
import Testing
import ThinAppViewCore

@Suite("Batch explicit read marks")
struct BatchReadMarksTests {
  @Test("only selected subjects change, preserving other viewers and publication floors")
  func selectedSubjectsOnly() async throws {
    let fixture = try Self.fixture()
    defer { Self.removeDatabase(at: fixture.path) }
    let viewer = "did:plc:viewer"
    let otherViewer = "did:plc:other"
    let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
    let newDate = oldDate.addingTimeInterval(60)
    let selected = ["selected-read", "selected-unread", "selected-new"]

    try await fixture.store.upsertReadMark(viewerDid: viewer, subjectUri: selected[0], createdAt: oldDate)
    try await fixture.store.markEntryUnread(viewerDid: viewer, subjectUri: selected[1], createdAt: oldDate)
    try await fixture.store.upsertReadMark(viewerDid: viewer, subjectUri: "newer-read", createdAt: newDate)
    try await fixture.store.markEntryUnread(viewerDid: viewer, subjectUri: "newer-unread", createdAt: newDate)
    try await fixture.store.markEntryUnread(viewerDid: viewer, subjectUri: "unrelated-old", createdAt: oldDate)
    try await fixture.store.upsertReadMark(viewerDid: otherViewer, subjectUri: selected[0], createdAt: oldDate)
    try await fixture.store.markEntryUnread(viewerDid: otherViewer, subjectUri: selected[1], createdAt: oldDate)

    let scope = PublicationUnreadScope(
      publicationId: "publication",
      authorDid: "did:plc:author",
      publicationAtUri: nil,
      publicationScopeAtUris: [],
      publicationSiteUrls: []
    )
    _ = try await fixture.store.markAllReadCounters(viewerDid: viewer, scopes: [scope], readAt: oldDate)
    let floorBefore = try await fixture.store.readBoundary(viewerDid: viewer, publicationId: scope.publicationId)
    let unaffectedMarksBefore = try await fixture.database.read { db in
      try String.fetchAll(db, sql: """
        SELECT viewer_did || '|' || subject_uri || '|' || created_at FROM read_marks
        WHERE viewer_did != ? OR subject_uri NOT IN (?, ?, ?)
        ORDER BY viewer_did, subject_uri
        """, arguments: StatementArguments([viewer] + selected))
    }
    let unaffectedOverridesBefore = try await fixture.database.read { db in
      try String.fetchAll(db, sql: """
        SELECT viewer_did || '|' || subject_uri || '|' || created_at FROM appview_unread_overrides
        WHERE viewer_did != ? OR subject_uri NOT IN (?, ?, ?)
        ORDER BY viewer_did, subject_uri
        """, arguments: StatementArguments([viewer] + selected))
    }

    // Use the protocol existential to exercise the batch contract used by service callers.
    let store: any ThinAppViewStore = fixture.store
    try await store.upsertReadMarks(viewerDid: viewer, subjectUris: selected, createdAt: newDate)

    for subject in selected {
      #expect(try await store.hasReadMark(viewerDid: viewer, subjectUri: subject))
    }
    let unaffectedMarksAfter = try await fixture.database.read { db in
      try String.fetchAll(db, sql: """
        SELECT viewer_did || '|' || subject_uri || '|' || created_at FROM read_marks
        WHERE viewer_did != ? OR subject_uri NOT IN (?, ?, ?)
        ORDER BY viewer_did, subject_uri
        """, arguments: StatementArguments([viewer] + selected))
    }
    let unaffectedOverridesAfter = try await fixture.database.read { db in
      try String.fetchAll(db, sql: """
        SELECT viewer_did || '|' || subject_uri || '|' || created_at FROM appview_unread_overrides
        WHERE viewer_did != ? OR subject_uri NOT IN (?, ?, ?)
        ORDER BY viewer_did, subject_uri
        """, arguments: StatementArguments([viewer] + selected))
    }
    #expect(unaffectedMarksAfter == unaffectedMarksBefore)
    #expect(unaffectedOverridesAfter == unaffectedOverridesBefore)
    #expect(try await store.readBoundary(viewerDid: viewer, publicationId: scope.publicationId) == floorBefore)
    let selectedOverrideCount = try await fixture.database.read { db in
      try Int.fetchOne(db, sql: """
        SELECT COUNT(*) FROM appview_unread_overrides
        WHERE viewer_did = ? AND subject_uri IN (?, ?, ?)
        """, arguments: StatementArguments([viewer] + selected))
    }
    #expect(selectedOverrideCount == 0)
  }

  @Test("large batches deduplicate subjects, update timestamps, and accept empty input")
  func chunkedDuplicatesAndEmptyInput() async throws {
    let fixture = try Self.fixture()
    defer { Self.removeDatabase(at: fixture.path) }
    let viewer = "did:plc:viewer"
    let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
    let newDate = oldDate.addingTimeInterval(60)
    let subjects = (0..<1_001).map { String(format: "subject-%04d", $0) }

    try await fixture.store.upsertReadMarks(
      viewerDid: viewer,
      subjectUris: subjects + subjects.reversed(),
      createdAt: oldDate
    )
    try await fixture.store.upsertReadMarks(viewerDid: viewer, subjectUris: subjects, createdAt: newDate)
    let timestampsBeforeEmpty = try await fixture.database.read { db in
      try String.fetchAll(db, sql: "SELECT created_at FROM read_marks WHERE viewer_did = ?", arguments: [viewer])
    }
    #expect(timestampsBeforeEmpty.count == subjects.count)
    #expect(Set(timestampsBeforeEmpty).count == 1)
    let timestamp = try #require(timestampsBeforeEmpty.first)
    #expect(ISO8601DateFormatter().date(from: timestamp) == newDate)

    try await fixture.store.upsertReadMarks(viewerDid: viewer, subjectUris: [], createdAt: oldDate)
    let timestampsAfterEmpty = try await fixture.database.read { db in
      try String.fetchAll(db, sql: "SELECT created_at FROM read_marks WHERE viewer_did = ?", arguments: [viewer])
    }
    #expect(timestampsAfterEmpty == timestampsBeforeEmpty)
  }

  @Test("a failure in a later chunk rolls back earlier marks and override deletions")
  func entireBatchRollsBack() async throws {
    let fixture = try Self.fixture()
    defer { Self.removeDatabase(at: fixture.path) }
    let viewer = "did:plc:viewer"
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let subjects = (0..<501).map { String(format: "subject-%04d", $0) }
    try await fixture.store.markEntryUnread(viewerDid: viewer, subjectUri: subjects[0], createdAt: date)
    try await fixture.database.write { db in
      try db.execute(sql: """
        CREATE TRIGGER fail_later_batch BEFORE INSERT ON read_marks
        WHEN NEW.subject_uri = 'subject-0500'
        BEGIN SELECT RAISE(ABORT, 'injected batch failure'); END;
        """)
    }

    await #expect(throws: DatabaseError.self) {
      try await fixture.store.upsertReadMarks(viewerDid: viewer, subjectUris: subjects, createdAt: date)
    }
    let readMarkCount = try await fixture.database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM read_marks")
    }
    let overrides = try await fixture.database.read { db in
      try String.fetchAll(db, sql: "SELECT subject_uri FROM appview_unread_overrides WHERE viewer_did = ?", arguments: [viewer])
    }
    #expect(readMarkCount == 0)
    #expect(overrides == [subjects[0]])
  }

  @Test("affected counters become dirty atomically and recover on recount", arguments: [false, true])
  func countersAreDirtyAtomically(injectCounterFailure: Bool) async throws {
    let fixture = try Self.fixture()
    defer { Self.removeDatabase(at: fixture.path) }
    let viewer = "did:plc:viewer"
    let otherViewer = "did:plc:other-viewer"
    let author = "did:plc:author"
    let now = Date()
    let scopes = [
      Self.scope(id: "selected", viewer: viewer, author: author, site: "https://selected.example", at: now),
      Self.scope(id: "author-all", viewer: viewer, author: author, site: nil, at: now),
      Self.scope(id: "unrelated", viewer: viewer, author: author, site: "https://unrelated.example", at: now),
      Self.scope(id: "other-author", viewer: viewer, author: "did:plc:other-author", site: "https://selected.example", at: now),
    ]
    let otherViewerScope = Self.scope(
      id: "selected", viewer: otherViewer, author: author, site: "https://selected.example", at: now
    )
    try await fixture.store.upsertPublicationScopes(scopes + [otherViewerScope])
    for (subject, site) in [
      ("selected-one", "https://selected.example"),
      ("selected-two", "https://selected.example"),
      ("unrelated", "https://unrelated.example"),
    ] {
      try await fixture.store.upsertContentItem(IndexedContentItem(
        uri: subject, cid: "cid-\(subject)", authorDid: author,
        collection: "site.standard.document", createdAt: now, indexedAt: now,
        publicationSite: site,
        render: ContentRenderFields(title: subject, publishedAt: ISO8601DateFormatter().string(from: now)),
        expiresAt: now.addingTimeInterval(3_600)
      ))
    }
    let unreadScopes = scopes.map(Self.unreadScope)
    _ = try await fixture.store.refreshUnreadCounters(viewerDid: viewer, scopes: unreadScopes)
    _ = try await fixture.store.refreshUnreadCounters(
      viewerDid: otherViewer, scopes: [Self.unreadScope(otherViewerScope)]
    )
    let before = try await fixture.store.fetchUnreadCounters(viewerDid: viewer, publicationIds: nil)
    let otherBefore = try await fixture.store.fetchUnreadCounters(viewerDid: otherViewer, publicationIds: nil)
    try await fixture.store.markEntryUnread(viewerDid: viewer, subjectUri: "selected-one", createdAt: now)
    if injectCounterFailure {
      try await fixture.database.write { db in
        try db.execute(sql: """
          CREATE TRIGGER fail_counter_update BEFORE UPDATE ON appview_unread_counters
          WHEN NEW.dirty = 1
          BEGIN SELECT RAISE(ABORT, 'injected counter failure'); END;
          """)
      }
      await #expect(throws: DatabaseError.self) {
        try await fixture.store.upsertReadMarks(
          viewerDid: viewer, subjectUris: ["selected-one", "selected-two"], createdAt: now
        )
      }
      #expect(try await fixture.store.hasReadMark(viewerDid: viewer, subjectUri: "selected-one") == false)
      let remainingOverrides = try await fixture.database.read { db in
        try String.fetchAll(db, sql: "SELECT subject_uri FROM appview_unread_overrides WHERE viewer_did = ?", arguments: [viewer])
      }
      #expect(remainingOverrides == ["selected-one"])
    } else {
      try await fixture.store.upsertReadMarks(
        viewerDid: viewer, subjectUris: ["selected-one", "selected-two"], createdAt: now
      )
    }

    let after = try await fixture.store.fetchUnreadCounters(viewerDid: viewer, publicationIds: nil)
    for previous in before {
      let current = try #require(after.first { $0.publicationId == previous.publicationId })
      if !injectCounterFailure && ["selected", "author-all"].contains(current.publicationId) {
        #expect(current.dirty)
        #expect(current.accuracy == .estimated)
        #expect(current.unreadCount == previous.unreadCount)
      } else {
        #expect(current == previous)
      }
    }
    #expect(try await fixture.store.fetchUnreadCounters(viewerDid: otherViewer, publicationIds: nil) == otherBefore)

    if !injectCounterFailure {
      let recounted = try await fixture.store.refreshUnreadCounters(viewerDid: viewer, scopes: unreadScopes)
      #expect(recounted.allSatisfy { !$0.dirty && $0.accuracy == .exact })
      #expect(recounted.first { $0.publicationId == "selected" }?.unreadCount == 0)
      #expect(recounted.first { $0.publicationId == "author-all" }?.unreadCount == 1)
    }
  }

  private static func scope(
    id: String, viewer: String, author: String, site: String?, at: Date
  ) -> AppViewPublicationScope {
    AppViewUnreadCounterSupport.publicationScope(
      viewerDid: viewer, publicationId: id, authorDid: author,
      publicationAtUri: nil, publicationScopeAtUris: [],
      publicationSiteUrls: site.map { [$0] } ?? [], sectionKeys: [], updatedAt: at
    )
  }

  private static func unreadScope(_ scope: AppViewPublicationScope) -> PublicationUnreadScope {
    PublicationUnreadScope(
      publicationId: scope.publicationId, authorDid: scope.authorDid,
      publicationAtUri: scope.publicationAtUri,
      publicationScopeAtUris: scope.publicationScopeAtUris,
      publicationSiteUrls: scope.publicationSiteUrls
    )
  }

  private static func fixture() throws -> (path: String, store: SQLiteThinAppViewStore, database: DatabaseQueue) {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("batch-read-marks-\(UUID().uuidString).sqlite").path
    let store = try SQLiteThinAppViewStore(path: path, logger: Logger(label: "batch-read-marks.test"))
    return (path, store, try DatabaseQueue(path: path))
  }

  private static func removeDatabase(at path: String) {
    for suffix in ["", "-shm", "-wal"] {
      try? FileManager.default.removeItem(atPath: path + suffix)
    }
  }
}
