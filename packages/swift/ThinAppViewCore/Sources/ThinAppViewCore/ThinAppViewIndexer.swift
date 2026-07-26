import AsyncHTTPClient
import Foundation
import Logging

enum ThinAppViewIndexingOutcome: Equatable, Sendable {
  case projectionMutation
  case skipped

  var didMutateProjection: Bool { self == .projectionMutation }
}

/// Indexes Skyreader feed subscriptions into the thin AppView store.
public actor ThinAppViewIndexer {
  private let store: any ThinAppViewStore
  private let config: ThinAppViewConfig
  private let logger: Logger
  private let httpClient: HTTPClient?
  private let plcURL: String?
  private let rssIngestion: ThinAppViewRssIngestion?
  private let projectionCache: (any AppViewProjectionCacheStore)?
  private var pdsBaseCache: [String: String] = [:]

  public init(
    store: any ThinAppViewStore,
    config: ThinAppViewConfig,
    logger: Logger,
    httpClient: HTTPClient? = nil,
    plcURL: String? = nil,
    rssIngestion: ThinAppViewRssIngestion? = nil,
    projectionCache: (any AppViewProjectionCacheStore)? = nil
  ) {
    self.store = store
    self.config = config
    self.logger = logger
    self.httpClient = httpClient
    self.plcURL = plcURL
    self.rssIngestion = rssIngestion
    self.projectionCache = projectionCache
  }

  public func handleCommit(
    repoDid: String,
    collection: String,
    rkey: String,
    cid: String,
    recordJSON: Data,
    operation: String,
    pdsBase: String? = nil,
    ingestionSource: String? = nil,
    ingestionEnvironment: String? = nil,
    repoRev: String? = nil,
    cursor: String? = nil,
    eventTime: Date? = nil
  ) async throws {
    _ = try await handleCommitWithOutcome(
      repoDid: repoDid,
      collection: collection,
      rkey: rkey,
      cid: cid,
      recordJSON: recordJSON,
      operation: operation,
      pdsBase: pdsBase,
      ingestionSource: ingestionSource,
      ingestionEnvironment: ingestionEnvironment,
      repoRev: repoRev,
      cursor: cursor,
      eventTime: eventTime
    )
  }

  func handleCommitWithOutcome(
    repoDid: String,
    collection: String,
    rkey: String,
    cid: String,
    recordJSON: Data,
    operation: String,
    pdsBase: String? = nil,
    ingestionSource: String? = nil,
    ingestionEnvironment: String? = nil,
    repoRev: String? = nil,
    cursor: String? = nil,
    eventTime: Date? = nil
  ) async throws -> ThinAppViewIndexingOutcome {
    let record = (try JSONSerialization.jsonObject(with: recordJSON) as? [String: Any]) ?? [:]

    if collection == RssFeedLexicons.skyreaderFeedSubscription {
      return try await handleSkyreaderSubscriptionCommit(
        repoDid: repoDid,
        record: record,
        operation: operation
      )
    }

    if collection == ThinAppViewConfig.graphSubscriptionCollection {
      return try await handleGraphSubscriptionCommit(
        repoDid: repoDid,
        record: record,
        operation: operation
      )
    }

    guard ThinAppViewConfig.contentCollections.contains(collection) else { return .skipped }

    let uri = RenderFieldExtractor.buildEntryUri(did: repoDid, collection: collection, rkey: rkey)
    if operation == "delete" {
      if ingestionSource == "tap",
         let ingestionEnvironment,
         let eventId = cursor.flatMap(Int64.init)
      {
        let now = Date()
        try await store.applyTapContentMutation(
          .delete(uri: uri, authorDid: repoDid, collection: collection),
          environment: ingestionEnvironment,
          eventId: eventId,
          repoRev: repoRev ?? "",
          eventTime: eventTime ?? now,
          observedAt: now
        )
        return .projectionMutation
      }
      let publicationSite = RenderFieldExtractor.publicationSiteField(from: record)
      try await store.deleteContentItem(uri: uri)
      try await store.markUnreadCountersDirtyForContent(
        authorDid: repoDid,
        publicationSite: publicationSite
      )
      try await invalidateFirstPageCaches(for: publicationSite)
      return .projectionMutation
    }

    let resolvedPds: String?
    if let pdsBase {
      resolvedPds = pdsBase
    } else {
      resolvedPds = await resolvePdsBase(for: repoDid)
    }
    let render = RenderFieldExtractor.extractRenderFields(
      from: record,
      repoDid: repoDid,
      pdsBase: resolvedPds
    )
    let createdAt = RenderFieldExtractor.createdAtDate(from: record, fallback: render)
    let now = Date()
    let item = IndexedContentItem(
      uri: uri,
      cid: cid,
      authorDid: repoDid,
      collection: collection,
      createdAt: createdAt,
      indexedAt: now,
      publicationSite: RenderFieldExtractor.publicationSiteField(from: record),
      render: render,
      expiresAt: now.addingTimeInterval(config.contentRetentionSeconds)
    )
    if ingestionSource == "tap",
       let ingestionEnvironment,
       let eventId = cursor.flatMap(Int64.init)
    {
      try await store.applyTapContentMutation(
        .upsert(item),
        environment: ingestionEnvironment,
        eventId: eventId,
        repoRev: repoRev ?? "",
        eventTime: eventTime ?? now,
        observedAt: now
      )
      return .projectionMutation
    }
    let itemAlreadyIndexed = try await store.fetchContentItem(uri: uri) != nil
    try await store.upsertContentItem(item)
    if itemAlreadyIndexed {
      try await store.markUnreadCountersDirtyForContent(
        authorDid: repoDid,
        publicationSite: item.publicationSite
      )
    } else {
      try await store.incrementUnreadCountersForContentItem(item)
    }
    try await invalidateFirstPageCaches(for: item.publicationSite)
    return .projectionMutation
  }

  /// Applies authoritative account lifecycle evidence from Tap.
  public func handleIdentity(
    repoDid: String,
    status: TapAccountStatus,
    isActive: Bool
  ) async throws {
    _ = try await handleIdentityWithOutcome(
      repoDid: repoDid,
      status: status,
      isActive: isActive
    )
  }

  func handleIdentityWithOutcome(
    repoDid: String,
    status: TapAccountStatus,
    isActive: Bool
  ) async throws -> ThinAppViewIndexingOutcome {
    pdsBaseCache.removeValue(forKey: repoDid)
    guard !isActive || !status.isActive else { return .skipped }
    _ = try await store.deleteContentItems(authorDid: repoDid)
    try await projectionCache?.invalidateAllProjectionCaches()
    return .projectionMutation
  }

  private func handleSkyreaderSubscriptionCommit(
    repoDid: String,
    record: [String: Any],
    operation: String
  ) async throws -> ThinAppViewIndexingOutcome {
    let normalizedFeedUrl = ThinAppViewRssIngestion.feedUrl(fromSubscriptionRecord: record)
    var didMutateProjection = false

    if operation != "delete", let normalizedFeedUrl, let rssIngestion {
      _ = try await rssIngestion.ingestFeed(normalizedFeedUrl: normalizedFeedUrl)
      didMutateProjection = true
    }

    guard let projectionCache else {
      return didMutateProjection ? .projectionMutation : .skipped
    }

    try await ThinAppViewProjectionCacheWarmer.invalidateViewerSubscriptionCaches(
      projectionCache: projectionCache,
      viewerDid: repoDid
    )

    if let normalizedFeedUrl {
      try await ThinAppViewProjectionCacheWarmer.invalidateFirstPageKeys(
        projectionCache: projectionCache,
        viewerDid: repoDid,
        publicationId: RssFeedIdentity.rssPublicationId(from: normalizedFeedUrl)
      )
      if operation != "delete" {
        try await ThinAppViewProjectionCacheWarmer.warmRssFirstPage(
          store: store,
          projectionCache: projectionCache,
          viewerDid: repoDid,
          normalizedFeedUrl: normalizedFeedUrl
        )
      }
    }
    return .projectionMutation
  }

  private func handleGraphSubscriptionCommit(
    repoDid: String,
    record: [String: Any],
    operation: String
  ) async throws -> ThinAppViewIndexingOutcome {
    guard let projectionCache else { return .skipped }

    try await ThinAppViewProjectionCacheWarmer.invalidateViewerSubscriptionCaches(
      projectionCache: projectionCache,
      viewerDid: repoDid
    )

    if operation != "delete",
       let publication = (record["publication"] as? String)?
         .trimmingCharacters(in: .whitespacesAndNewlines),
       !publication.isEmpty
    {
      try await ThinAppViewProjectionCacheWarmer.invalidateFirstPageKeys(
        projectionCache: projectionCache,
        viewerDid: repoDid,
        publicationId: publication
      )
    }
    return .projectionMutation
  }

  private func invalidateFirstPageCaches(for publicationSite: String?) async throws {
    guard let projectionCache, let publicationSite else { return }
    var publicationIds = RenderFieldExtractor.publicationFilterEquivalenceKeys(
      publicationAtUri: publicationSite
    )
    if publicationIds.isEmpty,
       let canonical = RenderFieldExtractor.canonicalPublicationAtUriKey(publicationSite)
    {
      publicationIds.insert(canonical)
    }
    if let normalized = RenderFieldExtractor.normalizePublicationSiteUrl(publicationSite) {
      publicationIds.insert(normalized)
    }
    if let normalized = RssFeedIdentity.normalizeFeedUrl(publicationSite) {
      publicationIds.insert(normalized)
      publicationIds.insert(RssFeedIdentity.rssPublicationId(from: normalized))
    }
    for publicationId in publicationIds {
      try await projectionCache.invalidateFirstPageForAllViewers(publicationId: publicationId)
    }
  }

  private func resolvePdsBase(for repoDid: String) async -> String? {
    if let cached = pdsBaseCache[repoDid] { return cached }
    guard let httpClient, let plcURL else { return nil }
    let resolved = try? await ThinAppViewPdsResolution.resolvePdsBase(
      repoDid: repoDid,
      plcBase: plcURL,
      httpClient: httpClient
    )
    if let resolved {
      pdsBaseCache[repoDid] = resolved
    }
    return resolved
  }
}
