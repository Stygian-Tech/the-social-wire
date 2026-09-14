import Foundation
import GatewayCore
import Hummingbird
import Logging
import NIOCore
import ThinAppViewCore

struct ReadAgeService: Sendable {
  let store: any ThinAppViewStore
  let projectionCache: (any AppViewProjectionCacheStore)?

  func options(
    viewerDid: String, rows: [SidebarPublicationRow], timeZone: String, now: Date
  ) async throws -> ReadAgeOptionsResponse {
    _ = try ReadAgeCalendar.calendar(timeZone: timeZone)
    let entries = try await unreadSnapshot(viewerDid: viewerDid, rows: rows)
    return try ReadAgeCalendar.options(
      publishedDates: entries.map(\.publishedAt), timeZone: timeZone, now: now
    )
  }

  func writeOptionsStream(
    viewerDid: String, rows: [SidebarPublicationRow], timeZone: String, now: Date,
    writer: inout any ResponseBodyWriter
  ) async throws {
    do {
      var accumulator = try ReadAgeOptionAccumulator(timeZone: timeZone, now: now)
      let scopes = Self.scopes(viewerDid: viewerDid, rows: rows)
      try await ReadAgeSnapshot.forEachPage { cursor in
        guard !scopes.isEmpty else {
          return AppViewEntryListResponse(entries: [], cursor: nil)
        }
        return try await store.listUnreadEntriesForReadMutation(
          viewerDid: viewerDid, scopes: scopes, cursor: cursor, limit: 100
        )
      } onPage: { entries in
        accumulator.append(publishedDates: entries.map(\.publishedAt))
        let options = try accumulator.response()
        try await Self.writeEvent(
          ReadAgeStreamEvent(type: "options", options: options.options, referenceDay: options.referenceDay),
          writer: &writer
        )
      }
      try await Self.writeEvent(ReadAgeStreamEvent(type: "done"), writer: &writer)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try await Self.writeEvent(
        ReadAgeStreamEvent(type: "error", message: "Couldn't load read-age options."),
        writer: &writer
      )
    }
    try await writer.finish(nil)
  }

  private static func writeEvent(
    _ event: ReadAgeStreamEvent, writer: inout any ResponseBodyWriter
  ) async throws {
    var buffer = ByteBuffer()
    buffer.writeBytes(try JSONEncoder().encode(event))
    buffer.writeString("\n")
    try await writer.write(buffer)
  }

  func markBefore(
    viewerDid: String, rows: [SidebarPublicationRow], before: String, now: Date
  ) async throws -> MarkReadBeforeResponse {
    let cutoff = try ReadAgeCalendar.cutoff(before, now: now)
    // Complete the paginated snapshot before changing unread state. Publication dates do not
    // follow feed cursor order, so an old or recent row is never a reason to stop scanning.
    let entries = try await unreadSnapshot(viewerDid: viewerDid, rows: rows)
    let entryIds = entries.filter { $0.publishedAt < cutoff }.map(\.entryId)
    // The store chunks SQL internally in one transaction, so a failed chunk rolls back all marks.
    try await store.upsertReadMarks(viewerDid: viewerDid, subjectUris: entryIds, createdAt: now)
    let uniqueRows = Self.uniqueRows(rows)
    let scopes = uniqueRows.map { row in
      PublicationUnreadScope(
        publicationId: row.publicationId,
        authorDid: row.appViewScope.authorDid,
        publicationAtUri: row.appViewScope.publicationAtUri,
        publicationScopeAtUris: row.appViewScope.publicationScopeAtUris,
        publicationSiteUrls: row.appViewScope.publicationSiteUrls
      )
    }
    var counters: [AppViewUnreadCounter] = []
    var refreshFailed = false
    do {
      counters = try await store.refreshUnreadCounters(viewerDid: viewerDid, scopes: scopes)
    } catch {
      refreshFailed = true
    }
    // Even if recounting fails after the committed transaction, attempt every invalidation.
    for row in uniqueRows {
      do {
        try await projectionCache?.invalidateUnreadCounts(
          viewerDid: viewerDid, publicationId: row.publicationId
        )
      } catch { refreshFailed = true }
      do {
        try await projectionCache?.invalidateFirstPage(
          viewerDid: viewerDid, publicationId: row.publicationId
        )
      } catch { refreshFailed = true }
    }
    if refreshFailed {
      Logger(label: "ReadAgeService").warning(
        "Read marks committed; a read-state projection refresh failed",
        metadata: ["marked": .stringConvertible(entryIds.count)]
      )
    }
    // Marks are already committed. Preserve success and their IDs even if the recount failed;
    // an empty count map makes no count claim, and dirty counters are rebuilt on the next read.
    // Entry detail resolves read state directly from the store; it has no read-state cache.
    return MarkReadBeforeResponse(
      marked: entryIds.count,
      entryIds: entryIds,
      readAt: ReadAgeCalendar.timestamp(now),
      unreadCounts: Dictionary(uniqueKeysWithValues: counters.map { ($0.publicationId, $0.unreadCount) })
    )
  }

  private func unreadSnapshot(
    viewerDid: String, rows: [SidebarPublicationRow]
  ) async throws -> [AppViewEntryListItem] {
    let scopes = Self.scopes(viewerDid: viewerDid, rows: rows)
    guard !scopes.isEmpty else { return [] }
    return try await ReadAgeSnapshot.collect { cursor in
      try await store.listUnreadEntriesForReadMutation(
        viewerDid: viewerDid, scopes: scopes, cursor: cursor, limit: 100
      )
    }
  }

  private static func scopes(
    viewerDid: String, rows: [SidebarPublicationRow]
  ) -> [AppViewPublicationScope] {
    uniqueRows(rows).map { row in
      AppViewUnreadCounterSupport.publicationScope(
        viewerDid: viewerDid,
        publicationId: row.publicationId,
        authorDid: row.appViewScope.authorDid,
        publicationAtUri: row.appViewScope.publicationAtUri,
        publicationScopeAtUris: row.appViewScope.publicationScopeAtUris,
        publicationSiteUrls: row.appViewScope.publicationSiteUrls,
        sectionKeys: []
      )
    }
  }

  private static func uniqueRows(_ rows: [SidebarPublicationRow]) -> [SidebarPublicationRow] {
    var seen = Set<String>()
    return rows.filter { seen.insert($0.publicationId).inserted }
  }
}
