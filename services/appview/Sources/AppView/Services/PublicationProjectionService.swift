import AsyncHTTPClient
import Foundation
import GatewayCore
import Hummingbird
import Logging
import ThinAppViewCore

actor PublicationProjectionService {
  private let httpClient: HTTPClient
  private let plcURL: String
  private let logger: Logger
  private let repo: ATProtoAuthenticatedRepoClient
  private let thinStore: any ThinAppViewStore
  private var appViewScopeCache: [String: (scope: PublicationAppViewScope, expiresAt: Date)] = [:]
  private var discoveryCacheByViewer: [String: (context: SidebarDiscoveryContext, expiresAt: Date)] = [:]
  private var sidebarRowCacheByViewer: [String: [String: SidebarPublicationRow]] = [:]

  private static let appViewScopeCacheTTL: TimeInterval = 5 * 60
  private static let discoveryCacheTTL: TimeInterval = 2 * 60

  init(
    httpClient: HTTPClient,
    plcURL: String,
    logger: Logger,
    thinStore: any ThinAppViewStore
  ) {
    self.httpClient = httpClient
    self.plcURL = plcURL
    self.logger = logger
    self.thinStore = thinStore
    self.repo = ATProtoAuthenticatedRepoClient(httpClient: httpClient, plcURL: plcURL, logger: logger)
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

  func sidebarRows(for viewerDid: String, publicationIds: [String]) -> [SidebarPublicationRow] {
    guard let cache = sidebarRowCacheByViewer[viewerDid] else { return [] }
    return publicationIds.compactMap { cache[$0] }
  }

  // MARK: - Discovery

  private func discoverContext(auth: AuthContext) async throws -> SidebarDiscoveryContext {
    let viewerDid = auth.did

    let folders = try await loadFolders(auth: auth)
    let prefs = try await loadPublicationPrefs(auth: auth)
    let subscriptionValues = try await loadGraphSubscriptions(auth: auth)
    let skyreaderRecords = try await loadSkyreaderSubscriptions(auth: auth)

    let discovered = await PublicationFollowDiscovery.discover(
      viewerDid: viewerDid,
      auth: auth,
      repo: repo,
      httpClient: httpClient,
      plcURL: plcURL,
      logger: logger
    )

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

    let visibleDiscovery = discovered + graphOrphanRows
    let segmented = PublicationProjectionLogic.segmentDiscovery(
      visibleDiscovery,
      viewerDid: viewerDid,
      subscriptionKeys: subscriptionKeys
    )

    let subscribed = PublicationProjectionLogic.mergeSubscribed(
      graphSubscribed: segmented.graphSubscribed,
      rssRows: rssRows,
      graphOrphanRows: graphOrphanRows
    )

    let myPublications = subscribed.filter {
      PublicationProjectionLogic.viewerOwnsPublication($0, viewerDid: viewerDid)
    }

    let prefsByPublicationId = Dictionary(
      uniqueKeysWithValues: prefs.map { ($0.publicationId, $0) }
    )

    let unfoldered = subscribed.filter { row in
      guard !PublicationProjectionLogic.viewerOwnsPublication(row, viewerDid: viewerDid) else {
        return false
      }
      let folderId = prefsByPublicationId[row.publicationId]?.value["folderId"]?.value as? String
      return folderId == nil || folderId?.isEmpty == true
    }

    let following = PublicationProjectionLogic.filterFollowingTab(
      followOwnedUnsubscribed: segmented.followOwnedUnsubscribed,
      myPublications: myPublications
    )

    let allRows = discovered + rssRows + graphOrphanRows
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
    for (publicationId, row) in rows {
      merged[publicationId] = row
    }
    sidebarRowCacheByViewer[viewerDid] = merged
  }

  struct BootstrapPrioritySidebarResult: Sendable {
    let response: PublicationSidebarResponse
    let context: SidebarDiscoveryContext
  }

  func bootstrapPrioritySidebar(auth: AuthContext) async throws -> BootstrapPrioritySidebarResult {
    let context = try await discoverContext(auth: auth)
    cacheDiscovery(context, viewerDid: auth.did)
    let response = try await buildSidebarResponse(
      context: context,
      auth: auth,
      phase: .priority,
      refreshedAt: Date(),
      includeUnreadCounts: true
    )
    return BootstrapPrioritySidebarResult(response: response, context: context)
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
      includeUnreadCounts: true
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

    switch phase {
    case .folderPublications:
      let folderSections = buildFolderSections(
        context: context,
        sidebarRowById: rowCache,
        includePublications: true
      )
      let folderPublicationRows = folderSections.flatMap(\.publications)
      return PublicationSidebarResponse(
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
      return PublicationSidebarResponse(
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
      return PublicationSidebarResponse(
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

  private func loadGraphSubscriptions(auth: AuthContext) async throws -> [[String: Any]] {
    let records = try await repo.listAllRecords(
      auth: auth,
      repo: auth.did,
      collection: PublicationLexicons.graphSubscription,
      maxPages: 20
    )
    return records.map(\.value.values)
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

    var out: [String: SidebarPublicationRow] = [:]
    for row in rows {
      guard let scope = scopeCache[row.publicationId] else {
        throw HTTPError(.internalServerError)
      }
      let unreadCount: Int?
      if includeUnreadCounts {
        unreadCount = try? await thinStore.countUnreadEntries(
          viewerDid: viewerDid,
          authorDid: scope.authorDid,
          publicationAtUri: scope.publicationAtUri,
          publicationScopeAtUris: scope.publicationScopeAtUris,
          publicationSiteUrls: scope.publicationSiteUrls
        )
      } else {
        unreadCount = nil
      }
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
