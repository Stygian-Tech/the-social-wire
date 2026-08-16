import AsyncHTTPClient
import Foundation
import GatewayCore
import Hummingbird
import Logging
import OperationsCore
import ThinAppViewCore

actor PublicationProjectionService {
  private let httpClient: HTTPClient
  private let plcURL: String
  private let logger: Logger
  private let repo: ATProtoAuthenticatedRepoClient
  private let thinStore: any ThinAppViewStore
  private let projectionCache: (any AppViewProjectionCacheStore)?
  private let telemetry: OperationsTelemetryBuffer?
  private var appViewScopeCache: [String: (scope: PublicationAppViewScope, expiresAt: Date)] = [:]
  private var discoveryCacheByViewer: [String: (context: SidebarDiscoveryContext, expiresAt: Date)] = [:]
  private var sidebarRowCacheByViewer: [String: [String: SidebarPublicationRow]] = [:]

  private static let appViewScopeCacheTTL: TimeInterval = 5 * 60
  private static let discoveryCacheTTL: TimeInterval = 10 * 60

  struct UnreadCounterSnapshot: Sendable {
    let counts: [String: Int]
    let generation: Int64
    let accuracy: AppViewUnreadCounterAccuracy
    let countedAt: Date
    let dirty: Bool
    let missingPublicationIds: [String]
  }

  init(
    httpClient: HTTPClient,
    plcURL: String,
    logger: Logger,
    thinStore: any ThinAppViewStore,
    projectionCache: (any AppViewProjectionCacheStore)? = nil,
    telemetry: OperationsTelemetryBuffer? = nil
  ) {
    self.httpClient = httpClient
    self.plcURL = plcURL
    self.logger = logger
    self.thinStore = thinStore
    self.projectionCache = projectionCache
    self.telemetry = telemetry
    self.repo = ATProtoAuthenticatedRepoClient(httpClient: httpClient, plcURL: plcURL, logger: logger)
  }

  /// Drops exactly the caches a viewer-initiated refresh needs rebuilt.
  ///
  /// Scoped deliberately. Unread counts and cached first pages are *not* cleared: the sidebar
  /// response carries neither, so dropping them did nothing for this request and cold-started the
  /// viewer's next feed load. `appViewScopeCache` is keyed by publication rather than by viewer,
  /// so only the entries this viewer is known to reference are evicted. `discoveryCacheByViewer`
  /// is left intact so the Following tab survives until the background full-discovery pass
  /// replaces it — see `refreshPrioritySidebar`.
  func invalidateViewerCaches(viewerDid: String) async {
    if let rows = sidebarRowCacheByViewer[viewerDid] {
      for key in rows.keys {
        appViewScopeCache.removeValue(
          forKey: PublicationProjectionLogic.normalizeAtRepoParam(key)
        )
      }
    }
    sidebarRowCacheByViewer.removeValue(forKey: viewerDid)
    guard let projectionCache else { return }
    try? await projectionCache.invalidateSidebarProjection(viewerDid: viewerDid)
  }

  func sidebar(
    auth: AuthContext,
    phase: SidebarBuildPhase = .full
  ) async throws -> PublicationSidebarResponse {
    switch phase {
    case .full:
      let context = try await discoverContext(auth: auth)
      cacheDiscovery(context, viewerDid: auth.did)
      return try await buildSidebarResponse(
        context: context,
        auth: auth,
        phase: .full,
        refreshedAt: Date()
      )
    case .priority:
      let context = try await discoverContext(auth: auth)
      cacheDiscovery(context, viewerDid: auth.did)
      return try await buildSidebarResponse(
        context: context,
        auth: auth,
        phase: .priority,
        refreshedAt: Date()
      )
    case .folderPublications:
      let context: SidebarDiscoveryContext
      if let cached = discoveryCacheByViewer[auth.did], cached.expiresAt > Date() {
        context = cached.context
      } else {
        context = try await discoverContext(auth: auth)
        cacheDiscovery(context, viewerDid: auth.did)
      }
      return try await buildSidebarResponse(
        context: context,
        auth: auth,
        phase: .folderPublications,
        refreshedAt: Date()
      )
    }
  }

  /// Reconstructs a sidebar response from the durable, cross-restart, cross-replica Postgres
  /// projection cache — no PDS/PLC calls. Used to serve hot paths (mark-all-read, unread-count
  /// lookups for publications not yet warm in this process's in-memory caches) without falling
  /// back to a live `discoverContext` pass, which fans out to every followed author's PDS and
  /// can take tens of seconds (or blow through the Gateway's proxy timeout) for viewers who
  /// follow many accounts.
  func cachedSidebarResponse(viewerDid: String) async -> PublicationSidebarResponse? {
    guard let projectionCache,
          let entry = try? await projectionCache.sidebarProjectionCacheEntryIncludingExpired(
            viewerDid: viewerDid
          ),
          let snapshot = try? JSONDecoder().decode(
            BootstrapSidebarCacheSnapshot.self,
            from: Data(entry.value.utf8)
          )
    else {
      return nil
    }
    let priority = snapshot.priority
    let folders = snapshot.folderPayload
    var allRowsById: [String: SidebarPublicationRow] = [:]
    for row in priority.allPublicationRows + (folders?.allPublicationRows ?? []) {
      allRowsById[row.publicationId] = row
    }
    return PublicationSidebarResponse(
      viewerDid: priority.viewerDid,
      folders: priority.folders,
      publicationPrefs: priority.publicationPrefs,
      folderSections: folders?.folderSections ?? priority.folderSections,
      allPublicationRows: Array(allRowsById.values),
      myPublications: priority.myPublications,
      subscribedUnfoldered: priority.subscribedUnfoldered,
      followingTabPublications: priority.followingTabPublications,
      enrollAuthorDids: priority.enrollAuthorDids,
      totalUnreadCount: priority.totalUnreadCount,
      refreshedAt: priority.refreshedAt
    )
  }

  /// Repairs feed membership from the stale sidebar projection without contacting a PDS.
  func rebuildFeedProjectionFromCachedSidebar(viewerDid: String) async -> Bool {
    guard let response = await cachedSidebarResponse(viewerDid: viewerDid) else { return false }
    do {
      try await storePublicationScopes(from: response, replaceAll: true)
      return true
    } catch {
      logger.warning("Failed to rebuild feed projection from sidebar cache")
      return false
    }
  }

  func sidebarRow(for viewerDid: String, publicationId: String) -> SidebarPublicationRow? {
    guard let cache = sidebarRowCacheByViewer[viewerDid] else { return nil }
    if let hit = cache[publicationId] { return hit }
    for key in PublicationProjectionLogic.publicationIdLookupKeys(for: publicationId) {
      if let hit = cache[key] { return hit }
    }
    return nil
  }

  func sidebarRows(for viewerDid: String, publicationIds: [String]) -> [SidebarPublicationRow] {
    publicationIds.compactMap { sidebarRow(for: viewerDid, publicationId: $0) }
  }

  // MARK: - Discovery

  private func discoverContext(
    auth: AuthContext,
    includeFollowDiscovery: Bool = true
  ) async throws -> SidebarDiscoveryContext {
    let viewerDid = auth.did

    async let foldersTask = loadFolders(auth: auth)
    async let prefsTask = loadPublicationPrefs(auth: auth)
    async let subscriptionValuesTask = loadGraphSubscriptions(auth: auth)
    async let skyreaderRecordsTask = loadSkyreaderSubscriptions(auth: auth)
    async let discoveredTask: [ProjectionDiscoveredRow] = {
      guard includeFollowDiscovery else { return [] }
      return await PublicationFollowDiscovery.discover(
        viewerDid: viewerDid,
        auth: auth,
        repo: repo,
        httpClient: httpClient,
        plcURL: plcURL,
        logger: logger
      )
    }()

    let folders = try await foldersTask
    let prefs = try await prefsTask
    let subscriptionValues = try await subscriptionValuesTask
    let skyreaderRecords = try await skyreaderRecordsTask
    let discovered = await discoveredTask

    let rssRows = PublicationProjectionLogic.skyreaderRows(from: skyreaderRecords)
    let subscriptionKeys = PublicationProjectionLogic.subscriptionPublicationKeys(from: subscriptionValues)

    let existingForOrphans = discovered + rssRows
    let orphanUris = PublicationProjectionLogic.orphanGraphSubscriptionUris(
      subscriptions: subscriptionValues,
      existingRows: existingForOrphans
    )

    var graphOrphanRows: [ProjectionDiscoveredRow] = []
    await withTaskGroup(of: ProjectionDiscoveredRow?.self) { group in
      for uri in orphanUris {
        group.addTask {
          await PublicationFollowDiscovery.rowFromPublicationAtUri(
            atUri: uri,
            repo: self.repo,
            auth: auth,
            httpClient: self.httpClient,
            plcURL: self.plcURL
          )
        }
      }
      for await row in group {
        if let row { graphOrphanRows.append(row) }
      }
    }

    let visibleDiscovery = PublicationProjectionLogic.filterHiddenPublications(
      discovered + graphOrphanRows,
      prefs: prefs
    )
    let visibleRssRows = PublicationProjectionLogic.filterHiddenPublications(
      rssRows,
      prefs: prefs
    )
    let segmented = PublicationProjectionLogic.segmentDiscovery(
      visibleDiscovery,
      viewerDid: viewerDid,
      subscriptionKeys: subscriptionKeys
    )

    let subscribed = PublicationProjectionLogic.mergeSubscribed(
      graphSubscribed: segmented.graphSubscribed,
      rssRows: visibleRssRows,
      graphOrphanRows: PublicationProjectionLogic.filterHiddenPublications(
        graphOrphanRows,
        prefs: prefs
      )
    )

    let myPublications = subscribed.filter {
      PublicationProjectionLogic.viewerOwnsPublication($0, viewerDid: viewerDid)
    }

    let prefsByPublicationId = PublicationProjectionLogic.prefsByPublicationId(prefs)

    let unfoldered = subscribed.filter { row in
      guard !PublicationProjectionLogic.viewerOwnsPublication(row, viewerDid: viewerDid) else {
        return false
      }
      let folderId = prefsByPublicationId[row.publicationId]?.value["folderId"]?.value as? String
      return folderId == nil || folderId?.isEmpty == true
    }

    let following: [ProjectionDiscoveredRow]
    if includeFollowDiscovery {
      following = PublicationProjectionLogic.filterFollowingTab(
        followOwnedUnsubscribed: segmented.followOwnedUnsubscribed,
        myPublications: myPublications
      )
    } else if let cached = discoveryCacheByViewer[viewerDid], cached.expiresAt > Date() {
      following = cached.context.following
    } else {
      following = []
    }

    let allRows = visibleDiscovery + visibleRssRows
    let enrollAuthorDids = Array(
      Set(
        allRows
          .map(\.authorDid)
          .filter { ThinAppViewEnrollBackfill.isBackfillEligibleAuthorDid($0) }
      )
    ).sorted()
    let uniqueRows = Self.uniqueRows(allRows)

    return SidebarDiscoveryContext(
      viewerDid: viewerDid,
      folders: folders,
      prefs: prefs,
      subscribed: subscribed,
      myPublications: myPublications,
      unfoldered: unfoldered,
      following: following,
      uniqueRows: uniqueRows,
      enrollAuthorDids: enrollAuthorDids,
      prefsByPublicationId: prefsByPublicationId
    )
  }

  private func cacheDiscovery(_ context: SidebarDiscoveryContext, viewerDid: String) {
    discoveryCacheByViewer[viewerDid] = (
      context,
      Date().addingTimeInterval(Self.discoveryCacheTTL)
    )
  }

  private func mergeSidebarRows(
    viewerDid: String,
    rows: [String: SidebarPublicationRow]
  ) {
    var merged = sidebarRowCacheByViewer[viewerDid] ?? [:]
    for row in rows.values {
      for key in PublicationProjectionLogic.publicationIdLookupKeys(for: row.publicationId) {
        merged[key] = row
      }
    }
    sidebarRowCacheByViewer[viewerDid] = merged
  }

  struct BootstrapPrioritySidebarResult: Sendable {
    let response: PublicationSidebarResponse
    let context: SidebarDiscoveryContext
  }

  func bootstrapPrioritySidebar(auth: AuthContext) async throws -> BootstrapPrioritySidebarResult {
    let context: SidebarDiscoveryContext
    if let cached = discoveryCacheByViewer[auth.did], cached.expiresAt > Date() {
      context = cached.context
    } else {
      context = try await discoverContext(auth: auth, includeFollowDiscovery: false)
    }
    let response = try await buildSidebarResponse(
      context: context,
      auth: auth,
      phase: .priority,
      refreshedAt: Date(),
      includeUnreadCounts: false
    )
    return BootstrapPrioritySidebarResult(response: response, context: context)
  }

  /// Full follow discovery + sidebar rebuild for background cache refresh after bootstrap.
  func refreshFullDiscoverySidebar(auth: AuthContext) async throws -> PublicationSidebarResponse {
    let context = try await discoverContext(auth: auth, includeFollowDiscovery: true)
    cacheDiscovery(context, viewerDid: auth.did)
    return try await buildSidebarResponse(
      context: context,
      auth: auth,
      phase: .full,
      refreshedAt: Date(),
      includeUnreadCounts: false
    )
  }

  /// Viewer-initiated refresh, sized for a request path.
  ///
  /// Rebuilds folders, prefs, subscriptions and RSS rows live while skipping the follow-graph
  /// discovery fan-out, which walks up to 500 authors' PDSes and is what pushed this endpoint past
  /// the Gateway's 60s proxy timeout. The Following tab is carried over from the discovery cache
  /// (see the `includeFollowDiscovery == false` fallback in `discoverContext`) and is refreshed out
  /// of band by `refreshFullDiscoveryAndPersist`.
  ///
  /// Returns the priority tier, so folder sections come back without their publications. Callers
  /// must merge this into an existing projection rather than replacing one.
  func refreshPrioritySidebar(auth: AuthContext) async throws -> PublicationSidebarResponse {
    let context = try await discoverContext(auth: auth, includeFollowDiscovery: false)
    cacheDiscovery(context, viewerDid: auth.did)
    return try await buildSidebarResponse(
      context: context,
      auth: auth,
      phase: .priority,
      refreshedAt: Date(),
      includeUnreadCounts: false
    )
  }

  /// Full follow-graph discovery plus a durable projection-cache write, for running off the
  /// request path. Shared by bootstrap and by `app.thesocialwire.publication.refreshSidebar` so that a refresh
  /// leaves the cross-replica cache warm instead of deleting it and never writing it back.
  func refreshFullDiscoveryAndPersist(auth: AuthContext) async {
    do {
      _ = try await refreshFullDiscoverySidebar(auth: auth)
      let refreshed = try await bootstrapPrioritySidebar(auth: auth)
      let folders = try await bootstrapFolderSidebar(auth: auth, context: refreshed.context)
      guard let projectionCache else { return }
      let snapshot = BootstrapSidebarCacheSnapshot(
        priority: refreshed.response,
        folderPayload: folders
      )
      guard let data = try? JSONEncoder().encode(snapshot),
            let json = String(data: data, encoding: .utf8)
      else { return }
      try? await projectionCache.storeSidebarProjectionJSON(
        viewerDid: auth.did,
        jsonBody: json,
        expiresAt: Date().addingTimeInterval(AppViewProjectionCacheTTL.sidebarSeconds)
      )
    } catch {
      logger.warning(
        "Background sidebar refresh failed",
        metadata: ["error": .string(String(describing: error))]
      )
    }
  }

  func bootstrapFolderSidebar(
    auth: AuthContext,
    context: SidebarDiscoveryContext
  ) async throws -> AppViewBootstrapSidebarFoldersPayload {
    let response = try await buildSidebarResponse(
      context: context,
      auth: auth,
      phase: .folderPublications,
      refreshedAt: Date(),
      includeUnreadCounts: false
    )
    return AppViewBootstrapSidebarFoldersPayload(
      folderSections: response.folderSections,
      allPublicationRows: response.allPublicationRows
    )
  }

  func unreadCountsMap(for rows: [SidebarPublicationRow]) -> [String: Int] {
    var counts: [String: Int] = [:]
    for row in rows {
      guard let unreadCount = row.unreadCount, unreadCount > 0 else { continue }
      counts[row.publicationId] = unreadCount
    }
    return counts
  }

  /// Live unread totals from the AppView index (ignores embedded sidebar row counts).
  func freshUnreadCountsMap(for rows: [SidebarPublicationRow], viewerDid: String) async -> [String: Int] {
    guard !rows.isEmpty else { return [:] }
    let scopes = rows.map {
      PublicationUnreadScope(
        publicationId: $0.publicationId,
        authorDid: $0.appViewScope.authorDid,
        publicationAtUri: $0.appViewScope.publicationAtUri,
        publicationScopeAtUris: $0.appViewScope.publicationScopeAtUris,
        publicationSiteUrls: $0.appViewScope.publicationSiteUrls
      )
    }
    return (try? await thinStore.countUnreadEntriesBatch(viewerDid: viewerDid, scopes: scopes)) ?? [:]
  }

  func unreadCounterSnapshot(
    for rows: [SidebarPublicationRow],
    viewerDid: String
  ) async -> UnreadCounterSnapshot {
    let publicationIds = rows.map(\.publicationId)
    guard !publicationIds.isEmpty else {
      let now = Date()
      return UnreadCounterSnapshot(
        counts: [:],
        generation: AppViewUnreadCounterSupport.generation(for: now),
        accuracy: .exact,
        countedAt: now,
        dirty: false,
        missingPublicationIds: []
      )
    }
    let counters = (try? await thinStore.fetchUnreadCounters(
      viewerDid: viewerDid,
      publicationIds: publicationIds
    )) ?? []
    let byId = Dictionary(uniqueKeysWithValues: counters.map { ($0.publicationId, $0) })
    var counts: [String: Int] = [:]
    var missing: [String] = []
    var generation: Int64 = 0
    var countedAt = Date.distantPast
    var dirty = false
    var allExact = true
    for publicationId in publicationIds {
      guard let counter = byId[publicationId] else {
        counts[publicationId] = 0
        missing.append(publicationId)
        dirty = true
        allExact = false
        continue
      }
      counts[publicationId] = counter.unreadCount
      generation = max(generation, counter.generation)
      countedAt = max(countedAt, counter.countedAt)
      dirty = dirty || counter.dirty
      allExact = allExact && counter.accuracy == .exact && !counter.dirty
    }
    let now = Date()
    if generation == 0 { generation = AppViewUnreadCounterSupport.generation(for: now) }
    if countedAt == Date.distantPast { countedAt = now }
    return UnreadCounterSnapshot(
      counts: counts,
      generation: generation,
      accuracy: allExact ? .exact : .estimated,
      countedAt: countedAt,
      dirty: dirty,
      missingPublicationIds: missing
    )
  }

  /// Reads known per-publication Redis values first and reconstructs only missing keys from the
  /// durable materialized counters. A cold contender waits briefly for the lease holder, then
  /// falls back to Postgres so Redis coordination can never become a response dependency.
  func cachedUnreadCounterSnapshot(
    for rows: [SidebarPublicationRow],
    viewerDid: String
  ) async -> UnreadCounterSnapshot {
    guard let projectionCache, !rows.isEmpty else {
      return await unreadCounterSnapshot(for: rows, viewerDid: viewerDid)
    }

    var rowsById: [String: SidebarPublicationRow] = [:]
    for row in rows where rowsById[row.publicationId] == nil {
      rowsById[row.publicationId] = row
    }
    let publicationIds = Array(rowsById.keys).sorted()
    var cachedCounts: [String: Int] = [:]
    var cachedAt: Date?
    var stale = false

    let applyLookup = { (lookup: AppViewProjectionCacheLookup<[String: Int]>) in
      switch lookup {
      case .fresh(let entry):
        cachedCounts.merge(entry.value) { _, latest in latest }
        cachedAt = entry.cachedAt
      case .stale(let entry):
        cachedCounts.merge(entry.value) { _, latest in latest }
        cachedAt = entry.cachedAt
        stale = true
      case .miss:
        break
      }
    }

    if let lookup = try? await projectionCache.unreadCountsCacheLookup(
      viewerDid: viewerDid,
      publicationIds: publicationIds,
      now: Date()
    ) {
      applyLookup(lookup)
    }

    var missingIds = publicationIds.filter { cachedCounts[$0] == nil }
    var lease: AppViewProjectionRefreshLease?
    if !missingIds.isEmpty {
      lease = await projectionCache.acquireRefreshLease(
        domain: "unread",
        resource: viewerDid,
        ttl: 10
      )
      if lease == nil {
        try? await Task.sleep(for: .milliseconds(250))
        if let lookup = try? await projectionCache.unreadCountsCacheLookup(
          viewerDid: viewerDid,
          publicationIds: missingIds,
          now: Date()
        ) {
          applyLookup(lookup)
        }
        missingIds = publicationIds.filter { cachedCounts[$0] == nil }
      }
    }

    let missingRows = missingIds.compactMap { rowsById[$0] }
    let reconstructed = missingRows.isEmpty
      ? nil
      : await unreadCounterSnapshot(for: missingRows, viewerDid: viewerDid)
    if let reconstructed {
      cachedCounts.merge(reconstructed.counts) { known, _ in known }
      if !reconstructed.counts.isEmpty {
        try? await projectionCache.storeUnreadCounts(
          viewerDid: viewerDid,
          counts: reconstructed.counts,
          expiresAt: Date().addingTimeInterval(AppViewProjectionCacheTTL.unreadCountsSeconds)
        )
      }
    }
    if let lease {
      await projectionCache.releaseRefreshLease(lease)
    }

    let needsRefresh = stale
      || reconstructed?.dirty == true
      || !(reconstructed?.missingPublicationIds.isEmpty ?? true)
    if needsRefresh {
      Task {
        _ = await self.refreshUnreadCounterSnapshot(for: rows, viewerDid: viewerDid)
      }
    }

    let now = Date()
    let cachedGeneration = cachedAt.map(AppViewUnreadCounterSupport.generation(for:)) ?? 0
    let countedAt = max(cachedAt ?? .distantPast, reconstructed?.countedAt ?? .distantPast)
    return UnreadCounterSnapshot(
      counts: cachedCounts,
      generation: max(cachedGeneration, reconstructed?.generation ?? 0),
      accuracy: cachedAt == nil && reconstructed?.accuracy == .exact ? .exact : .estimated,
      countedAt: countedAt == .distantPast ? now : countedAt,
      dirty: reconstructed?.dirty ?? false,
      missingPublicationIds: reconstructed?.missingPublicationIds ?? []
    )
  }

  func refreshUnreadCounterSnapshot(
    for rows: [SidebarPublicationRow],
    viewerDid: String
  ) async -> UnreadCounterSnapshot {
    guard !rows.isEmpty else {
      return await unreadCounterSnapshot(for: rows, viewerDid: viewerDid)
    }
    let rebuildStarted = Date()
    let prior = await unreadCounterSnapshot(for: rows, viewerDid: viewerDid)
    let reason = !prior.missingPublicationIds.isEmpty ? "missing" : prior.dirty ? "dirty" : "refresh"
    let scopes = unreadScopes(from: rows)
    let lease = await projectionCache?.acquireRefreshLease(
      domain: "unread",
      resource: viewerDid,
      ttl: 10
    )
    guard projectionCache == nil || lease != nil else {
      return await unreadCounterSnapshot(for: rows, viewerDid: viewerDid)
    }
    let renewal = lease.flatMap { lease in
      projectionCache.map { refreshLeaseRenewal(lease, projectionCache: $0) }
    }
    defer {
      renewal?.cancel()
      if let lease, let projectionCache {
        Task { await projectionCache.releaseRefreshLease(lease) }
      }
    }
    _ = try? await thinStore.refreshUnreadCounters(viewerDid: viewerDid, scopes: scopes)
    recordMetric(
      name: "socialwire.appview.unread.recomputes_total",
      value: 1,
      dimensions: ["reason": reason]
    )
    recordMetric(
      name: "socialwire.appview.cache.rebuild.duration_seconds",
      value: Date().timeIntervalSince(rebuildStarted),
      dimensions: ["cache_type": "unread"]
    )
    let snapshot = await unreadCounterSnapshot(for: rows, viewerDid: viewerDid)
    if let projectionCache, !snapshot.counts.isEmpty {
      try? await projectionCache.storeUnreadCounts(
        viewerDid: viewerDid,
        counts: snapshot.counts,
        expiresAt: Date().addingTimeInterval(AppViewProjectionCacheTTL.unreadCountsSeconds)
      )
    }
    return snapshot
  }

  private func unreadScopes(from rows: [SidebarPublicationRow]) -> [PublicationUnreadScope] {
    rows.map {
      PublicationUnreadScope(
        publicationId: $0.publicationId,
        authorDid: $0.appViewScope.authorDid,
        publicationAtUri: $0.appViewScope.publicationAtUri,
        publicationScopeAtUris: $0.appViewScope.publicationScopeAtUris,
        publicationSiteUrls: $0.appViewScope.publicationSiteUrls
      )
    }
  }

  private func recordMetric(name: String, value: Double, dimensions: [String: String]) {
    guard let telemetry else { return }
    Task {
      _ = await telemetry.enqueue(.metric(
        OperationsMetricSample(name: name, value: value, dimensions: dimensions)
      ))
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

  private func buildSidebarResponse(
    context: SidebarDiscoveryContext,
    auth: AuthContext,
    phase: SidebarBuildPhase,
    refreshedAt: Date,
    includeUnreadCounts: Bool = false
  ) async throws -> PublicationSidebarResponse {
    let priorityRows = priorityDiscoveredRows(from: context)
    let folderRows = folderDiscoveredRows(from: context)

    let rowsToBuild: [ProjectionDiscoveredRow]
    switch phase {
    case .full:
      rowsToBuild = context.uniqueRows
    case .priority:
      rowsToBuild = priorityRows
    case .folderPublications:
      rowsToBuild = folderRows
    }

    let sidebarRowById = try await buildSidebarRowMap(
      rows: rowsToBuild,
      auth: auth,
      viewerDid: context.viewerDid,
      includeUnreadCounts: includeUnreadCounts
    )
    mergeSidebarRows(viewerDid: context.viewerDid, rows: sidebarRowById)

    let rowCache = sidebarRowCacheByViewer[context.viewerDid] ?? sidebarRowById

    let response: PublicationSidebarResponse
    switch phase {
    case .folderPublications:
      let folderSections = buildFolderSections(
        context: context,
        sidebarRowById: rowCache,
        includePublications: true
      )
      let folderPublicationRows = folderSections.flatMap(\.publications)
      response = PublicationSidebarResponse(
        viewerDid: context.viewerDid,
        folders: [],
        publicationPrefs: [],
        folderSections: folderSections,
        allPublicationRows: folderPublicationRows,
        myPublications: [],
        subscribedUnfoldered: [],
        followingTabPublications: [],
        enrollAuthorDids: [],
        totalUnreadCount: 0,
        refreshedAt: refreshedAt
      )
    case .priority:
      let myRows = context.myPublications.compactMap { rowCache[$0.publicationId] }
      let unfolderedRows = context.unfoldered.compactMap { rowCache[$0.publicationId] }
      let followingRows = context.following.compactMap { rowCache[$0.publicationId] }
      let prioritySidebarRows = priorityRows.compactMap { rowCache[$0.publicationId] }
      let folderSections = buildFolderSections(
        context: context,
        sidebarRowById: rowCache,
        includePublications: false
      )
      let totalUnread = (myRows + unfolderedRows + followingRows + folderSections.flatMap(\.publications))
        .compactMap(\.unreadCount)
        .reduce(0, +)
      response = PublicationSidebarResponse(
        viewerDid: context.viewerDid,
        folders: context.folders,
        publicationPrefs: context.prefs,
        folderSections: folderSections,
        allPublicationRows: prioritySidebarRows,
        myPublications: myRows,
        subscribedUnfoldered: unfolderedRows,
        followingTabPublications: followingRows,
        enrollAuthorDids: context.enrollAuthorDids,
        totalUnreadCount: totalUnread,
        refreshedAt: refreshedAt
      )
    case .full:
      let sidebarRows = context.uniqueRows.compactMap { rowCache[$0.publicationId] }
      let myRows = context.myPublications.compactMap { rowCache[$0.publicationId] }
      let unfolderedRows = context.unfoldered.compactMap { rowCache[$0.publicationId] }
      let followingRows = context.following.compactMap { rowCache[$0.publicationId] }
      let folderSections = buildFolderSections(
        context: context,
        sidebarRowById: rowCache,
        includePublications: true
      )
      response = PublicationSidebarResponse(
        viewerDid: context.viewerDid,
        folders: context.folders,
        publicationPrefs: context.prefs,
        folderSections: folderSections,
        allPublicationRows: sidebarRows,
        myPublications: myRows,
        subscribedUnfoldered: unfolderedRows,
        followingTabPublications: followingRows,
        enrollAuthorDids: context.enrollAuthorDids,
        totalUnreadCount: 0,
        refreshedAt: refreshedAt
      )
    }
    try? await storePublicationScopes(from: response, replaceAll: phase == .full)
    return response
  }

  private func priorityDiscoveredRows(from context: SidebarDiscoveryContext) -> [ProjectionDiscoveredRow] {
    var byId: [String: ProjectionDiscoveredRow] = [:]
    for row in context.myPublications + context.unfoldered + context.following {
      byId[row.publicationId] = row
    }
    return Array(byId.values)
  }

  private func folderDiscoveredRows(from context: SidebarDiscoveryContext) -> [ProjectionDiscoveredRow] {
    var byId: [String: ProjectionDiscoveredRow] = [:]
    for folder in context.folders {
      let folderId = folder.uri
      for row in context.subscribed {
        let prefFolder = context.prefsByPublicationId[row.publicationId]?.value["folderId"]?.value as? String
        guard prefFolder == folderId || prefFolder == folder.rkey else { continue }
        byId[row.publicationId] = row
      }
    }
    return Array(byId.values)
  }

  private func buildFolderSections(
    context: SidebarDiscoveryContext,
    sidebarRowById: [String: SidebarPublicationRow],
    includePublications: Bool
  ) -> [PublicationFolderSection] {
    context.folders.map { folder in
      let folderId = folder.uri
      let pubs = context.subscribed.filter { row in
        let prefFolder = context.prefsByPublicationId[row.publicationId]?.value["folderId"]?.value as? String
        return prefFolder == folderId || prefFolder == folder.rkey
      }
      let sectionRows = includePublications
        ? pubs.compactMap { sidebarRowById[$0.publicationId] }
        : []
      let name = folder.value["name"]?.value as? String ?? folder.rkey
      return PublicationFolderSection(
        folderUri: folder.uri,
        folderRkey: folder.rkey,
        name: name,
        publications: sectionRows,
        unreadCount: sectionRows.compactMap(\.unreadCount).reduce(0, +)
      )
    }
  }

  private func storePublicationScopes(
    from response: PublicationSidebarResponse,
    replaceAll: Bool
  ) async throws {
    var sectionKeysByPublicationId: [String: Set<String>] = [:]
    let addSectionKey = { (publicationId: String, sectionKey: String, map: inout [String: Set<String>]) in
      _ = map[publicationId, default: []].insert(sectionKey)
    }

    for row in response.myPublications {
      addSectionKey(row.publicationId, "my", &sectionKeysByPublicationId)
      addSectionKey(row.publicationId, "subscribed", &sectionKeysByPublicationId)
    }
    for row in response.subscribedUnfoldered {
      addSectionKey(row.publicationId, "subscribed:unfoldered", &sectionKeysByPublicationId)
      addSectionKey(row.publicationId, "subscribed", &sectionKeysByPublicationId)
    }
    for row in response.followingTabPublications {
      addSectionKey(row.publicationId, "following", &sectionKeysByPublicationId)
    }
    for section in response.folderSections {
      for row in section.publications {
        addSectionKey(row.publicationId, "folder:\(section.folderRkey)", &sectionKeysByPublicationId)
        addSectionKey(row.publicationId, "subscribed", &sectionKeysByPublicationId)
      }
    }
    for row in response.allPublicationRows where sectionKeysByPublicationId[row.publicationId] == nil {
      addSectionKey(row.publicationId, "all", &sectionKeysByPublicationId)
    }

    var rowsById: [String: SidebarPublicationRow] = [:]
    for row in response.allPublicationRows
      + response.myPublications
      + response.subscribedUnfoldered
      + response.followingTabPublications
      + response.folderSections.flatMap(\.publications)
    {
      rowsById[row.publicationId] = row
    }

    let now = Date()
    let scopes = rowsById.values.map { row in
      AppViewUnreadCounterSupport.publicationScope(
        viewerDid: response.viewerDid,
        publicationId: row.publicationId,
        authorDid: row.appViewScope.authorDid,
        publicationAtUri: row.appViewScope.publicationAtUri,
        publicationScopeAtUris: row.appViewScope.publicationScopeAtUris,
        publicationSiteUrls: row.appViewScope.publicationSiteUrls,
        sectionKeys: Array(sectionKeysByPublicationId[row.publicationId] ?? []),
        updatedAt: now
      )
    }
    let topLevelSubscribed = AppViewViewerFeed(
      viewerDid: response.viewerDid,
      kind: .subscribed,
      feedId: "",
      updatedAt: now
    )
    let topLevelFollowing = AppViewViewerFeed(
      viewerDid: response.viewerDid,
      kind: .following,
      feedId: "",
      updatedAt: now
    )
    let folderFeeds = response.folderSections.map {
      AppViewViewerFeed(
        viewerDid: response.viewerDid,
        kind: .folder,
        feedId: $0.folderRkey,
        updatedAt: now
      )
    }
    let subscribedRows = PublicationProjectionLogic.subscribedFeedMembershipRows(
      subscribedUnfoldered: response.subscribedUnfoldered,
      folderSections: response.folderSections
    )
    let subscribedMemberships = subscribedRows.map {
      AppViewFeedPublication(
        viewerDid: response.viewerDid,
        kind: .subscribed,
        feedId: "",
        publicationId: $0.publicationId
      )
    }
    let followingMemberships = response.followingTabPublications.map {
      AppViewFeedPublication(
        viewerDid: response.viewerDid,
        kind: .following,
        feedId: "",
        publicationId: $0.publicationId
      )
    }
    let folderMemberships = response.folderSections.flatMap { section in
      section.publications.map {
        AppViewFeedPublication(
          viewerDid: response.viewerDid,
          kind: .folder,
          feedId: section.folderRkey,
          publicationId: $0.publicationId
        )
      }
    }
    let feeds = [topLevelSubscribed, topLevelFollowing] + folderFeeds
    var membershipsByKey: [String: AppViewFeedPublication] = [:]
    for membership in subscribedMemberships + followingMemberships + folderMemberships {
      let key = "\(membership.kind.rawValue):\(membership.feedId):\(membership.publicationId)"
      membershipsByKey[key] = membership
    }
    let memberships = Array(membershipsByKey.values)
    if replaceAll {
      try await thinStore.replaceViewerFeedProjection(
        viewerDid: response.viewerDid,
        scopes: scopes,
        feeds: feeds,
        memberships: memberships
      )
    } else {
      try await thinStore.upsertViewerFeedProjection(
        viewerDid: response.viewerDid,
        scopes: scopes,
        feeds: feeds,
        memberships: memberships
      )
    }
  }

  // MARK: - PDS loaders

  private func loadFolders(auth: AuthContext) async throws -> [PublicationFolderRecord] {
    let records = try await repo.listAllRecords(
      auth: auth,
      repo: auth.did,
      collection: PublicationLexicons.folder,
      maxPages: 10
    )
    return records.map { record in
      let rkey = rkeyFromUri(record.uri) ?? record.uri
      return PublicationFolderRecord(
        uri: record.uri,
        rkey: rkey,
        value: record.value.values.mapValues { AnyCodable($0) }
      )
    }
  }

  private func loadPublicationPrefs(auth: AuthContext) async throws -> [PublicationPrefsRecordDTO] {
    let records = try await repo.listAllRecords(
      auth: auth,
      repo: auth.did,
      collection: PublicationLexicons.publicationPrefs,
      maxPages: 20
    )
    return records.compactMap { record in
      guard let publicationId = record.value.values["publicationId"] as? String else { return nil }
      return PublicationPrefsRecordDTO(
        uri: record.uri,
        publicationId: publicationId,
        value: record.value.values.mapValues { AnyCodable($0) }
      )
    }
  }

  private func loadGraphSubscriptions(auth: AuthContext) async throws -> [GraphSubscriptionProjection] {
    let records = try await repo.listAllRecords(
      auth: auth,
      repo: auth.did,
      collection: PublicationLexicons.graphSubscription,
      maxPages: 20
    )
    return records.map { record in
      GraphSubscriptionProjection(
        publication: record.value.values["publication"] as? String
      )
    }
  }

  private func loadSkyreaderSubscriptions(auth: AuthContext) async throws -> [(uri: String, value: PdsRecordJSON)] {
    let records = try await repo.listAllRecords(
      auth: auth,
      repo: auth.did,
      collection: PublicationLexicons.skyreaderFeedSubscription,
      maxPages: 20
    )
    return records.map { ($0.uri, $0.value) }
  }

  private static func uniqueRows(_ rows: [ProjectionDiscoveredRow]) -> [ProjectionDiscoveredRow] {
    var byId: [String: ProjectionDiscoveredRow] = [:]
    for row in rows {
      byId[row.publicationId] = row
    }
    return Array(byId.values)
  }

  private func buildSidebarRowMap(
    rows: [ProjectionDiscoveredRow],
    auth: AuthContext,
    viewerDid: String,
    includeUnreadCounts: Bool
  ) async throws -> [String: SidebarPublicationRow] {
    var scopeCache: [String: PublicationAppViewScope] = [:]
    await withTaskGroup(of: (String, PublicationAppViewScope).self) { group in
      for row in rows {
        group.addTask {
          let scope = await self.cachedBuildAppViewScope(
            publicationId: row.publicationId,
            authorDid: row.authorDid,
            auth: auth
          )
          return (row.publicationId, scope)
        }
      }
      for await (publicationId, scope) in group {
        scopeCache[publicationId] = scope
      }
    }

    var unreadByPublicationId: [String: Int] = [:]
    if includeUnreadCounts {
      await withTaskGroup(of: (String, Int?).self) { group in
        for row in rows {
          guard let scope = scopeCache[row.publicationId] else { continue }
          group.addTask {
            let count = try? await self.thinStore.countUnreadEntries(
              viewerDid: viewerDid,
              authorDid: scope.authorDid,
              publicationAtUri: scope.publicationAtUri,
              publicationScopeAtUris: scope.publicationScopeAtUris,
              publicationSiteUrls: scope.publicationSiteUrls
            )
            return (row.publicationId, count)
          }
        }
        for await (publicationId, count) in group {
          if let count, count > 0 {
            unreadByPublicationId[publicationId] = count
          }
        }
      }
    }

    var out: [String: SidebarPublicationRow] = [:]
    for row in rows {
      guard let scope = scopeCache[row.publicationId] else {
        throw HTTPError(.internalServerError)
      }
      let unreadCount: Int? = includeUnreadCounts
        ? (unreadByPublicationId[row.publicationId] ?? 0)
        : nil
      out[row.publicationId] = SidebarPublicationRow(
        publicationId: row.publicationId,
        subscriptionPublicationId: row.subscriptionPublicationId,
        authorDid: row.authorDid,
        authorHandle: row.authorHandle,
        title: row.title,
        iconUrl: row.iconUrl,
        avatarUrl: row.avatarUrl,
        discoveredAt: row.discoveredAt,
        appViewScope: scope,
        unreadCount: unreadCount
      )
    }
    return out
  }

  private func rkeyFromUri(_ uri: String) -> String? {
    guard let parsed = RenderFieldExtractor.parseAtUri(uri) else { return nil }
    return parsed.rkey
  }

  private func cachedBuildAppViewScope(
    publicationId: String,
    authorDid: String,
    auth: AuthContext
  ) async -> PublicationAppViewScope {
    let key = PublicationProjectionLogic.normalizeAtRepoParam(publicationId)
    if let hit = appViewScopeCache[key], hit.expiresAt > Date() {
      return hit.scope
    }
    let scope = await buildAppViewScope(
      publicationId: publicationId,
      authorDid: authorDid,
      auth: auth
    )
    appViewScopeCache[key] = (
      scope,
      Date().addingTimeInterval(Self.appViewScopeCacheTTL)
    )
    return scope
  }

  private func buildAppViewScope(
    publicationId: String,
    authorDid: String,
    auth: AuthContext
  ) async -> PublicationAppViewScope {
    let normalized = PublicationProjectionLogic.normalizeAtRepoParam(publicationId)

    if normalized.hasPrefix(PublicationLexicons.rssPublicationPrefix) {
      let feedUrl = RssFeedIdentity.normalizedFeedUrl(fromRssPublicationId: normalized)
      return PublicationAppViewScope(
        authorDid: PublicationLexicons.rssAuthorDid,
        publicationAtUri: nil,
        publicationScopeAtUris: [],
        publicationSiteUrls: feedUrl.map { [$0] } ?? []
      )
    }

    if normalized.hasPrefix("did:") {
      return PublicationAppViewScope(
        authorDid: normalized,
        publicationAtUri: nil,
        publicationScopeAtUris: [],
        publicationSiteUrls: []
      )
    }

    guard let parsed = RenderFieldExtractor.parseAtUri(normalized) else {
      return PublicationAppViewScope(
        authorDid: authorDid,
        publicationAtUri: nil,
        publicationScopeAtUris: [],
        publicationSiteUrls: []
      )
    }

    var atUriKeys = RenderFieldExtractor.publicationFilterEquivalenceKeys(publicationAtUri: normalized)
    var siteUrlKeys = Set<String>()

    if let value = try? await repo.getRecordByAtUri(auth: auth, atUri: normalized) {
      for url in publicationSiteUrlsFromRecord(value.values) {
        siteUrlKeys.insert(url)
      }
      await mergeSiblingPublicationScopeKeys(
        authorDid: parsed.did,
        recordValue: value.values,
        atUriKeys: &atUriKeys,
        siteUrlKeys: &siteUrlKeys,
        auth: auth
      )
    }

    return PublicationAppViewScope(
      authorDid: parsed.did,
      publicationAtUri: normalized,
      publicationScopeAtUris: Array(atUriKeys).sorted(),
      publicationSiteUrls: Array(siteUrlKeys).sorted()
    )
  }

  private func publicationSiteUrlsFromRecord(_ value: [String: Any]) -> [String] {
    var urls: [String] = []
    for key in ["url", "siteUrl", "site", "homepage"] {
      if let raw = value[key] as? String,
         let norm = RenderFieldExtractor.normalizePublicationSiteUrl(raw)
      {
        urls.append(norm)
      }
    }
    return urls
  }

  private func mergeSiblingPublicationScopeKeys(
    authorDid: String,
    recordValue: [String: Any],
    atUriKeys: inout Set<String>,
    siteUrlKeys: inout Set<String>,
    auth: AuthContext
  ) async {
    let siteNorm = (recordValue["site"] as? String).flatMap {
      RenderFieldExtractor.normalizePublicationSiteUrl($0)
    }
    guard let siteNorm else { return }

    for collection in PublicationLexicons.discoveryPublicationCollections {
      let page = try? await repo.listRecords(
        auth: auth,
        repo: authorDid,
        collection: collection,
        limit: 50,
        reverse: true
      )
      guard let records = page?.records else { continue }
      for record in records {
        let site = (record.value.values["site"] as? String).flatMap {
          RenderFieldExtractor.normalizePublicationSiteUrl($0)
        }
        guard site == siteNorm else { continue }
        atUriKeys.formUnion(RenderFieldExtractor.publicationFilterEquivalenceKeys(publicationAtUri: record.uri))
        for url in publicationSiteUrlsFromRecord(record.value.values) {
          siteUrlKeys.insert(url)
        }
      }
    }
  }
}
