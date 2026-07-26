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

  func cachedFirstPageIfAvailable(
    auth: AuthContext,
    publicationId: String,
    scope: PublicationAppViewScope,
    limit: Int
  ) async throws -> AppViewProjectionCacheEntry<AppViewEntryListResponse>? {
    guard let projectionCache else { return nil }
    guard
      let entry = try await firstPageCacheEntry(
        projectionCache: projectionCache,
        viewerDid: auth.did,
        publicationId: publicationId
      ),
      let cached = try? JSONDecoder().decode(
        AppViewEntryListResponse.self,
        from: Data(entry.value.utf8)
      ),
      !cached.entries.isEmpty
    else { return nil }
    _ = scope
    _ = limit
    return AppViewProjectionCacheEntry(
      value: dedupedPage(cached),
      cachedAt: entry.cachedAt,
      expiresAt: entry.expiresAt,
      source: entry.source
    )
  }

  func liveFirstPage(
    auth: AuthContext,
    scope: PublicationAppViewScope,
    limit: Int
  ) async throws -> AppViewEntryListResponse? {
    let page = try await listEntries(
      auth: auth,
      authorDid: scope.authorDid,
      publicationAtUri: scope.publicationAtUri,
      publicationScopeAtUris: scope.publicationScopeAtUris,
      publicationSiteUrls: scope.publicationSiteUrls,
      filter: .all,
      cursor: nil,
      limit: limit,
      skipFirstPageCache: true
    )
    guard !page.entries.isEmpty else { return nil }
    return dedupedPage(page)
  }

  func cachedOrListedFirstPage(
    auth: AuthContext,
    publicationId: String,
    scope: PublicationAppViewScope,
    limit: Int
  ) async throws -> AppViewEntryListResponse? {
    if let cached = try await cachedFirstPageIfAvailable(
      auth: auth,
      publicationId: publicationId,
      scope: scope,
      limit: limit
    ) {
      return cached.value
    }
    return try await liveFirstPage(auth: auth, scope: scope, limit: limit)
  }

  func listEntries(
    auth: AuthContext,
    authorDid: String,
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String],
    filter: EntryListFilter,
    cursor: String?,
    limit: Int,
    skipFirstPageCache: Bool = false
  ) async throws -> AppViewEntryListResponse {
    if cursor == nil, filter == .all, !skipFirstPageCache, let projectionCache {
      if let publicationId = primaryPublicationId(
        publicationAtUri: publicationAtUri,
        publicationScopeAtUris: publicationScopeAtUris,
        publicationSiteUrls: publicationSiteUrls,
        authorDid: authorDid
      ),
         let entry = try await firstPageCacheEntry(
           projectionCache: projectionCache,
           viewerDid: auth.did,
           publicationId: publicationId
         ),
         let cached = try? JSONDecoder().decode(
           AppViewEntryListResponse.self,
           from: Data(entry.value.utf8)
         )
      {
        return dedupedPage(cached)
      }
    }

    let publicationId = primaryPublicationId(
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls,
      authorDid: authorDid
    )
    let readFloorAt: Date?
    if filter == .unread, let publicationId {
      readFloorAt = try await store.readFloor(viewerDid: auth.did, publicationId: publicationId)
    } else {
      readFloorAt = nil
    }

    let page = try await store.listEntries(
      viewerDid: auth.did,
      authorDid: authorDid,
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls,
      filter: filter,
      cursor: cursor,
      limit: limit,
      readFloorAt: readFloorAt
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
        viewerDid: AppViewProjectionCacheViewerKeys.sharedFirstPage,
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
    let alreadyRead = try? await store.hasReadMark(viewerDid: auth.did, subjectUri: subjectUri)
    try await store.upsertReadMark(
      viewerDid: auth.did,
      subjectUri: subjectUri,
      createdAt: readAt ?? Date()
    )
    if alreadyRead != true {
      try? await store.adjustUnreadCountersForReadState(
        viewerDid: auth.did,
        subjectUri: subjectUri,
        delta: -1
      )
    }
    try await invalidateReadStateCaches(viewerDid: auth.did)
  }

  func deleteReadMark(auth: AuthContext, subjectUri: String) async throws {
    let wasRead = try? await store.hasReadMark(viewerDid: auth.did, subjectUri: subjectUri)
    try await store.deleteReadMark(viewerDid: auth.did, subjectUri: subjectUri)
    if wasRead == true {
      try? await store.adjustUnreadCountersForReadState(
        viewerDid: auth.did,
        subjectUri: subjectUri,
        delta: 1
      )
    }
    try await invalidateReadStateCaches(viewerDid: auth.did)
  }

  func purge(auth: AuthContext) async throws {
    try await store.purgeReadMarks(viewerDid: auth.did)
    try await projectionCache?.invalidateUnreadCounts(viewerDid: auth.did, publicationId: nil)
    logger.info("Purged thin AppView read marks", metadata: ["did": .string(auth.did)])
  }

  func entryDetail(auth: AuthContext, entryId: String) async throws -> AppViewEntryDetailResponse {
    guard let item = try await store.fetchContentItem(uri: entryId) else {
      throw HTTPError(.notFound, message: "Entry not found in AppView index")
    }
    let render = try await store.fetchContentRender(uri: entryId)
    let isRead = try await store.hasReadMark(viewerDid: auth.did, subjectUri: entryId)
    let originalUrl = RssFeedIdentity.originalArticleURL(
      forEntryId: entryId,
      render: render,
      summary: item.summary
    )
    return AppViewEntryDetailResponse(
      entryId: item.entryId,
      title: item.title,
      summary: item.summary,
      publishedAt: item.publishedAt,
      thumbnailUrl: item.thumbnailUrl,
      isRead: isRead,
      contentHtml: render?.contentHtml ?? render?.summary ?? item.summary,
      originalUrl: originalUrl
    )
  }

  func unreadCountsByPublicationIds(
    auth: AuthContext,
    publicationIds: [String],
    projectionService: PublicationProjectionService
  ) async throws -> AppViewUnreadCountsByPublicationResponse {
    var rowsById: [String: SidebarPublicationRow] = [:]
    for publicationId in publicationIds {
      if let row = await projectionService.sidebarRow(for: auth.did, publicationId: publicationId) {
        rowsById[publicationId] = row
      }
    }
    let resolvedRows = rowsById

    var rowsForCounters = publicationIds.compactMap { resolvedRows[$0] }

    if rowsForCounters.count < publicationIds.count {
      let missingIds = publicationIds.filter { resolvedRows[$0] == nil }
      if !missingIds.isEmpty {
        let sidebar = try await projectionService.sidebar(auth: auth, phase: .full)
        for publicationId in missingIds {
          guard let row = sidebar.allPublicationRows.first(where: {
            PublicationProjectionLogic.publicationIdsMatch($0.publicationId, publicationId)
          }) else {
            continue
          }
          rowsById[publicationId] = row
        }
        rowsForCounters = publicationIds.compactMap { rowsById[$0] }
      }
    }

    var snapshot = await projectionService.unreadCounterSnapshot(
      for: rowsForCounters,
      viewerDid: auth.did
    )
    if snapshot.dirty || !snapshot.missingPublicationIds.isEmpty {
      snapshot = await projectionService.refreshUnreadCounterSnapshot(
        for: rowsForCounters,
        viewerDid: auth.did
      )
    }

    if let projectionCache, !snapshot.counts.isEmpty {
      let expiresAt = Date().addingTimeInterval(AppViewProjectionCacheTTL.unreadCountsSeconds)
      try? await projectionCache.storeUnreadCounts(
        viewerDid: auth.did,
        counts: snapshot.counts,
        expiresAt: expiresAt
      )
    }

    return AppViewUnreadCountsByPublicationResponse(
      counts: snapshot.counts,
      generation: snapshot.generation,
      accuracy: snapshot.accuracy.rawValue,
      countedAt: snapshot.countedAt
    )
  }

  func markAllRead(
    auth: AuthContext,
    rows: [SidebarPublicationRow]
  ) async throws -> (counters: [AppViewUnreadCounter], marked: Int) {
    let publicationIds = rows.map(\.publicationId)
    let existing = (try? await store.fetchUnreadCounters(
      viewerDid: auth.did,
      publicationIds: publicationIds
    )) ?? []
    let marked = existing.reduce(0) { $0 + $1.unreadCount }
    let counters = try await store.markAllReadCounters(
      viewerDid: auth.did,
      publicationIds: publicationIds,
      readAt: Date()
    )
    try await projectionCache?.invalidateUnreadCounts(viewerDid: auth.did, publicationId: nil)
    return (counters, marked)
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
  }

  private func firstPageCacheEntry(
    projectionCache: any AppViewProjectionCacheStore,
    viewerDid: String,
    publicationId: String
  ) async throws -> AppViewProjectionCacheEntry<String>? {
    if let viewerEntry = try await projectionCache.firstPageCacheEntry(
      viewerDid: viewerDid,
      publicationId: publicationId
    ) {
      return viewerEntry
    }
    return try await projectionCache.firstPageCacheEntry(
      viewerDid: AppViewProjectionCacheViewerKeys.sharedFirstPage,
      publicationId: publicationId
    )
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
