import AsyncHTTPClient
import Foundation
import Logging

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
    pdsBase: String? = nil
  ) async throws {
    let record = (try JSONSerialization.jsonObject(with: recordJSON) as? [String: Any]) ?? [:]

    if collection == RssFeedLexicons.skyreaderFeedSubscription {
      if operation != "delete", let rssIngestion {
        if let feedUrl = ThinAppViewRssIngestion.feedUrl(fromSubscriptionRecord: record) {
          _ = try? await rssIngestion.ingestFeed(normalizedFeedUrl: feedUrl)
        }
      }
      return
    }

    if ThinAppViewConfig.readStateCollection == collection {
      try await handleReadStateCommit(repoDid: repoDid, rkey: rkey, record: record, operation: operation)
      return
    }

    guard ThinAppViewConfig.contentCollections.contains(collection) else { return }

    let uri = RenderFieldExtractor.buildEntryUri(did: repoDid, collection: collection, rkey: rkey)
    if operation == "delete" {
      let publicationSite = RenderFieldExtractor.publicationSiteField(from: record)
      try await store.deleteContentItem(uri: uri)
      await invalidateFirstPageCaches(for: publicationSite)
      return
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
    try await store.upsertContentItem(item)
    await invalidateFirstPageCaches(for: item.publicationSite)
  }

  private func invalidateFirstPageCaches(for publicationSite: String?) async {
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
    for publicationId in publicationIds {
      try? await projectionCache.invalidateFirstPageForAllViewers(publicationId: publicationId)
    }
  }

  private func handleReadStateCommit(
    repoDid: String,
    rkey: String,
    record: [String: Any],
    operation: String
  ) async throws {
    guard let subjectUri = record["subjectUri"] as? String else { return }
    if operation == "delete" {
      try await store.deleteReadMark(viewerDid: repoDid, subjectUri: subjectUri)
      return
    }

    let readAtRaw = (record["readAt"] as? String) ?? (record["updatedAt"] as? String)
    let readAt = readAtRaw.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
    try await store.upsertReadMark(viewerDid: repoDid, subjectUri: subjectUri, createdAt: readAt)
    _ = rkey
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
