import Foundation
import GatewayCore
import Hummingbird
import Logging
import OperationsCore
import ThinAppViewCore

actor ThinAppViewReadService {
  private let store: any ThinAppViewStore
  private let projectionCache: (any AppViewProjectionCacheStore)?
  private let telemetry: OperationsTelemetryBuffer?
  private let logger: Logger
  private let circlePrivateState: (any CirclePrivateStateStoring)?

  init(
    store: any ThinAppViewStore,
    projectionCache: (any AppViewProjectionCacheStore)? = nil,
    telemetry: OperationsTelemetryBuffer? = nil,
    circlePrivateState: (any CirclePrivateStateStoring)? = nil,
    logger: Logger
  ) {
    self.store = store
    self.projectionCache = projectionCache
    self.telemetry = telemetry
    self.circlePrivateState = circlePrivateState
    self.logger = logger
  }

  func cachedFirstPageIfAvailable(
    auth: AuthContext,
    publicationId: String,
    scope: PublicationAppViewScope,
    limit: Int
  ) async throws -> AppViewProjectionCacheEntry<AppViewEntryListResponse>? {
    guard let projectionCache else { return nil }
    let lookup = try await firstPageCacheLookup(
      projectionCache: projectionCache,
      viewerDid: auth.did,
      publicationId: publicationId
    )
    let entry: AppViewProjectionCacheEntry<String>
    let stale: Bool
    switch lookup {
    case .fresh(let cached):
      entry = cached
      stale = false
    case .stale(let cached):
      entry = cached
      stale = true
    case .miss:
      return nil
    }
    guard
      let cached = try? JSONDecoder().decode(
        AppViewEntryListResponse.self,
        from: Data(entry.value.utf8)
      ),
      !cached.entries.isEmpty
    else { return nil }
    if stale {
      scheduleFirstPageRefresh(auth: auth, publicationId: publicationId, scope: scope, limit: limit)
    }
    // Cached pages are serialized pre-read-state (shared across viewers, so
    // every entry carries isRead: false); re-resolve per viewer or bootstrap
    // re-emits already-read entries as unread until the cache TTL expires.
    let page = try await authoritativePage(
      cached,
      viewerDid: auth.did,
      publicationId: publicationId
    )
    return AppViewProjectionCacheEntry(
      value: page,
      cachedAt: entry.cachedAt,
      freshUntil: entry.freshUntil,
      hardExpiresAt: entry.hardExpiresAt,
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
    if cursor == nil, filter == .all, !skipFirstPageCache {
      if let publicationId = primaryPublicationId(
        publicationAtUri: publicationAtUri,
        publicationScopeAtUris: publicationScopeAtUris,
        publicationSiteUrls: publicationSiteUrls,
        authorDid: authorDid
      ),
         let cached = try await cachedFirstPageIfAvailable(
           auth: auth,
           publicationId: publicationId,
           scope: PublicationAppViewScope(
             authorDid: authorDid,
             publicationAtUri: publicationAtUri,
             publicationScopeAtUris: publicationScopeAtUris,
             publicationSiteUrls: publicationSiteUrls
           ),
           limit: limit
         )
      {
        return cached.value
      }
    }

    var firstPageLease: AppViewProjectionRefreshLease?
    if cursor == nil,
       filter == .all,
       !skipFirstPageCache,
       let projectionCache,
       let publicationId = primaryPublicationId(
         publicationAtUri: publicationAtUri,
         publicationScopeAtUris: publicationScopeAtUris,
         publicationSiteUrls: publicationSiteUrls,
         authorDid: authorDid
       )
    {
      firstPageLease = await projectionCache.acquireRefreshLease(
        domain: "firstpage",
        resource: publicationId,
        ttl: 10
      )
      if firstPageLease == nil {
        try? await Task.sleep(for: .milliseconds(250))
        if let cached = try await cachedFirstPageIfAvailable(
          auth: auth,
          publicationId: publicationId,
          scope: PublicationAppViewScope(
            authorDid: authorDid,
            publicationAtUri: publicationAtUri,
            publicationScopeAtUris: publicationScopeAtUris,
            publicationSiteUrls: publicationSiteUrls
          ),
          limit: limit
        ) {
          return cached.value
        }
      }
    }
    let firstPageRenewal = firstPageLease.flatMap { lease in
      projectionCache.map { refreshLeaseRenewal(lease, projectionCache: $0) }
    }
    defer {
      firstPageRenewal?.cancel()
      if let firstPageLease, let projectionCache {
        Task { await projectionCache.releaseRefreshLease(firstPageLease) }
      }
    }

    let publicationId = primaryPublicationId(
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls,
      authorDid: authorDid
    )
    let readBoundary: ReadWatermarkBoundary?
    if filter != .all, let publicationId {
      readBoundary = try await store.readBoundary(
        viewerDid: auth.did,
        publicationId: publicationId
      )
    } else {
      readBoundary = nil
    }

    let rebuildStarted = Date()
    let page = try await store.listEntries(
      viewerDid: auth.did,
      authorDid: authorDid,
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls,
      filter: filter,
      cursor: cursor,
      limit: limit,
      readBoundary: readBoundary
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
      recordMetric(
        name: "socialwire.appview.cache.rebuild.duration_seconds",
        value: Date().timeIntervalSince(rebuildStarted),
        dimensions: ["cache_type": "first_page"]
      )
    }

    return try await authoritativePage(
      page,
      viewerDid: auth.did,
      publicationId: publicationId
    )
  }

  private func dedupedPage(_ page: AppViewEntryListResponse) -> AppViewEntryListResponse {
    AppViewEntryListResponse(
      entries: RssFeedIdentity.dedupeEntryListItems(page.entries),
      cursor: page.cursor
    )
  }

  private func recordMetric(name: String, value: Double, dimensions: [String: String]) {
    guard let telemetry else { return }
    Task {
      _ = await telemetry.enqueue(.metric(
        OperationsMetricSample(name: name, value: value, dimensions: dimensions)
      ))
    }
  }

  private func authoritativePage(
    _ page: AppViewEntryListResponse,
    viewerDid: String,
    publicationId: String?
  ) async throws -> AppViewEntryListResponse {
    let neutral = dedupedPage(page)
    let scopedEntries = neutral.entries.map { entry in
      if let publicationId {
        return entry.withPublicationId(publicationId)
      }
      return entry
    }
    let states = try await store.readStates(viewerDid: viewerDid, entries: scopedEntries)
    return AppViewEntryListResponse(
      entries: scopedEntries.map {
        $0.withReadState(states[$0.entryId] ?? false)
      },
      cursor: neutral.cursor
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

  func listFeed(
    auth: AuthContext,
    publications: [SidebarPublicationRow],
    filter: EntryListFilter,
    cursor: String?,
    limit: Int
  ) async throws -> AppViewEntryListResponse {
    let pageLimit = max(1, min(limit, 100))
    let scopes = publications.map { publication in
      let scope = publication.appViewScope
      return PublicationUnreadScope(
        publicationId: publication.publicationId,
        authorDid: scope.authorDid,
        publicationAtUri: scope.publicationAtUri,
        publicationScopeAtUris: scope.publicationScopeAtUris,
        publicationSiteUrls: scope.publicationSiteUrls
      )
    }
    let page = try await store.listFeedEntries(
      viewerDid: auth.did,
      scopes: scopes,
      filter: filter,
      cursor: cursor,
      limit: min(100, pageLimit + 1)
    )
    let deduped = RssFeedIdentity.dedupeEntryListItems(page.entries)
    let entries = Array(deduped.prefix(pageLimit))
    let hasMore = page.cursor != nil || deduped.count > pageLimit
    return AppViewEntryListResponse(
      entries: entries,
      cursor: hasMore ? entries.last.map {
        ThinAppViewCursor.encode(createdAt: $0.feedPositionAt, uri: $0.entryId)
      } : nil
    )
  }

  func listFeed(
    auth: AuthContext,
    selector: AppViewFeedSelector,
    filter: EntryListFilter,
    cursor: String?,
    limit: Int
  ) async throws -> AppViewFeedPage? {
    try await store.listFeedEntries(
      viewerDid: auth.did,
      selector: selector,
      filter: filter,
      cursor: cursor,
      limit: limit
    )
  }

  func hasFeedProjection(auth: AuthContext) async throws -> Bool {
    try await store.hasViewerFeedProjection(viewerDid: auth.did)
  }

  func listSubscribedFeed(
    auth: AuthContext,
    filter: EntryListFilter,
    cursor: String?,
    limit: Int
  ) async throws -> AppViewEntryListResponse? {
    let scopes = try await store.publicationScopes(
      viewerDid: auth.did,
      sectionKey: "subscribed"
    )
    guard !scopes.isEmpty else { return nil }

    let result = try await store.listAggregateEntries(
      viewerDid: auth.did,
      scopes: scopes,
      filter: filter,
      cursor: cursor,
      limit: limit
    )
    await recordSubscribedFeedMetrics(
      result: result,
      pageKind: cursor == nil ? "first_page" : "pagination"
    )
    return result.response
  }

  private func recordSubscribedFeedMetrics(
    result: AppViewAggregatePageResult,
    pageKind: String
  ) async {
    guard let telemetry else { return }
    let dimensions = Self.subscribedFeedMetricDimensions(pageKind: pageKind)
    _ = await telemetry.enqueue(
      .metric(
        .init(
          name: "socialwire.appview.feed.query_duration_seconds",
          value: result.diagnostics.queryDuration,
          dimensions: dimensions
        )
      )
    )
    _ = await telemetry.enqueue(
      .metric(
        .init(
          name: "socialwire.appview.feed.rows_scanned",
          value: Double(result.diagnostics.rowsScanned),
          dimensions: dimensions
        )
      )
    )
    _ = await telemetry.enqueue(
      .metric(
        .init(
          name: "socialwire.appview.feed.rows_returned",
          value: Double(result.diagnostics.rowsReturned),
          dimensions: dimensions
        )
      )
    )
    _ = await telemetry.enqueue(
      .metric(
        .init(
          name: "socialwire.appview.feed.duplicates_suppressed",
          value: Double(result.diagnostics.duplicatesSuppressed),
          dimensions: dimensions
        )
      )
    )
    if let payload = try? JSONEncoder().encode(result.response) {
      _ = await telemetry.enqueue(
        .metric(
          .init(
            name: "socialwire.appview.feed.payload_bytes",
            value: Double(payload.count),
            dimensions: dimensions
          )
        )
      )
    }
  }

  static func subscribedFeedMetricDimensions(pageKind: String) -> [String: String] {
    [
      "feed_kind": "subscribed",
      "page_kind": pageKind,
    ]
  }

  func upsertReadMark(auth: AuthContext, subjectUri: String, readAt: Date?) async throws {
    let alreadyRead = try? await authoritativeReadState(
      viewerDid: auth.did,
      subjectUri: subjectUri
    )
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
    try await invalidateReadStateCaches(viewerDid: auth.did, subjectUri: subjectUri)
  }

  func deleteReadMark(auth: AuthContext, subjectUri: String) async throws {
    let wasRead = try? await authoritativeReadState(
      viewerDid: auth.did,
      subjectUri: subjectUri
    )
    try await store.markEntryUnread(
      viewerDid: auth.did,
      subjectUri: subjectUri,
      createdAt: Date()
    )
    if wasRead == true {
      try? await store.adjustUnreadCountersForReadState(
        viewerDid: auth.did,
        subjectUri: subjectUri,
        delta: 1
      )
    }
    try await invalidateReadStateCaches(viewerDid: auth.did, subjectUri: subjectUri)
  }

  private func authoritativeReadState(
    viewerDid: String,
    subjectUri: String
  ) async throws -> Bool {
    guard let item = try await store.fetchContentItem(uri: subjectUri) else {
      return try await store.hasReadMark(viewerDid: viewerDid, subjectUri: subjectUri)
    }
    return try await store.readStates(viewerDid: viewerDid, entries: [item])[subjectUri] ?? false
  }

  func purge(auth: AuthContext) async throws {
    try await store.purgeReadMarks(viewerDid: auth.did)
    try await circlePrivateState?.purge(viewerDID: auth.did)
    try await projectionCache?.invalidateUnreadCounts(viewerDid: auth.did, publicationId: nil)
    logger.info("Purged private AppView viewer state")
  }

  func entryDetail(auth: AuthContext, entryId: String) async throws -> AppViewEntryDetailResponse {
    guard let item = try await store.fetchContentItem(uri: entryId) else {
      throw HTTPError(.notFound, message: "Entry not found in AppView index")
    }
    let render = try await store.fetchContentRender(uri: entryId)
    let isRead = try await store.readStates(viewerDid: auth.did, entries: [item])[entryId] ?? false
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
      var missingIds = publicationIds.filter { rowsById[$0] == nil }
      if !missingIds.isEmpty {
        // Try the durable, cross-restart projection cache before paying for a live
        // discovery pass — the in-memory sidebarRow cache misses on every cold process
        // (deploys, restarts, a different replica), which otherwise turns a routine
        // unread-count refresh into a full live PDS re-crawl that can time out.
        if let cachedSidebar = await projectionService.cachedSidebarResponse(viewerDid: auth.did) {
          for publicationId in missingIds {
            guard let row = cachedSidebar.allPublicationRows.first(where: {
              PublicationProjectionLogic.publicationIdsMatch($0.publicationId, publicationId)
            }) else {
              continue
            }
            rowsById[publicationId] = row
          }
          missingIds = publicationIds.filter { rowsById[$0] == nil }
        }
      }
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
      }
      rowsForCounters = publicationIds.compactMap { rowsById[$0] }
    }

    let snapshot = await projectionService.cachedUnreadCounterSnapshot(
      for: rowsForCounters,
      viewerDid: auth.did
    )
    if snapshot.dirty || !snapshot.missingPublicationIds.isEmpty {
      Task {
        _ = await projectionService.refreshUnreadCounterSnapshot(
          for: rowsForCounters,
          viewerDid: auth.did
        )
      }
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
  ) async throws -> (
    counters: [AppViewUnreadCounter],
    boundaries: [ReadWatermarkBoundary],
    confirmedAt: Date,
    marked: Int
  ) {
    let publicationIds = rows.map(\.publicationId)
    let existing = (try? await store.fetchUnreadCounters(
      viewerDid: auth.did,
      publicationIds: publicationIds
    )) ?? []
    let marked = existing.reduce(0) { $0 + $1.unreadCount }
    let confirmedAt = Date()
    let scopes = rows.map {
      PublicationUnreadScope(
        publicationId: $0.publicationId,
        authorDid: $0.appViewScope.authorDid,
        publicationAtUri: $0.appViewScope.publicationAtUri,
        publicationScopeAtUris: $0.appViewScope.publicationScopeAtUris,
        publicationSiteUrls: $0.appViewScope.publicationSiteUrls
      )
    }
    let confirmed = try await store.markAllReadCounters(
      viewerDid: auth.did,
      scopes: scopes,
      readAt: confirmedAt
    )
    for publicationId in Set(rows.map(\.publicationId)) {
      try await projectionCache?.invalidateUnreadCounts(
        viewerDid: auth.did,
        publicationId: publicationId
      )
    }
    return (confirmed.counters, confirmed.boundaries, confirmedAt, marked)
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

  private func invalidateReadStateCaches(viewerDid: String, subjectUri: String) async throws {
    let publicationId = try? await store.fetchContentItem(uri: subjectUri)?.publicationId
    try await projectionCache?.invalidateUnreadCounts(
      viewerDid: viewerDid,
      publicationId: publicationId ?? nil
    )
  }

  private func firstPageCacheLookup(
    projectionCache: any AppViewProjectionCacheStore,
    viewerDid: String,
    publicationId: String
  ) async throws -> AppViewProjectionCacheLookup<String> {
    let viewerLookup = try await projectionCache.firstPageCacheLookup(
      viewerDid: viewerDid,
      publicationId: publicationId
    )
    switch viewerLookup {
    case .fresh, .stale:
      return viewerLookup
    case .miss:
      return try await projectionCache.firstPageCacheLookup(
        viewerDid: AppViewProjectionCacheViewerKeys.sharedFirstPage,
        publicationId: publicationId
      )
    }
  }

  private func scheduleFirstPageRefresh(
    auth: AuthContext,
    publicationId: String,
    scope: PublicationAppViewScope,
    limit: Int
  ) {
    Task {
      guard let projectionCache = self.projectionCache,
            let lease = await projectionCache.acquireRefreshLease(
              domain: "firstpage",
              resource: publicationId,
              ttl: 10
            )
      else { return }
      let renewal = self.refreshLeaseRenewal(lease, projectionCache: projectionCache)
      defer {
        renewal.cancel()
        Task { await projectionCache.releaseRefreshLease(lease) }
      }
      _ = try? await self.listEntries(
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
    }
  }

  private func refreshLeaseRenewal(
    _ lease: AppViewProjectionRefreshLease,
    projectionCache: any AppViewProjectionCacheStore
  ) -> Task<Void, Never> {
    Task {
      let interval = max(1, lease.ttlMilliseconds / 3)
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(interval))
        guard !Task.isCancelled else { return }
        guard await projectionCache.renewRefreshLease(lease) else { return }
      }
    }
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
