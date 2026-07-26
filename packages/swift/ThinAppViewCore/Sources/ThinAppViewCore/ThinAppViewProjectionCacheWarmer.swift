import Foundation

/// Invalidates and optionally warms AppView projection caches after viewer subscription changes.
enum ThinAppViewProjectionCacheWarmer {
  static func invalidateViewerSubscriptionCaches(
    projectionCache: any AppViewProjectionCacheStore,
    viewerDid: String
  ) async throws {
    try await projectionCache.invalidateSidebarProjection(viewerDid: viewerDid)
    try await projectionCache.invalidateUnreadCounts(viewerDid: viewerDid, publicationId: nil)
  }

  static func invalidateFirstPageKeys(
    projectionCache: any AppViewProjectionCacheStore,
    viewerDid: String,
    publicationId: String
  ) async throws {
    var keys = RenderFieldExtractor.publicationFilterEquivalenceKeys(publicationAtUri: publicationId)
    if keys.isEmpty {
      keys.insert(publicationId)
    }
    if let normalized = RssFeedIdentity.normalizeFeedUrl(publicationId) {
      keys.insert(normalized)
    }
    if let normalized = RenderFieldExtractor.normalizePublicationSiteUrl(publicationId) {
      keys.insert(normalized)
    }
    for key in keys {
      try await projectionCache.invalidateFirstPage(viewerDid: viewerDid, publicationId: key)
      try await projectionCache.invalidateFirstPage(
        viewerDid: AppViewProjectionCacheViewerKeys.sharedFirstPage,
        publicationId: key
      )
    }
  }

  static func warmRssFirstPage(
    store: any ThinAppViewStore,
    projectionCache: any AppViewProjectionCacheStore,
    viewerDid: String,
    normalizedFeedUrl: String,
    limit: Int = 50
  ) async throws {
    let publicationId = RssFeedIdentity.rssPublicationId(from: normalizedFeedUrl)
    let page = try await store.listEntries(
      viewerDid: viewerDid,
      authorDid: RssFeedLexicons.rssAuthorDid,
      publicationAtUri: nil,
      publicationScopeAtUris: [],
      publicationSiteUrls: [normalizedFeedUrl],
      filter: .all,
      cursor: nil,
      limit: limit
    )
    guard !page.entries.isEmpty else { return }

    let response = AppViewEntryListResponse(
      entries: RssFeedIdentity.dedupeEntryListItems(page.entries),
      cursor: page.cursor
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard
      let data = try? encoder.encode(response),
      let json = String(data: data, encoding: .utf8)
    else { return }

    let expiresAt = Date().addingTimeInterval(AppViewProjectionCacheTTL.firstPageSeconds)
    try await projectionCache.storeFirstPageJSON(
      viewerDid: AppViewProjectionCacheViewerKeys.sharedFirstPage,
      publicationId: publicationId,
      jsonBody: json,
      expiresAt: expiresAt
    )
  }
}
