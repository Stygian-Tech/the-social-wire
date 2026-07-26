import Foundation

public struct RssFeedFetchMetadata: Sendable {
  public let normalizedFeedUrl: String
  public let etag: String?
  public let lastModified: String?
  public let lastPollAt: Date?
  public let backoffUntil: Date?
  public let consecutiveErrorCount: Int

  public init(
    normalizedFeedUrl: String,
    etag: String?,
    lastModified: String?,
    lastPollAt: Date?,
    backoffUntil: Date?,
    consecutiveErrorCount: Int
  ) {
    self.normalizedFeedUrl = normalizedFeedUrl
    self.etag = etag
    self.lastModified = lastModified
    self.lastPollAt = lastPollAt
    self.backoffUntil = backoffUntil
    self.consecutiveErrorCount = consecutiveErrorCount
  }
}

/// Persistence for thin AppView `content_items` and `read_marks`.
public protocol ThinAppViewStore: Actor {
  func ping() async throws
  func upsertContentItem(_ item: IndexedContentItem) async throws
  func deleteContentItem(uri: String) async throws
  func deleteContentItems(authorDid: String) async throws -> Int
  func fetchContentIdentity(uri: String) async throws -> IndexedContentIdentity?

  func upsertReadMark(viewerDid: String, subjectUri: String, createdAt: Date) async throws
  func deleteReadMark(viewerDid: String, subjectUri: String) async throws
  func purgeReadMarks(viewerDid: String) async throws

  func fetchContentItem(uri: String) async throws -> AppViewEntryListItem?
  func hasReadMark(viewerDid: String, subjectUri: String) async throws -> Bool

  func listEntries(
    viewerDid: String,
    authorDid: String,
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String],
    filter: EntryListFilter,
    cursor: String?,
    limit: Int,
    readFloorAt: Date?
  ) async throws -> AppViewEntryListResponse

  func readFloor(viewerDid: String, publicationId: String) async throws -> Date?

  func countUnreadEntries(
    viewerDid: String,
    authorDid: String,
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String]
  ) async throws -> Int

  func countUnreadEntriesBatch(
    viewerDid: String,
    scopes: [PublicationUnreadScope]
  ) async throws -> [String: Int]

  func upsertPublicationScopes(_ scopes: [AppViewPublicationScope]) async throws

  func replacePublicationScopes(
    viewerDid: String,
    scopes: [AppViewPublicationScope]
  ) async throws

  func fetchUnreadCounters(
    viewerDid: String,
    publicationIds: [String]?
  ) async throws -> [AppViewUnreadCounter]

  func refreshUnreadCounters(
    viewerDid: String,
    scopes: [PublicationUnreadScope]
  ) async throws -> [AppViewUnreadCounter]

  func incrementUnreadCountersForContentItem(_ item: IndexedContentItem) async throws

  func markUnreadCountersDirtyForContent(authorDid: String, publicationSite: String?) async throws

  func adjustUnreadCountersForReadState(
    viewerDid: String,
    subjectUri: String,
    delta: Int
  ) async throws

  func markAllReadCounters(
    viewerDid: String,
    publicationIds: [String],
    readAt: Date
  ) async throws -> [AppViewUnreadCounter]

  func deleteExpiredContent(before: Date, batchSize: Int) async throws -> Int
  func deleteExpiredReadMarks(before: Date, batchSize: Int) async throws -> Int
  func deleteExpiredTapEventReceipts(
    environment: String,
    before: Date,
    batchSize: Int
  ) async throws -> Int
  func deleteExpiredProjectionRepairs(
    environment: String,
    before: Date,
    batchSize: Int
  ) async throws -> Int

  func desiredTapRepositoryScope(limit: Int) async throws -> TapDesiredRepositoryScope
  func registeredTapRepositoryDids(environment: String) async throws -> [String]
  func markTapRepositoriesRegistered(
    environment: String,
    repoDids: [String],
    at: Date
  ) async throws
  func markTapRepositoriesRemoved(
    environment: String,
    repoDids: [String],
    at: Date
  ) async throws

  func recordIngestionCheckpoint(
    environment: String,
    source: String,
    repoDid: String,
    collection: String,
    cursor: String?,
    eventTime: Date?,
    observedAt: Date
  ) async throws

  func fetchTapRepositorySyncState(
    environment: String,
    repoDid: String
  ) async throws -> TapRepositorySyncState?

  func upsertTapRepositorySyncState(_ state: TapRepositorySyncState) async throws

  func hasProcessedTapEvent(environment: String, eventId: Int64) async throws -> Bool

  /// Persists the event receipt and repository evidence in one database transaction.
  func commitTapEvent(
    state: TapRepositorySyncState,
    eventId: Int64,
    eventType: String,
    parityEvidence: TapParityEventEvidence?,
    processedAt: Date
  ) async throws

  func listTapParityDiscrepancies(
    environment: String,
    repoDid: String
  ) async throws -> [TapParityDiscrepancy]

  /// Atomically applies authoritative Tap content, advances its checkpoint, and enqueues repair.
  func applyTapContentMutation(
    _ mutation: TapContentMutation,
    environment: String,
    eventId: Int64,
    repoRev: String,
    eventTime: Date,
    observedAt: Date
  ) async throws

  func projectionRepairBacklog(
    environment: String,
    at: Date
  ) async throws -> AppViewProjectionRepairBacklogSnapshot

  func claimProjectionRepair(
    environment: String,
    workerId: String,
    leaseUntil: Date,
    at: Date
  ) async throws -> AppViewProjectionRepair?

  func completeProjectionRepair(environment: String, id: String, workerId: String) async throws

  func failProjectionRepair(
    environment: String,
    id: String,
    workerId: String,
    errorCategory: String,
    retryAt: Date,
    at: Date
  ) async throws

  /// Authors with the stalest index; used by the worker proactive backfill loop.
  func listAuthorDidsForProactiveBackfill(limit: Int) async throws -> [String]

  /// Distinct RSS feed URLs (`publication_site`) for Skyreader poll refresh.
  func listRssPublicationSites(limit: Int) async throws -> [String]

  func fetchRssFeedMetadata(normalizedFeedUrl: String) async throws -> RssFeedFetchMetadata?
  func storeRssFeedMetadata(_ metadata: RssFeedFetchMetadata) async throws

  func fetchContentRender(uri: String) async throws -> ContentRenderFields?

  /// Lists indexed rows for one RSS feed URL (Skyreader duplicate cleanup).
  func listContentItemsForPublicationSite(
    authorDid: String,
    publicationSite: String,
    limit: Int
  ) async throws -> [(uri: String, renderJSON: String)]
}

public extension ThinAppViewStore {
  func listEntries(
    viewerDid: String,
    authorDid: String,
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String],
    filter: EntryListFilter,
    cursor: String?,
    limit: Int
  ) async throws -> AppViewEntryListResponse {
    try await listEntries(
      viewerDid: viewerDid,
      authorDid: authorDid,
      publicationAtUri: publicationAtUri,
      publicationScopeAtUris: publicationScopeAtUris,
      publicationSiteUrls: publicationSiteUrls,
      filter: filter,
      cursor: cursor,
      limit: limit,
      readFloorAt: nil
    )
  }
}
