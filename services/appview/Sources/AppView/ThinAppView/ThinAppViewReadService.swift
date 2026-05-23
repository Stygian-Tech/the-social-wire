import Foundation
import GatewayCore
import Hummingbird
import Logging
import ThinAppViewCore

actor ThinAppViewReadService {
  private let store: any ThinAppViewStore
  private let logger: Logger

  init(store: any ThinAppViewStore, logger: Logger) {
    self.store = store
    self.logger = logger
  }

  func listEntries(
    auth: AuthContext,
    authorDid: String,
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String],
    filter: EntryListFilter,
    cursor: String?,
    limit: Int
  ) async throws -> AppViewEntryListResponse {
    try await store.listEntries(
      viewerDid: auth.did,
      authorDid: authorDid,
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls,
      filter: filter,
      cursor: cursor,
      limit: limit
    )
  }

  func listEntriesUpTo(
    auth: AuthContext,
    authorDid: String,
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String],
    filter: EntryListFilter,
    maxEntries: Int,
    pageLimit: Int = ThinAppViewEntryPagination.defaultPageLimit
  ) async throws -> AppViewEntryListResponse {
    let cappedMax = max(1, min(maxEntries, ThinAppViewEntryPagination.maxAggregateEntries))
    var merged: [AppViewEntryListItem] = []
    var cursor: String?
    var nextCursor: String?

    while merged.count < cappedMax {
      let page = try await listEntries(
        auth: auth,
        authorDid: authorDid,
        publicationAtUri: publicationAtUri,
        publicationScopeAtUris: publicationScopeAtUris,
        publicationSiteUrls: publicationSiteUrls,
        filter: filter,
        cursor: cursor,
        limit: pageLimit
      )
      if page.entries.isEmpty {
        nextCursor = nil
        break
      }

      merged = ThinAppViewEntryPagination.mergeEntries(existing: merged, newPage: page.entries)

      if merged.count >= cappedMax {
        nextCursor = page.cursor
        break
      }

      guard let pageCursor = page.cursor, !pageCursor.isEmpty else {
        nextCursor = nil
        break
      }
      cursor = pageCursor
    }

    if merged.count > cappedMax {
      merged = Array(merged.prefix(cappedMax))
    }

    return AppViewEntryListResponse(entries: merged, cursor: nextCursor)
  }

  func upsertReadMark(auth: AuthContext, subjectUri: String, readAt: Date?) async throws {
    try await store.upsertReadMark(
      viewerDid: auth.did,
      subjectUri: subjectUri,
      createdAt: readAt ?? Date()
    )
  }

  func deleteReadMark(auth: AuthContext, subjectUri: String) async throws {
    try await store.deleteReadMark(viewerDid: auth.did, subjectUri: subjectUri)
  }

  func purge(auth: AuthContext) async throws {
    try await store.purgeReadMarks(viewerDid: auth.did)
    logger.info("Purged thin AppView read marks", metadata: ["did": .string(auth.did)])
  }

  func entryDetail(auth: AuthContext, entryId: String) async throws -> AppViewEntryDetailResponse {
    guard let item = try await store.fetchContentItem(uri: entryId) else {
      throw HTTPError(.notFound, message: "Entry not found in AppView index")
    }
    let isRead = try await store.hasReadMark(viewerDid: auth.did, subjectUri: entryId)
    return AppViewEntryDetailResponse(
      entryId: item.entryId,
      title: item.title,
      summary: item.summary,
      publishedAt: item.publishedAt,
      thumbnailUrl: item.thumbnailUrl,
      isRead: isRead,
      contentHtml: item.summary
    )
  }

  func unreadCountsByPublicationIds(
    auth: AuthContext,
    publicationIds: [String],
    projectionService: PublicationProjectionService
  ) async throws -> AppViewUnreadCountsByPublicationResponse {
    let cachedRows = await projectionService.sidebarRows(
      for: auth.did,
      publicationIds: publicationIds
    )
    let rowsById = Dictionary(uniqueKeysWithValues: cachedRows.map { ($0.publicationId, $0) })

    var counts: [String: Int] = [:]
    await withTaskGroup(of: (String, Int)?.self) { group in
      for publicationId in publicationIds {
        group.addTask {
          guard let row = rowsById[publicationId] else { return nil }
          let unreadCount = try? await self.store.countUnreadEntries(
            viewerDid: auth.did,
            authorDid: row.appViewScope.authorDid,
            publicationAtUri: row.appViewScope.publicationAtUri,
            publicationScopeAtUris: row.appViewScope.publicationScopeAtUris,
            publicationSiteUrls: row.appViewScope.publicationSiteUrls
          )
          guard let unreadCount, unreadCount > 0 else { return nil }
          return (publicationId, unreadCount)
        }
      }
      for await result in group {
        if let (publicationId, count) = result {
          counts[publicationId] = count
        }
      }
    }

    if counts.count < publicationIds.filter({ rowsById[$0] != nil }).count {
      let missingIds = publicationIds.filter { rowsById[$0] == nil }
      if !missingIds.isEmpty {
        let sidebar = try await projectionService.sidebar(auth: auth, phase: .full)
        for publicationId in missingIds {
          guard let row = sidebar.allPublicationRows.first(where: { $0.publicationId == publicationId }) else {
            continue
          }
          let unreadCount = try await store.countUnreadEntries(
            viewerDid: auth.did,
            authorDid: row.appViewScope.authorDid,
            publicationAtUri: row.appViewScope.publicationAtUri,
            publicationScopeAtUris: row.appViewScope.publicationScopeAtUris,
            publicationSiteUrls: row.appViewScope.publicationSiteUrls
          )
          if unreadCount > 0 {
            counts[publicationId] = unreadCount
          }
        }
      }
    }

    return AppViewUnreadCountsByPublicationResponse(counts: counts)
  }

  func unreadCounts(
    auth: AuthContext,
    authorDid: String?,
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String]
  ) async throws -> AppViewUnreadCountsResponse {
    let did = authorDid ?? auth.did
    let unreadCount = try await store.countUnreadEntries(
      viewerDid: auth.did,
      authorDid: did,
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls
    )
    let key = publicationAtUri ?? did
    return AppViewUnreadCountsResponse(
      counts: [AppViewUnreadCountRow(scopeKey: key, unreadCount: unreadCount)]
    )
  }
}
