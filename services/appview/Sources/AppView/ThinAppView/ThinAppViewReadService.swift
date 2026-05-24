import Foundation
import GatewayCore
import Hummingbird
import Logging
import ThinAppViewCore

actor ThinAppViewReadService {
  private let store: any ThinAppViewStore
  private let projectionCache: (any AppViewProjectionCacheStore)?
  private let logger: Logger

  init(
    store: any ThinAppViewStore,
    projectionCache: (any AppViewProjectionCacheStore)? = nil,
    logger: Logger
  ) {
    self.store = store
    self.projectionCache = projectionCache
    self.logger = logger
  }

  func cachedOrListedFirstPage(
    auth: AuthContext,
    publicationId: String,
    scope: PublicationAppViewScope,
    limit: Int
  ) async throws -> AppViewEntryListResponse? {
    if let projectionCache,
       let json = try await projectionCache.cachedFirstPageJSON(
         viewerDid: auth.did,
         publicationId: publicationId
       ),
       let page = try? JSONDecoder().decode(AppViewEntryListResponse.self, from: Data(json.utf8)),
       !page.entries.isEmpty
    {
      return dedupedPage(page)
    }

    let page = try await listEntries(
      auth: auth,
      authorDid: scope.authorDid,
      publicationAtUri: scope.publicationAtUri,
      publicationScopeAtUris: scope.publicationScopeAtUris,
      publicationSiteUrls: scope.publicationSiteUrls,
      filter: .all,
      cursor: nil,
      limit: limit
    )
    guard !page.entries.isEmpty else { return nil }
    return dedupedPage(page)
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
    if cursor == nil, filter == .all, let projectionCache {
      if let publicationId = primaryPublicationId(
        publicationAtUri: publicationAtUri,
        publicationScopeAtUris: publicationScopeAtUris,
        publicationSiteUrls: publicationSiteUrls,
        authorDid: authorDid
      ),
         let json = try await projectionCache.cachedFirstPageJSON(
           viewerDid: auth.did,
           publicationId: publicationId
         ),
         let cached = try? JSONDecoder().decode(AppViewEntryListResponse.self, from: Data(json.utf8))
      {
        return dedupedPage(cached)
      }
    }

    let page = try await store.listEntries(
      viewerDid: auth.did,
      authorDid: authorDid,
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls,
      filter: filter,
      cursor: cursor,
      limit: limit
    )

    if cursor == nil,
       filter == .all,
       let projectionCache,
       let publicationId = primaryPublicationId(
         publicationAtUri: publicationAtUri,
         publicationScopeAtUris: publicationScopeAtUris,
         publicationSiteUrls: publicationSiteUrls,
         authorDid: authorDid
       ),
       !page.entries.isEmpty,
       let data = try? JSONEncoder().encode(dedupedPage(page)),
       let json = String(data: data, encoding: .utf8)
    {
      let expiresAt = Date().addingTimeInterval(AppViewProjectionCacheTTL.firstPageSeconds)
      try? await projectionCache.storeFirstPageJSON(
        viewerDid: auth.did,
        publicationId: publicationId,
        jsonBody: json,
        expiresAt: expiresAt
      )
    }

    return dedupedPage(page)
  }

  private func dedupedPage(_ page: AppViewEntryListResponse) -> AppViewEntryListResponse {
    AppViewEntryListResponse(
      entries: RssFeedIdentity.dedupeEntryListItems(page.entries),
      cursor: page.cursor
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

    while true {
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
      let stepResult = ThinAppViewEntryPagination.step(
        merged: merged,
        page: page,
        cappedMax: cappedMax
      )
      merged = stepResult.merged
      if stepResult.completed {
        return AppViewEntryListResponse(entries: merged, cursor: stepResult.responseCursor)
      }
      cursor = stepResult.nextFetchCursor
    }
  }

  func upsertReadMark(auth: AuthContext, subjectUri: String, readAt: Date?) async throws {
    try await store.upsertReadMark(
      viewerDid: auth.did,
      subjectUri: subjectUri,
      createdAt: readAt ?? Date()
    )
    try await invalidateReadStateCaches(viewerDid: auth.did)
  }

  func deleteReadMark(auth: AuthContext, subjectUri: String) async throws {
    try await store.deleteReadMark(viewerDid: auth.did, subjectUri: subjectUri)
    try await invalidateReadStateCaches(viewerDid: auth.did)
  }

  func purge(auth: AuthContext) async throws {
    try await store.purgeReadMarks(viewerDid: auth.did)
    try await projectionCache?.invalidateUnreadCounts(viewerDid: auth.did, publicationId: nil)
    try await projectionCache?.invalidateFirstPage(viewerDid: auth.did, publicationId: nil)
    logger.info("Purged thin AppView read marks", metadata: ["did": .string(auth.did)])
  }

  func entryDetail(auth: AuthContext, entryId: String) async throws -> AppViewEntryDetailResponse {
    guard let item = try await store.fetchContentItem(uri: entryId) else {
      throw HTTPError(.notFound, message: "Entry not found in AppView index")
    }
    let render = try await store.fetchContentRender(uri: entryId)
    let isRead = try await store.hasReadMark(viewerDid: auth.did, subjectUri: entryId)
    return AppViewEntryDetailResponse(
      entryId: item.entryId,
      title: item.title,
      summary: item.summary,
      publishedAt: item.publishedAt,
      thumbnailUrl: item.thumbnailUrl,
      isRead: isRead,
      contentHtml: render?.contentHtml ?? render?.summary ?? item.summary
    )
  }

  func unreadCountsByPublicationIds(
    auth: AuthContext,
    publicationIds: [String],
    projectionService: PublicationProjectionService
  ) async throws -> AppViewUnreadCountsByPublicationResponse {
    if let projectionCache,
       let cached = try await projectionCache.cachedUnreadCounts(viewerDid: auth.did)
    {
      let filtered = publicationIds.reduce(into: [String: Int]()) { partial, publicationId in
        if let count = cached[publicationId], count > 0 {
          partial[publicationId] = count
        }
      }
      if filtered.count == publicationIds.filter({ cached[$0] != nil }).count {
        return AppViewUnreadCountsByPublicationResponse(counts: filtered)
      }
    }

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

    if let projectionCache, !counts.isEmpty {
      let expiresAt = Date().addingTimeInterval(AppViewProjectionCacheTTL.unreadCountsSeconds)
      try? await projectionCache.storeUnreadCounts(
        viewerDid: auth.did,
        counts: counts,
        expiresAt: expiresAt
      )
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

  private func invalidateReadStateCaches(viewerDid: String) async throws {
    try await projectionCache?.invalidateUnreadCounts(viewerDid: viewerDid, publicationId: nil)
    try await projectionCache?.invalidateFirstPage(viewerDid: viewerDid, publicationId: nil)
  }

  private func primaryPublicationId(
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String],
    authorDid: String
  ) -> String? {
    if let publicationAtUri, !publicationAtUri.isEmpty {
      return PublicationProjectionLogic.normalizeAtRepoParam(publicationAtUri)
    }
    if let firstScope = publicationScopeAtUris.first, !firstScope.isEmpty {
      return PublicationProjectionLogic.normalizeAtRepoParam(firstScope)
    }
    if let feedUrl = publicationSiteUrls.first, !feedUrl.isEmpty,
       let normalized = RssFeedIdentity.normalizeFeedUrl(feedUrl)
    {
      return PublicationProjectionLogic.rssPublicationId(from: normalized)
    }
    if authorDid.hasPrefix("did:") {
      return authorDid
    }
    return nil
  }
}
