import Foundation

public enum AppViewIngestionScopePolicy {
  /// Stable policy identifier persisted with every scope-filtered inbox row.
  public static let version = "publication-author-viewer-v1"

  public static let publicationAuthorCollections = [
    "site.standard.document",
    "site.standard.entry",
    "com.standard.document",
    "com.standard.entry",
  ]

  public static let viewerCollections = [
    "app.skyreader.feed.subscription",
    "site.standard.graph.subscription",
  ]
}

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
  /// Atomically leases at most one actionable item per repository, preserving FIFO per DID.
  func claimIngestionInbox(
    environment: String,
    sourceGeneration: String,
    workerId: String,
    limit: Int,
    leaseUntil: Date,
    at: Date
  ) async throws -> [AppViewIngestionInboxItem]

  /// Terminalizes a bounded batch of actionable commits that are outside the current, DB-backed
  /// projection scope. Publication content is scoped by author; viewer-owned subscription records
  /// are scoped by viewer; lifecycle events require either current role. Scope-filtered rows are
  /// neither applied nor reconciled.
  func filterIngestionInboxOutsideScope(
    environment: String,
    sourceGeneration: String,
    policy: String,
    limit: Int,
    expiresAt: Date,
    at: Date
  ) async throws -> Int

  /// Atomically marks a leased event applied. The worker coalesces applied-watermark advancement
  /// after a drain so concurrent completions do not contend on the generation checkpoint row.
  func markIngestionInboxApplied(
    environment: String,
    sourceGeneration: String,
    sequence: Int64,
    workerId: String,
    leaseToken: String,
    expiresAt: Date,
    at: Date
  ) async throws

  /// Advances across the staged terminal prefix, including intentionally discarded V2 events.
  func advanceIngestionInboxAppliedWatermark(
    environment: String,
    sourceGeneration: String,
    at: Date
  ) async throws

  func renewIngestionInboxLease(
    environment: String,
    sourceGeneration: String,
    sequence: Int64,
    workerId: String,
    leaseToken: String,
    leaseUntil: Date,
    at: Date
  ) async throws

  func retryIngestionInbox(
    environment: String,
    sourceGeneration: String,
    sequence: Int64,
    workerId: String,
    leaseToken: String,
    failureCategory: String,
    failureReason: String,
    nextAttemptAt: Date,
    at: Date
  ) async throws

  /// Dead-letters a fenced event and enqueues targeted repository reconciliation atomically.
  func deadLetterIngestionInbox(
    environment: String,
    sourceGeneration: String,
    sequence: Int64,
    repoDid: String,
    workerId: String,
    leaseToken: String,
    failureCategory: String,
    failureReason: String,
    expiresAt: Date,
    at: Date
  ) async throws

  func markIngestionInboxReconciled(
    environment: String,
    sourceGeneration: String,
    sequence: Int64,
    repoDid: String,
    repoRev: String,
    workerId: String,
    leaseToken: String,
    expiresAt: Date,
    at: Date
  ) async throws

  func deleteExpiredIngestionInbox(
    environment: String,
    before: Date,
    batchSize: Int
  ) async throws -> Int

  func resolveRecoveredIngestionIncidents(
    environment: String,
    sourceGeneration: String,
    at: Date
  ) async throws -> Int

  /// Resolves only fully-terminal fatal-stream incidents from generations superseded by the
  /// configured generation. The live successor must have an active fenced intake lease, match
  /// the retired transport identity, and prove inclusive cursor overlap. Current-generation,
  /// verification-required, and reconciliation-blocked incidents remain fail-closed.
  func resolveTerminalRetiredGenerationIncidents(
    environment: String,
    activeSourceGeneration: String,
    activeLeaseName: String,
    at: Date
  ) async throws -> Int

  func claimIngestionReconciliationRequests(
    environment: String,
    sourceGeneration: String,
    workerId: String,
    limit: Int,
    leaseUntil: Date,
    at: Date
  ) async throws -> [AppViewIngestionReconciliationRequest]

  func renewIngestionReconciliationLease(
    environment: String,
    requestId: String,
    workerId: String,
    leaseToken: String,
    leaseUntil: Date,
    at: Date
  ) async throws

  func retryIngestionReconciliation(
    environment: String,
    requestId: String,
    workerId: String,
    leaseToken: String,
    failureReason: String,
    nextAttemptAt: Date,
    at: Date
  ) async throws

  func completeIngestionReconciliation(
    environment: String,
    requestId: String,
    sourceGeneration: String,
    repoDid: String,
    triggerSequence: Int64,
    workerId: String,
    leaseToken: String,
    expiresAt: Date,
    at: Date
  ) async throws

  func upsertContentItem(_ item: IndexedContentItem) async throws
  func deleteContentItem(uri: String) async throws
  func deleteContentItems(authorDid: String) async throws -> Int
  func deleteContentItems(
    authorDid: String,
    excludingURIs: [String],
    indexedAtOrBefore: Date
  ) async throws -> Int
  func fetchContentIdentity(uri: String) async throws -> IndexedContentIdentity?

  func upsertReadMark(viewerDid: String, subjectUri: String, createdAt: Date) async throws
  func deleteReadMark(viewerDid: String, subjectUri: String) async throws
  func markEntryUnread(viewerDid: String, subjectUri: String, createdAt: Date) async throws
  func purgeReadMarks(viewerDid: String) async throws

  func fetchContentItem(uri: String) async throws -> AppViewEntryListItem?
  func hasReadMark(viewerDid: String, subjectUri: String) async throws -> Bool
  func readStates(
    viewerDid: String,
    entries: [AppViewEntryListItem]
  ) async throws -> [String: Bool]

  func listEntries(
    viewerDid: String,
    authorDid: String,
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String],
    filter: EntryListFilter,
    cursor: String?,
    limit: Int,
    readBoundary: ReadWatermarkBoundary?
  ) async throws -> AppViewEntryListResponse

  func listFeedEntries(
    viewerDid: String,
    scopes: [PublicationUnreadScope],
    filter: EntryListFilter,
    cursor: String?,
    limit: Int
  ) async throws -> AppViewEntryListResponse

  func listFeedEntries(
    viewerDid: String,
    selector: AppViewFeedSelector,
    filter: EntryListFilter,
    cursor: String?,
    limit: Int
  ) async throws -> AppViewFeedPage?

  func hasViewerFeedProjection(viewerDid: String) async throws -> Bool

  func publicationScopes(
    viewerDid: String,
    sectionKey: String
  ) async throws -> [AppViewPublicationScope]

  func listAggregateEntries(
    viewerDid: String,
    scopes: [AppViewPublicationScope],
    filter: EntryListFilter,
    cursor: String?,
    limit: Int
  ) async throws -> AppViewAggregatePageResult

  func readBoundary(viewerDid: String, publicationId: String) async throws -> ReadWatermarkBoundary?

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

  func upsertViewerFeedProjection(
    viewerDid: String,
    scopes: [AppViewPublicationScope],
    feeds: [AppViewViewerFeed],
    memberships: [AppViewFeedPublication]
  ) async throws

  func replaceViewerFeedProjection(
    viewerDid: String,
    scopes: [AppViewPublicationScope],
    feeds: [AppViewViewerFeed],
    memberships: [AppViewFeedPublication]
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
  func markUnreadCountersDirtyForAuthor(authorDid: String) async throws

  func adjustUnreadCountersForReadState(
    viewerDid: String,
    subjectUri: String,
    delta: Int
  ) async throws

  func markAllReadCounters(
    viewerDid: String,
    scopes: [PublicationUnreadScope],
    readAt: Date
  ) async throws -> (counters: [AppViewUnreadCounter], boundaries: [ReadWatermarkBoundary])

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
  /// Default for external store conformers that have not adopted retired-generation recovery.
  /// Remaining unresolved is the fail-closed, source-compatible behavior.
  func resolveTerminalRetiredGenerationIncidents(
    environment: String,
    activeSourceGeneration: String,
    activeLeaseName: String,
    at: Date
  ) async throws -> Int {
    0
  }

  /// Source-compatible convenience for callers using the canonical intake lease name.
  func resolveTerminalRetiredGenerationIncidents(
    environment: String,
    activeSourceGeneration: String,
    at: Date
  ) async throws -> Int {
    try await resolveTerminalRetiredGenerationIncidents(
      environment: environment,
      activeSourceGeneration: activeSourceGeneration,
      activeLeaseName: ThinAppViewConfig.defaultJetstreamLeaderLeaseName,
      at: at
    )
  }

  func listFeedEntries(
    viewerDid: String,
    scopes: [PublicationUnreadScope],
    filter: EntryListFilter,
    cursor: String?,
    limit: Int
  ) async throws -> AppViewEntryListResponse {
    let pageLimit = max(1, min(limit, 100))
    var candidates: [AppViewEntryListItem] = []
    var sourceHasMore = false
    for scope in scopes {
      let boundary = filter == .all
        ? nil
        : try await readBoundary(viewerDid: viewerDid, publicationId: scope.publicationId)
      let page = try await listEntries(
        viewerDid: viewerDid,
        authorDid: scope.authorDid,
        publicationAtUri: scope.publicationAtUri,
        publicationScopeAtUris: scope.publicationScopeAtUris,
        publicationSiteUrls: scope.publicationSiteUrls,
        filter: filter,
        cursor: cursor,
        limit: min(100, pageLimit + 1),
        readBoundary: boundary
      )
      candidates.append(contentsOf: page.entries.map { $0.withPublicationId(scope.publicationId) })
      sourceHasMore = sourceHasMore || page.cursor != nil
    }
    candidates.sort {
      $0.feedPositionAt == $1.feedPositionAt
        ? $0.entryId > $1.entryId
        : $0.feedPositionAt > $1.feedPositionAt
    }
    let entries = Array(candidates.prefix(pageLimit))
    let hasMore = sourceHasMore || candidates.count > pageLimit
    return AppViewEntryListResponse(
      entries: entries,
      cursor: hasMore ? entries.last.map {
        ThinAppViewCursor.encode(createdAt: $0.feedPositionAt, uri: $0.entryId)
      } : nil
    )
  }

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
      readBoundary: nil
    )
  }
}
