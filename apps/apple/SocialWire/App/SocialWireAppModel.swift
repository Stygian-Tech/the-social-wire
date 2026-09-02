import Foundation
import LatrKit
import Observation
import SwiftData

@Observable
@MainActor
final class SocialWireAppModel {
    let authService: ATProtoOAuthService
    let resolver: ATProtoResolver
    let xrpc: XRPCClient
    let pds: PDSRecordService
    let sembleRecords: SembleRecordService
    let publicationsService: PublicationService
    let userInputFeedbackService: UserInputFeedbackService
    private let rss = RSSService()
    private let gateway: SocialWireGatewayClient
    private let latrGateway: LatrGatewayClient
    private var readerCacheCoordinator: ReaderCacheCoordinator?
    private var attemptedBookmarkMigration = false
    private var savedTagSelectionViewerDid: String?

    private static let preferencesSyncCacheKey = "v1/sync/preferences"
    private static let lastSelectedPublicationKey = "the-social-wire.last-selected-publication-id"

    var folders: [RepoRecord<FolderRecord>] = []
    var publicationPrefs: [String: RepoRecord<PublicationPrefsRecord>] = [:]
    var savedLinks: [MergedLatrSave] = []
    var archivedSavedLinks: [MergedLatrSave] = []
    private(set) var readAgeRevision = 0
    var readAtByEntryId: [String: Date] = [:] {
        didSet { readAgeRevision &+= 1 }
    }
    var entries: [EntryListItem] = [] {
        didSet { readAgeRevision &+= 1 }
    }
    var selectedPublication: DiscoveredPublication?
    var selectedEntry: EntryDetail?
    var selectedSavedLink: MergedLatrSave?
    var sembleCollections: [SembleCollectionSummary] = []
    var sembleCollection: SembleCollectionSummary?
    var sembleItems: [SembleCollectionItem] = []
    var selectedSembleItem: SembleCollectionItem?
    var sembleConnections: [SembleConnection] = []
    var pendingSembleSaveRetry: SembleSaveRetryState?
    var isLoadingSemble = false
    var sembleCollectionUnavailable = false
    var sembleCollectionLoadFailed = false
    var selectedSavedSourceKey: String?
    var selectedSavedTag: String?
    var savedTagMutationProgress: SavedTagMutationProgress?
    var isMutatingSavedTags = false
    var selectedSidebar: SidebarSelection?
    var feedSelection: FeedSelection = .topLevel(.subscribed)
    var publicationSidebarTab: PublicationSidebarTab = .subscribed
    var readerListSource: ReaderListSource = .subscribed
    var sidebarFoldersSectionExpanded = true
    var sidebarPublicationsSectionExpanded = true
    var sidebarExpandedFolderRkeys: Set<String> = []
    var viewerProfile: ActorProfileResponse?
    var readerFilter: ReaderFilter = .all
    var isLoading = false
    var isLoadingEntries = false
    var isLoadingMoreEntries = false
    /// Bootstrap NDJSON stream in flight (sidebar may still paint from cache).
    var sidebarFetching = false
    /// Folder publication rows not yet merged from stream phase two.
    var folderPublicationsLoading = false
    /// True once a cached or streamed sidebar snapshot has been applied this session.
    var hasSidebarSnapshot = false
    var errorMessage: String?
    /// Next AppView page cursor for the active publication entry list (`nil` when exhausted).
    private var entriesNextCursor: String?
    /// Lexical account preferences returned by **`app.thesocialwire.sync.getPreferences`** (optional read-later hints).
    var preferencesFromGateway: PreferencesRecord?
    var feedPreferences: ReaderFeedPreferences = .defaults
    var wireEdition: WireEditionPage?
    var circleCatalog: CircleFeedCatalog?
    var circleEdition: CircleEditionPage?
    var isLoadingCircle = false
    var circleErrorMessage: String?
    private(set) var circleHiddenStoryIds = Set<String>()
    private(set) var wireFeedbackByCanonicalURL: [String: WireArticleFeedbackValue] = [:]
    private(set) var recommendedStandardSiteDocumentURIs = Set<String>()
    private(set) var likeRecordURIByEntryID: [String: String] = [:]
    private(set) var repostRecordURIByEntryID: [String: String] = [:]
    private var articleSocialStateLoadingKeys = Set<String>()
    var wireCatalog: WireFeedCatalog?
    var wireFeedNotice: String?
    var wireFeedLoadFailed = false
    private var wireGenerationId: String?
    /// Entry id currently open under **Unread** filter — `markRead` is deferred until navigation away.
    private var unreadDeferredEntryId: String?
    /// Bumped when publication selection clears the reader; stale `selectEntry` tasks must not reopen it.
    private var entrySelectionGeneration = 0
    /// AppView scope keys from **`app.thesocialwire.publication.getSidebar`**.
    private var sidebarScopesByPublicationId: [String: PublicationAppViewScopeDTO] = [:]
    /// Server unread counts keyed by publication id (sidebar projection + optional refresh).
    private var unreadCountsByPublicationId: [String: Int] = [:]
    private var unreadCountsGeneration: Int64?
    private var unreadCountsAccuracy: String?
    private var unreadCountsCountedAt: String?
    private var sidebarSectionGenerations: [String: Int64] = [:]
    /// Cached sidebar section unread totals (recomputed when counts or folder membership change).
    private(set) var foldersSectionUnreadCount = 0
    private(set) var subscribedUnfolderedSectionUnreadCount = 0
    private(set) var folderUnreadCountsByRkey: [String: Int] = [:]
    private(set) var followingSectionUnreadCount = 0
    /// Dedupes pagination triggers when the last filtered row re-appears during fast scroll.
    private var entriesPaginationTriggeredForEntryId: String?
    /// Set false after a 404 from `app.thesocialwire.appview.*` (API deployed without `ENABLE_THIN_APPVIEW`).
    private var appViewRoutesAvailable = true

    private var gatewaySubscribedUnfoldered: [DiscoveredPublication] = []
    private var gatewayMyPublications: [DiscoveredPublication] = []
    private var gatewayFollowingTab: [DiscoveredPublication] = []
    private var gatewayAllPublicationRows: [DiscoveredPublication] = []
    private var gatewayFolderMap: [String: [DiscoveredPublication]] = [:]
    private var cachedPriorityProjection: PublicationSidebarResponseDTO?
    private var cachedFolderSections: [PublicationFolderSectionDTO]?
    private var cachedFolderRows: [SidebarPublicationRowDTO]?
    private var sidebarExpandedKeysViewerDid: String?
    private var isLoadingSidebarExpandedKeys = false
    private let sidebarProjection = SidebarProjectionStore()
    private let sidebarUnread = SidebarUnreadController()
    private let bootstrapCoordinator = BootstrapStreamCoordinator()
    private var bootstrapSawSidebarSection = false
    private var bootstrapCompletedAt: Date?
    private var pendingRestoredFeedSelection: FeedSelection?
    private(set) var sidebarTreeViewModel = SidebarTreeViewModel(
        folders: [],
        folderPublications: [:],
        unfoldered: [],
        following: [],
        unreadByPublicationId: [:],
        foldersSectionUnread: 0,
        publicationsSectionUnread: 0,
        followingSectionUnread: 0,
        folderUnreadByRkey: [:],
        loadingFlags: SidebarLoadingFlags(
            sidebarFetching: false,
            folderPublicationsLoading: false,
            hasSidebarSnapshot: false
        )
    )

    private struct SidebarLayoutRollback {
        let folders: [RepoRecord<FolderRecord>]
        let folderMap: [String: [DiscoveredPublication]]
        let subscribedUnfoldered: [DiscoveredPublication]
        let publicationPrefs: [String: RepoRecord<PublicationPrefsRecord>]
    }

    init() {
        authService = ATProtoOAuthService()
        resolver = ATProtoResolver()
        xrpc = XRPCClient(auth: authService, resolver: resolver)
        pds = PDSRecordService(xrpc: xrpc)
        sembleRecords = SembleRecordService(xrpc: xrpc)
        publicationsService = PublicationService(xrpc: xrpc)
        userInputFeedbackService = UserInputFeedbackService(auth: authService, xrpc: xrpc)
        gateway = SocialWireGatewayClient(auth: authService)
        latrGateway = LatrGatewayClient(auth: authService)
        applyReaderListSource(ReaderListSourceStorage.load(), persist: false)
    }

    /// Call once SwiftData injects **`ModelContext`** (see **`RootView`**).
    func configureReaderPersistence(modelContext: ModelContext) {
        guard readerCacheCoordinator == nil else { return }
        readerCacheCoordinator = ReaderCacheCoordinator(modelContext: modelContext)
        if let viewerDid = viewerDID {
            restoreCachedSidebarSnapshot(viewerDid: viewerDid)
            loadSidebarExpandedKeys(for: viewerDid)
            restoreLastSelectedPublicationEntriesIfCached()
        }
    }

    var isSignedIn: Bool {
        authService.session != nil
    }

    var viewerDID: String? {
        authService.session?.did
    }

    var isSembleReadLaterEnabled: Bool {
        preferencesFromGateway?.readLaterService == "semble"
    }

    var configuredSembleCollectionURI: String? {
        preferencesFromGateway?.readLaterConnections?["semble"]?.collectionUri
    }

    var configuredSembleCollectionName: String? {
        preferencesFromGateway?.readLaterConnections?["semble"]?.collectionName
    }

    var savedTabTitle: String {
        guard isSembleReadLaterEnabled else { return "Saved" }
        return sembleCollection?.name ?? configuredSembleCollectionName ?? "Semble"
    }

    var savedTabCount: Int {
        isSembleReadLaterEnabled
            ? (sembleCollection?.cardCount ?? sembleItems.count)
            : savedLinks.count
    }

    var needsSembleConfiguration: Bool {
        isSembleReadLaterEnabled &&
            (configuredSembleCollectionURI == nil || sembleCollectionUnavailable)
    }

    var visibleReaderListSources: [ReaderListSource] {
        var sources = feedPreferences.visibleFeeds
        if wireCatalog?.isAvailable == true {
            sources.insert(.wire, at: 0)
        }
        return sources
    }

    func showsTopLevelFeedUnreadCount(for source: ReaderListSource) -> Bool {
        source != .wire && feedPreferences.showsUnreadCount(for: source)
    }

    func isTopLevelFeedSelected(_ source: ReaderListSource) -> Bool {
        feedSelection == .topLevel(source)
    }

    func topLevelUnreadCount(for source: ReaderListSource) -> Int {
        switch source {
        case .wire:
            0
        case .readLater:
            savedLinks.filter { save in
                guard let subjectUri = save.subjectUri else { return true }
                return readAtByEntryId[subjectUri] == nil && save.lastOpenedAt == nil
            }.count
        case .archive:
            archivedSavedLinks.filter { save in
                guard let subjectUri = save.subjectUri else { return true }
                return readAtByEntryId[subjectUri] == nil && save.lastOpenedAt == nil
            }.count
        case .subscribed:
            sumUnread(for: subscribedPublications)
        case .following:
            sumUnread(for: followingTabPublications)
        }
    }

    private var useAppViewEntryTimelines: Bool {
        appViewRoutesAvailable
    }

    var allPublicationRows: [DiscoveredPublication] {
        gatewayAllPublicationRows
    }

    var subscribedPublications: [DiscoveredPublication] {
        gatewaySubscribedPublicationsList()
    }

    var myPublications: [DiscoveredPublication] {
        gatewayMyPublications
    }

    var subscribedUnfolderedPublications: [DiscoveredPublication] {
        gatewaySubscribedUnfoldered
    }

    var followingTabPublications: [DiscoveredPublication] {
        gatewayFollowingTab
    }

    func publicationsForSidebarTab(_ tab: PublicationSidebarTab) -> [DiscoveredPublication] {
        switch tab {
        case .subscribed: subscribedUnfolderedPublications
        case .following: followingTabPublications
        }
    }

    func publicationsForBulkRead(tab: PublicationSidebarTab) -> [DiscoveredPublication] {
        switch tab {
        case .subscribed:
            publicationsForBulkRead(list: .subscribed)
        case .following:
            publicationsForBulkRead(list: .following)
        }
    }

    func publicationsForBulkRead(list: ReaderListSource) -> [DiscoveredPublication] {
        switch list {
        case .wire, .readLater, .archive:
            return []
        case .subscribed:
            var seen = Set<String>()
            var list: [DiscoveredPublication] = []
            for folder in folders {
                for publication in publications(in: folder) where seen.insert(publication.publicationId).inserted {
                    list.append(publication)
                }
            }
            for publication in subscribedUnfolderedPublications where seen.insert(publication.publicationId).inserted {
                list.append(publication)
            }
            return list
        case .following:
            return followingTabPublications
        }
    }

    func publicationsForAllListsBulkRead() -> [DiscoveredPublication] {
        var seen = Set<String>()
        var merged: [DiscoveredPublication] = []
        for publication in publicationsForBulkRead(list: .subscribed) + publicationsForBulkRead(list: .following)
            where seen.insert(publication.publicationId).inserted {
            merged.append(publication)
        }
        return merged
    }

    func cachedEntryIdsForBulkRead(publications: [DiscoveredPublication]) -> [String] {
        let publicationIds = publications.map(\.publicationId)
        return PublicationUnreadCountLookup.distinctCachedEntryIds(
            coordinator: readerCacheCoordinator,
            publicationIds: publicationIds
        )
    }

    func cachedEntryIds(for scope: ReaderMarkReadScope) -> [String] {
        switch scope {
        case .allLists:
            cachedEntryIdsForBulkRead(publications: publicationsForAllListsBulkRead())
        case .list(let source):
            cachedEntryIdsForBulkRead(publications: publicationsForBulkRead(list: source))
        case .folder(let folderRkey):
            cachedEntryIdsForBulkRead(publications: gatewayFolderMap[folderRkey] ?? [])
        case .publication(let publicationId):
            PublicationUnreadCountLookup.distinctCachedEntryIds(
                coordinator: readerCacheCoordinator,
                publicationIds: [publicationId]
            )
        case .entry, .unavailable:
            []
        }
    }

    func isMarkReadDisabled(for scope: ReaderMarkReadScope) -> Bool {
        switch scope {
        case .unavailable:
            return true
        case .entry(let entryId):
            return readAtByEntryId[entryId] != nil
        case .allLists, .list, .folder, .publication:
            return !bulkScopeHasUnread(scope)
        }
    }

    private func bulkScopeHasUnread(_ scope: ReaderMarkReadScope) -> Bool {
        let publications = publicationsAffected(by: scope)
        if publications.contains(where: { displayUnreadCount(publicationId: $0.publicationId) > 0 }) {
            return true
        }
        return cachedEntryIds(for: scope).contains { readAtByEntryId[$0] == nil }
    }

    func markRead(for scope: ReaderMarkReadScope) async {
        switch scope {
        case .unavailable:
            return
        case .entry(let entryId):
            await markReadIfNeeded(entryId: entryId)
        case .allLists, .list, .folder, .publication:
            guard useAppViewEntryTimelines else { return }
            let scopes = gatewayMarkAllReadScopes(for: scope)
            guard !scopes.isEmpty else { return }

            let entryIds = cachedEntryIds(for: scope).filter { readAtByEntryId[$0] == nil }
            let readAt = Date()
            let savedUnreadCounts = unreadCountsByPublicationId
            let savedReadAtByEntryId = readAtByEntryId

            clearUnreadCounts(for: publicationsAffected(by: scope))
            for entryId in entryIds {
                readAtByEntryId[entryId] = readAt
            }
            unreadDeferredEntryId = nil

            do {
                for gatewayScope in scopes {
                    _ = try await gateway.markAllRead(scope: gatewayScope)
                }
                await refreshSidebarUnreadCounts(
                    publicationIds: publicationsAffected(by: scope).map(\.publicationId)
                )
            } catch {
                unreadCountsByPublicationId = savedUnreadCounts
                readAtByEntryId = savedReadAtByEntryId
                markAppViewUnavailableIfNeeded(error)
                // Mark-all-read is an automatic side effect of navigation; failures roll back the
                // optimistic counts above without interrupting the user with a modal alert.
            }
        }
    }

    func readAgeOptions(for scope: ReaderMarkReadScope) async throws -> [FeedReadAgeOption] {
        let scopes = gatewayMarkAllReadScopes(for: scope)
        guard scopes.count == 1, let gatewayScope = scopes.first else { return [] }
        return try await gateway.fetchReadAgeOptions(scope: gatewayScope).options
    }

    func markRead(for scope: ReaderMarkReadScope, before: String) async throws {
        let scopes = gatewayMarkAllReadScopes(for: scope)
        guard scopes.count == 1, let gatewayScope = scopes.first else { return }
        let viewer = viewerDID
        let result = try await gateway.markReadBefore(scope: gatewayScope, before: before)
        guard viewerDID == viewer else { return }
        guard let readAt = DateFormatters.date(from: result.readAt) else {
            throw SocialWireError.badResponse("The read confirmation contained an invalid date.")
        }
        var readMap = readAtByEntryId
        for entryID in result.entryIds where readMap[entryID] == nil {
            readMap[entryID] = readAt
        }
        readAtByEntryId = readMap
        if let deferred = unreadDeferredEntryId, result.entryIds.contains(deferred) {
            unreadDeferredEntryId = nil
        }
        sidebarUnread.bumpReadRevision()
        // Partial marking must preserve newer unread entries and reconcile exact server counts.
        applySectionUnreadCounts(result.unreadCounts, publicationIds: Array(result.unreadCounts.keys))
        await refreshSidebarUnreadCounts(
            publicationIds: publicationsAffected(by: scope).map(\.publicationId),
            force: true
        )
    }

    func markUnread(for scope: ReaderMarkReadScope) async {
        guard useAppViewEntryTimelines else { return }
        let entryIds: [String]
        switch scope {
        case .unavailable:
            return
        case .entry(let entryId):
            entryIds = readAtByEntryId[entryId] == nil ? [] : [entryId]
        case .allLists, .list, .folder, .publication:
            entryIds = cachedEntryIds(for: scope).filter { readAtByEntryId[$0] != nil }
        }
        guard !entryIds.isEmpty else { return }

        for entryId in entryIds {
            do {
                try await gateway.deleteReadMark(subjectUri: entryId)
                readAtByEntryId.removeValue(forKey: entryId)
                if let publicationId = publicationId(for: entryId) {
                    adjustUnreadCount(publicationId: publicationId, entryId: entryId, delta: 1)
                }
            } catch {
                markAppViewUnavailableIfNeeded(error)
            }
        }
        sidebarUnread.bumpReadRevision()
        await refreshSidebarUnreadCounts(
            publicationIds: publicationsAffected(by: scope).map(\.publicationId)
        )
    }

    var filteredEntries: [EntryListItem] {
        guard readerListSource.supportsReadState else { return entries }
        return switch readerFilter {
        case .all: entries
        case .unread: entries.filter { readAtByEntryId[$0.entryId] == nil }
        }
    }

    var canLoadMoreEntries: Bool {
        guard let entriesNextCursor else { return false }
        return !entriesNextCursor.isEmpty
    }

    var hasSelectedArticleFeed: Bool {
        if selectedPublication != nil { return true }
        switch feedSelection {
        case .topLevel(.wire), .topLevel(.subscribed), .topLevel(.following), .folder:
            return true
        default:
            return false
        }
    }

    func refreshSelectedArticleFeed() async {
        if let publication = selectedPublication {
            await loadEntries(for: publication, forceNetworkRefresh: true)
            return
        }
        switch feedSelection {
        case .topLevel(.wire):
            await loadWireFeed()
        case .topLevel(.subscribed):
            await loadAggregateFeed(kind: "subscribed")
        case .topLevel(.following):
            await loadAggregateFeed(kind: "following")
        case .folder(let rkey):
            await loadAggregateFeed(kind: "folder", id: rkey)
        default:
            break
        }
    }

    var effectiveReadLaterServiceId: String {
        ReadLaterServiceCatalog.defaultServiceId
    }

    func unreadCachedBadge(for publication: DiscoveredPublication) -> Int {
        displayUnreadCount(publicationId: publication.publicationId)
    }

  /// AppView baseline reconciled with cached feed rows and local read state.
  private func displayUnreadCount(publicationId: String) -> Int {
    sidebarUnread.displayCount(
      publicationId: publicationId,
      readAtByEntryId: readAtByEntryId,
      coordinator: readerCacheCoordinator
    )
  }

  private func unreadAccuracyRank(_ accuracy: String?) -> Int {
    switch accuracy {
    case "exact": 2
    case "estimated": 1
    default: 0
    }
  }

  private func shouldApplyUnreadCountsSnapshot(generation: Int64?, accuracy: String?) -> Bool {
    guard let generation else { return true }
    if let current = unreadCountsGeneration, generation < current {
      return false
    }
    if unreadCountsGeneration == generation {
      return unreadAccuracyRank(accuracy) >= unreadAccuracyRank(unreadCountsAccuracy)
    }
    return true
  }

  private func applyUnreadCountMetadata(
    generation: Int64?,
    accuracy: String?,
    countedAt: String?
  ) {
    unreadCountsGeneration = generation ?? unreadCountsGeneration
    unreadCountsAccuracy = accuracy ?? unreadCountsAccuracy
    unreadCountsCountedAt = countedAt ?? unreadCountsCountedAt
  }

  private func markUnreadCountsOptimistic() {
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    unreadCountsGeneration = max(now, (unreadCountsGeneration ?? 0) + 1)
    unreadCountsAccuracy = "estimated"
    unreadCountsCountedAt = DateFormatters.string(from: Date())
  }

  private func adjustUnreadCount(publicationId: String, delta: Int) {
    markUnreadCountsOptimistic()
    sidebarUnread.adjustCount(publicationId: publicationId, delta: delta)
    unreadCountsByPublicationId = sidebarUnread.unreadCountsByPublicationId
    cachedPriorityProjection = sidebarUnread.cachedPriorityProjection
    rebuildSidebarTreeViewModel()
  }

  private func adjustUnreadCount(
    publicationId: String,
    entryId: String,
    delta: Int
  ) {
    if sidebarUnread.shouldDeferBaselineDelta(
      publicationId: publicationId,
      entryId: entryId,
      coordinator: readerCacheCoordinator
    ) {
      sidebarUnread.bumpReadRevision()
      markUnreadCountsOptimistic()
      rebuildSidebarTreeViewModel()
      return
    }
    adjustUnreadCount(publicationId: publicationId, delta: delta)
  }

  private func publicationId(for entryId: String) -> String? {
    if let selectedPublication,
       entries.contains(where: { $0.entryId == entryId })
    {
      return selectedPublication.publicationId
    }
    if let publication = gatewayAllPublicationRows.first(where: { publication in
      let cacheKeys = [
        publication.publicationId,
        normalizeATRepoParam(publication.publicationId),
        canonicalPublicationAtUriKey(publication.publicationId),
      ].compactMap { $0 }
      return cacheKeys.contains { cacheKey in
        (try? readerCacheCoordinator?.publicationEntries(cacheKey))?
          .contains(where: { $0.entryId == entryId }) == true
      }
    }) {
      return publication.publicationId
    }
    return selectedPublication?.publicationId
  }

    private func sidebarPublicationIds() -> [String] {
        Array(
            Set(
                gatewayAllPublicationRows.map(\.publicationId)
                    + gatewayMyPublications.map(\.publicationId)
                    + gatewaySubscribedUnfoldered.map(\.publicationId)
                    + gatewayFollowingTab.map(\.publicationId)
            )
        )
    }

    private func applyStreamUnreadCounts(
        _ counts: [String: Int],
        replacePublicationIds: [String]? = nil,
        generation: Int64? = nil,
        accuracy: String? = nil,
        countedAt: String? = nil
    ) {
        applyFetchedUnreadCounts(
            counts,
            publicationIds: replacePublicationIds ?? sidebarPublicationIds(),
            generation: generation,
            accuracy: accuracy,
            countedAt: countedAt
        )
    }

    private func applyFetchedUnreadCounts(
        _ counts: [String: Int],
        publicationIds: [String],
        generation: Int64? = nil,
        accuracy: String? = nil,
        countedAt: String? = nil
    ) {
        guard shouldApplyUnreadCountsSnapshot(generation: generation, accuracy: accuracy) else {
            return
        }
        sidebarUnread.cachedPriorityProjection = cachedPriorityProjection
        sidebarUnread.applyFetchedCounts(counts, publicationIds: publicationIds)
        unreadCountsByPublicationId = sidebarUnread.unreadCountsByPublicationId
        cachedPriorityProjection = sidebarUnread.cachedPriorityProjection
        applyUnreadCountMetadata(
            generation: generation,
            accuracy: accuracy,
            countedAt: countedAt
        )
        refreshSidebarUnreadSumCaches()
    }

    @ObservationIgnored private var launchStartedAt: Date?

    func restoreSession() async {
        launchStartedAt = Date()
        await authService.restoreSession()
        if isSignedIn {
            await refreshAll()
        }
    }

    func signIn(handle: String) async {
        do {
            errorMessage = nil
            try await authService.signIn(handle: handle)
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleOAuthCallback(_ url: URL) async {
        do {
            errorMessage = nil
            try await authService.handleCallbackURL(url)
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        if let viewerDID {
            try? readerCacheCoordinator?.clearCircleDiscoveryCache(viewerDID: viewerDID)
        }
        authService.signOut()
        folders = []
        publicationPrefs = [:]
        sidebarScopesByPublicationId = [:]
        unreadCountsByPublicationId = [:]
        unreadCountsGeneration = nil
        unreadCountsAccuracy = nil
        unreadCountsCountedAt = nil
        sidebarSectionGenerations = [:]
        foldersSectionUnreadCount = 0
        subscribedUnfolderedSectionUnreadCount = 0
        folderUnreadCountsByRkey = [:]
        followingSectionUnreadCount = 0
        entriesPaginationTriggeredForEntryId = nil
        gatewaySubscribedUnfoldered = []
        gatewayMyPublications = []
        gatewayFollowingTab = []
        gatewayAllPublicationRows = []
        gatewayFolderMap = [:]
        appViewRoutesAvailable = true
        savedLinks = []
        archivedSavedLinks = []
        entries = []
        selectedEntry = nil
        selectedPublication = nil
        selectedSavedLink = nil
        sembleCollections = []
        sembleCollection = nil
        sembleItems = []
        selectedSembleItem = nil
        sembleConnections = []
        pendingSembleSaveRetry = nil
        isLoadingSemble = false
        selectedSavedSourceKey = nil
        selectedSavedTag = nil
        savedTagSelectionViewerDid = nil
        savedTagMutationProgress = nil
        isMutatingSavedTags = false
        selectedSidebar = nil
        feedSelection = .topLevel(.subscribed)
        viewerProfile = nil
        preferencesFromGateway = nil
        feedPreferences = .defaults
        wireCatalog = nil
        wireFeedNotice = nil
        wireFeedLoadFailed = false
        wireEdition = nil
        circleCatalog = nil
        circleEdition = nil
        circleHiddenStoryIds = []
        circleErrorMessage = nil
        wireFeedbackByCanonicalURL = [:]
        recommendedStandardSiteDocumentURIs = []
        likeRecordURIByEntryID = [:]
        repostRecordURIByEntryID = [:]
        articleSocialStateLoadingKeys = []
        wireGenerationId = nil
        unreadDeferredEntryId = nil
        sidebarFetching = false
        folderPublicationsLoading = false
        hasSidebarSnapshot = false
        cachedPriorityProjection = nil
        stopProactiveFeedRefreshLoop()
        cachedFolderSections = nil
        cachedFolderRows = nil
        sidebarExpandedKeysViewerDid = nil
        sidebarFoldersSectionExpanded = true
        sidebarPublicationsSectionExpanded = true
        sidebarExpandedFolderRkeys = []
        sidebarProjection.reset()
        sidebarUnread.reset()
        bootstrapCoordinator.reset()
        bootstrapCompletedAt = nil
        rebuildSidebarTreeViewModel()
    }

    func toggleSidebarFolderExpanded(rkey: String) {
        if sidebarExpandedFolderRkeys.contains(rkey) {
            sidebarExpandedFolderRkeys.remove(rkey)
        } else {
            sidebarExpandedFolderRkeys.insert(rkey)
        }
        persistSidebarExpandedKeysIfLoaded()
    }

    func noteSidebarExpandedPresentationChanged() {
        persistSidebarExpandedKeysIfLoaded()
    }

    private func loadSidebarExpandedKeys(for viewerDid: String) {
        isLoadingSidebarExpandedKeys = true
        defer { isLoadingSidebarExpandedKeys = false }

        sidebarExpandedKeysViewerDid = viewerDid
        let snapshot = SidebarExpandedKeysStorage.load(viewerDid: viewerDid)
        sidebarFoldersSectionExpanded = snapshot.foldersSectionExpanded
        sidebarPublicationsSectionExpanded = snapshot.publicationsSectionExpanded
        sidebarExpandedFolderRkeys = snapshot.expandedFolderRkeys
    }

    private func persistSidebarExpandedKeysIfLoaded() {
        guard !isLoadingSidebarExpandedKeys else { return }
        guard let viewerDID, sidebarExpandedKeysViewerDid == viewerDID else { return }

        SidebarExpandedKeysStorage.save(
            viewerDid: viewerDID,
            snapshot: SidebarExpandedSnapshot(
                foldersSectionExpanded: sidebarFoldersSectionExpanded,
                publicationsSectionExpanded: sidebarPublicationsSectionExpanded,
                expandedFolderRkeys: sidebarExpandedFolderRkeys
            )
        )
    }

    private func migrateSidebarFolderExpandKey(oldRkey: String, newRkey: String) {
        guard oldRkey != newRkey else { return }

        if sidebarExpandedFolderRkeys.contains(oldRkey) {
            sidebarExpandedFolderRkeys.remove(oldRkey)
            sidebarExpandedFolderRkeys.insert(newRkey)
        }

        if let viewerDID {
            SidebarExpandedKeysStorage.migrateFolderExpandKey(
                viewerDid: viewerDID,
                oldRkey: oldRkey,
                newRkey: newRkey
            )
        }
    }

    func sumUnread(for publications: [DiscoveredPublication]) -> Int {
        sumUnreadCount(for: publications, unreadCount: unreadCachedBadge(for:))
    }

    func folderUnreadCount(rkey: String) -> Int {
        folderUnreadCountsByRkey[rkey] ?? 0
    }

    private func refreshSidebarUnreadSumCaches() {
        sidebarUnread.refreshSectionSums(
            folders: folders,
            folderMap: gatewayFolderMap,
            subscribedUnfoldered: subscribedUnfolderedPublications,
            following: followingTabPublications,
            displayCount: { publication in
                displayUnreadCount(publicationId: publication.publicationId)
            }
        )
        subscribedUnfolderedSectionUnreadCount = sidebarUnread.subscribedUnfolderedSectionUnreadCount
        followingSectionUnreadCount = sidebarUnread.followingSectionUnreadCount
        folderUnreadCountsByRkey = sidebarUnread.folderUnreadCountsByRkey
        foldersSectionUnreadCount = sidebarUnread.foldersSectionUnreadCount
        rebuildSidebarTreeViewModel()
    }

    private func rebuildSidebarTreeViewModel() {
        var unreadByPublicationId: [String: Int] = [:]
        for publication in gatewayAllPublicationRows {
            unreadByPublicationId[publication.publicationId] = displayUnreadCount(
                publicationId: publication.publicationId
            )
        }
        sidebarTreeViewModel = SidebarTreeViewModel(
            folders: folders,
            folderPublications: gatewayFolderMap,
            unfoldered: subscribedUnfolderedPublications,
            following: followingTabPublications,
            unreadByPublicationId: unreadByPublicationId,
            foldersSectionUnread: foldersSectionUnreadCount,
            publicationsSectionUnread: subscribedUnfolderedSectionUnreadCount,
            followingSectionUnread: followingSectionUnreadCount,
            folderUnreadByRkey: folderUnreadCountsByRkey,
            loadingFlags: SidebarLoadingFlags(
                sidebarFetching: sidebarFetching,
                folderPublicationsLoading: folderPublicationsLoading,
                hasSidebarSnapshot: hasSidebarSnapshot
            )
        )
    }

    func openMyPublications() {
        selectedSidebar = .myPublications
        selectedPublication = nil
        selectedEntry = nil
        selectedSavedLink = nil
        selectedSavedSourceKey = nil
        entries = []
    }

    func selectReaderListSource(_ source: ReaderListSource) {
        guard readerListSource != source || feedSelection != .topLevel(source) else { return }
        selectedEntry = nil
        unreadDeferredEntryId = nil
        applyReaderListSource(source, persist: true)
    }

    private func applyReaderListSource(_ source: ReaderListSource, persist: Bool) {
        readerListSource = source
        feedSelection = .topLevel(source)
        selectedSavedSourceKey = nil
        if persist {
            ReaderListSourceStorage.save(source)
            if let viewerDID {
                FeedSelectionStorage.save(feedSelection, viewerDid: viewerDID)
            }
        }

        switch source {
        case .wire:
            selectedSidebar = nil
            selectedPublication = nil
            selectedSavedLink = nil
            entries = []
            if persist {
                Task { await loadWireFeed() }
            }
        case .readLater, .archive:
            selectedSidebar = .saved
            selectedPublication = nil
            selectedSavedLink = nil
            entries = []
            Task { await refreshSavedLinks() }
        case .subscribed:
            publicationSidebarTab = .subscribed
            selectedSidebar = nil
            selectedPublication = nil
            selectedSavedLink = nil
            entries = []
            if persist {
                Task { await loadAggregateFeed(kind: "subscribed") }
            }
        case .following:
            publicationSidebarTab = .following
            selectedSidebar = nil
            selectedPublication = nil
            selectedSavedLink = nil
            entries = []
            if persist {
                Task { await loadAggregateFeed(kind: "following") }
            }
        }
    }

    func selectFolderFeed(folderRkey: String) async {
        prepareForPublicationSelection()
        readerListSource = .subscribed
        publicationSidebarTab = .subscribed
        feedSelection = .folder(folderRkey)
        if let viewerDID {
            FeedSelectionStorage.save(feedSelection, viewerDid: viewerDID)
        }
        selectedSidebar = nil
        selectedPublication = nil
        entries = []
        await loadAggregateFeed(kind: "folder", id: folderRkey)
    }

    private func loadAggregateFeed(
        kind: String,
        id: String? = nil,
        cursor: String? = nil
    ) async {
        if cursor == nil {
            entriesNextCursor = nil
            entriesPaginationTriggeredForEntryId = nil
            isLoadingEntries = true
        } else {
            isLoadingMoreEntries = true
        }
        defer {
            if cursor == nil { isLoadingEntries = false }
            else { isLoadingMoreEntries = false }
        }
        do {
            let page = try await gateway.fetchAggregateAppViewFeed(
                kind: kind,
                id: id,
                filter: readerFilter,
                cursor: cursor
            )
            applyAuthoritativeReadState(from: page.entries)
            entries = cursor == nil
                ? page.entries
                : mergeEntryPages(existing: entries, newPage: page.entries)
            entriesNextCursor = page.cursor
            if readerFilter == .all {
                persistAggregateEntriesByPublication(page.entries)
            }
            await prefetchThumbnailImages(for: page.entries)
        } catch {
            markAppViewUnavailableIfNeeded(error)
            if entries.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    private var preferredWireLanguage: String {
        preferredDiscoveryLanguage(supported: wireCatalog?.supportedLanguages)
    }

    private var preferredCircleLanguage: String {
        preferredDiscoveryLanguage(supported: circleCatalog?.supportedLanguages)
    }

    private func preferredDiscoveryLanguage(supported: [String]?) -> String {
        let preferred = Locale.current.language.languageCode?.identifier ?? "en"
        guard let supported, !supported.isEmpty else { return preferred }
        if supported.contains(preferred) { return preferred }
        if let language = supported.first(where: { preferred.hasPrefix($0 + "-") }) {
            return language
        }
        return supported.first ?? preferred
    }

    func refreshWireCatalog() async {
        do {
            let catalog = try await gateway.fetchFeedCatalog()
            wireCatalog = catalog
            guard catalog.isAvailable else {
                if readerListSource == .wire {
                    let fallback = feedPreferences.visibleFeeds.first ?? .subscribed
                    applyReaderListSource(fallback, persist: true)
                }
                return
            }
            if readerListSource == .wire, entries.isEmpty {
                await loadWireFeed()
            }
        } catch {
            // Keep an already-confirmed catalog during a transient refresh failure. On a cold
            // launch, fail closed so an operator-disabled feed never appears from client defaults.
            if wireCatalog == nil, readerListSource == .wire {
                let fallback = feedPreferences.visibleFeeds.first ?? .subscribed
                applyReaderListSource(fallback, persist: true)
            }
        }
    }

    func loadWireFeed(cursor: String? = nil) async {
        guard wireCatalog?.isAvailable == true, let viewerDID else { return }
        let language = preferredWireLanguage
        var restoredCache = false

        if cursor == nil,
           let coordinator = readerCacheCoordinator,
           let cached = try? coordinator.wireFeedPage(
               viewerDID: viewerDID,
               language: language
           ) {
            _ = applyWirePage(cached, replacing: true)
            restoredCache = !cached.items.isEmpty
        }

        if cursor == nil {
            entriesNextCursor = nil
            entriesPaginationTriggeredForEntryId = nil
            isLoadingEntries = !restoredCache
        } else {
            isLoadingMoreEntries = true
        }
        defer {
            if cursor == nil { isLoadingEntries = false }
            else { isLoadingMoreEntries = false }
        }

        do {
            let page = try await gateway.fetchWire(
                language: language,
                cursor: cursor
            )
            guard readerListSource == .wire else { return }
            guard applyWirePage(page, replacing: cursor == nil) else { return }
            if cursor == nil {
                try? readerCacheCoordinator?.upsertWireFeedPage(
                    page,
                    viewerDID: viewerDID
                )
            }
            await prefetchThumbnailImages(for: page.items.map { $0.toEntryListItem() })
        } catch {
            guard readerListSource == .wire else { return }
            wireFeedLoadFailed = entries.isEmpty
            if !entries.isEmpty {
                wireFeedNotice = "Showing the most recently cached edition."
            }
        }
    }

    @discardableResult
    private func applyWirePage(_ page: WireFeedPage, replacing: Bool) -> Bool {
        if !replacing, let wireGenerationId, page.generationId != wireGenerationId {
            return false
        }
        let pageEntries = page.items.map { $0.toEntryListItem() }
        entries = replacing
            ? pageEntries
            : mergeEntryPages(existing: entries, newPage: pageEntries)
        wireGenerationId = page.generationId
        entriesNextCursor = page.cursor
        wireFeedNotice = page.notice
        wireFeedLoadFailed = false
        return true
    }

    func loadMoreSelectedFeedIfNeeded(triggeredByEntryId entryId: String) async {
        guard entriesPaginationTriggeredForEntryId != entryId else { return }
        entriesPaginationTriggeredForEntryId = entryId
        guard let cursor = entriesNextCursor,
              !isLoadingEntries,
              !isLoadingMoreEntries
        else { return }
        switch feedSelection {
        case .topLevel(.wire):
            if wireEdition != nil {
                await loadWireEdition(cursor: cursor)
            } else {
                await loadWireFeed(cursor: cursor)
            }
        case .topLevel(.subscribed):
            await loadAggregateFeed(kind: "subscribed", cursor: cursor)
        case .topLevel(.following):
            await loadAggregateFeed(kind: "following", cursor: cursor)
        case .folder(let rkey):
            await loadAggregateFeed(kind: "folder", id: rkey, cursor: cursor)
        default:
            entriesPaginationTriggeredForEntryId = nil
        }
    }

    func loadWireEdition(cursor: String? = nil) async {
        guard wireCatalog?.isAvailable == true, let viewerDID else { return }
        let language = preferredWireLanguage
        var restoredCache = false

        if cursor == nil,
           let coordinator = readerCacheCoordinator,
           let cached = try? coordinator.wireEditionPage(
               viewerDID: viewerDID,
               language: language
           ) {
            let mapped = cached.stories.map { $0.toEntryListItem() }
            wireEdition = cached
            entries = mapped
            wireGenerationId = cached.generationId
            entriesNextCursor = cached.moreCursor
            wireFeedNotice = cached.degraded ? "This cached edition is using a limited fallback." : nil
            wireFeedLoadFailed = false
            restoredCache = !mapped.isEmpty
        }

        if cursor == nil {
            isLoadingEntries = !restoredCache
        } else {
            isLoadingMoreEntries = true
        }
        defer {
            isLoadingEntries = false
            isLoadingMoreEntries = false
        }

        do {
            let page = try await gateway.fetchWireEdition(
                language: language,
                cursor: cursor
            )
            let mapped = page.stories.map { $0.toEntryListItem() }
            entries = cursor == nil ? mapped : mergeEntryPages(existing: entries, newPage: mapped)
            wireEdition = page
            wireGenerationId = page.generationId
            entriesNextCursor = page.moreCursor
            wireFeedNotice = page.degraded ? "This edition is using a limited fallback." : nil
            wireFeedLoadFailed = false
            if cursor == nil {
                try? readerCacheCoordinator?.upsertWireEditionPage(
                    page,
                    viewerDID: viewerDID,
                    language: language
                )
            }
        } catch {
            if cursor == nil {
                if restoredCache {
                    wireFeedNotice = "Showing the most recently cached edition."
                } else {
                    wireEdition = nil
                    await loadWireFeed()
                }
            } else {
                wireFeedNotice = error.localizedDescription
            }
        }
    }

    func refreshCircleCatalog() async {
        guard isSignedIn else {
            circleCatalog = nil
            return
        }
        do {
            circleCatalog = try await gateway.fetchCircleCatalog()
            if circleCatalog?.isAvailable != true {
                circleEdition = nil
            }
        } catch {
            circleCatalog = nil
            circleEdition = nil
        }
    }

    func loadCircleEdition(cursor: String? = nil) async {
        guard circleCatalog?.isAvailable == true, let viewerDID else { return }
        let language = preferredCircleLanguage
        var restoredCache = false

        if cursor == nil,
           let coordinator = readerCacheCoordinator,
           let cached = try? coordinator.circleEditionPage(
               viewerDID: viewerDID,
               language: language
           ) {
            circleEdition = cached
            restoredCache = !cached.stories.isEmpty
        }

        isLoadingCircle = !restoredCache
        circleErrorMessage = nil
        defer { isLoadingCircle = false }
        do {
            let page = try await gateway.fetchCircleEdition(
                language: language,
                cursor: cursor
            )
            if cursor == nil || circleEdition == nil {
                circleEdition = page
            } else if let current = circleEdition {
                circleEdition = CircleEditionPage(
                    editionVersion: page.editionVersion,
                    generationId: page.generationId,
                    generatedAt: page.generatedAt,
                    language: page.language,
                    source: page.source,
                    degraded: page.degraded,
                    stories: mergeCircleStories(existing: current.stories, new: page.stories),
                    topStoryIds: page.topStoryIds,
                    publicationSpotlights: page.publicationSpotlights,
                    storyRails: page.storyRails,
                    trendingStoryIds: page.trendingStoryIds,
                    moreCursor: page.moreCursor
                )
            }
            if cursor == nil {
                try? readerCacheCoordinator?.upsertCircleEditionPage(
                    page,
                    viewerDID: viewerDID,
                    language: language
                )
            }
        } catch {
            circleErrorMessage = restoredCache
                ? "Showing the most recently cached edition."
                : error.localizedDescription
        }
    }

    var visibleCircleStories: [CircleStory] {
        circleEdition?.stories.filter { !circleHiddenStoryIds.contains($0.storyId) } ?? []
    }

    func selectCircleStory(_ story: CircleStory) {
        if let viewerDID,
           let cached = try? readerCacheCoordinator?.circleItemDetail(
               storyId: story.storyId,
               viewerDID: viewerDID
           ) {
            selectedEntry = cached
        } else {
            let detail = story.toEntryDetail()
            selectedEntry = detail
            if let viewerDID {
                try? readerCacheCoordinator?.upsertCircleItemDetail(
                    detail,
                    storyId: story.storyId,
                    viewerDID: viewerDID
                )
            }
        }
        selectedSavedLink = nil
    }

    func setCircleStory(_ story: CircleStory, hidden: Bool) async {
        if hidden {
            circleHiddenStoryIds.insert(story.storyId)
        } else {
            circleHiddenStoryIds.remove(story.storyId)
        }
        do {
            _ = try await gateway.setCircleItemHidden(storyId: story.storyId, hidden: hidden)
        } catch {
            if hidden {
                circleHiddenStoryIds.remove(story.storyId)
            } else {
                circleHiddenStoryIds.insert(story.storyId)
            }
            circleErrorMessage = error.localizedDescription
        }
    }

    private func mergeCircleStories(existing: [CircleStory], new: [CircleStory]) -> [CircleStory] {
        var result = existing
        var ids = Set(existing.map(\.storyId))
        for story in new where ids.insert(story.storyId).inserted {
            result.append(story)
        }
        return result
    }

    func setFeedVisible(_ source: ReaderListSource, visible: Bool) async {
        guard source != .wire else { return }
        var next = feedPreferences.visibleFeeds
        if visible {
            if !next.contains(source) { next.append(source) }
        } else {
            guard next.count > 1 else { return }
            next.removeAll { $0 == source }
        }
        feedPreferences = ReaderFeedPreferences(
            visibleFeeds: next,
            feedsWithUnreadCounts: visible
                ? feedPreferences.feedsWithUnreadCounts
                : feedPreferences.feedsWithUnreadCounts.filter { $0 != source },
            articleOpenMode: feedPreferences.articleOpenMode
        )
        if let viewerDID {
            ReaderFeedPreferencesStorage.save(feedPreferences, viewerDid: viewerDID)
        }
        if feedSelection == .topLevel(source), !visible,
           let replacement = nextVisibleReaderFeed(after: source, among: next) {
            selectReaderListSource(replacement)
        }
        try? await pds.upsertFeedDisplayPreferences(feedPreferences)
    }

    func setFeedUnreadCountVisible(_ source: ReaderListSource, visible: Bool) async {
        guard source != .wire else { return }
        guard feedPreferences.visibleFeeds.contains(source) else { return }
        let feedsWithUnreadCounts = visible
            ? ReaderListSource.preferenceCases.filter {
                $0 == source || feedPreferences.feedsWithUnreadCounts.contains($0)
            }
            : feedPreferences.feedsWithUnreadCounts.filter { $0 != source }
        feedPreferences = ReaderFeedPreferences(
            visibleFeeds: feedPreferences.visibleFeeds,
            feedsWithUnreadCounts: feedsWithUnreadCounts,
            articleOpenMode: feedPreferences.articleOpenMode
        )
        if let viewerDID {
            ReaderFeedPreferencesStorage.save(feedPreferences, viewerDid: viewerDID)
        }
        try? await pds.upsertFeedDisplayPreferences(feedPreferences)
    }

    func setArticleOpenMode(_ mode: ArticleOpenMode) async {
        guard feedPreferences.articleOpenMode != mode else { return }
        feedPreferences.articleOpenMode = mode
        if let viewerDID {
            ReaderFeedPreferencesStorage.save(feedPreferences, viewerDid: viewerDID)
        }
        try? await pds.upsertArticleOpenMode(mode)
    }

    private func nextVisibleReaderFeed(
        after source: ReaderListSource,
        among visible: [ReaderListSource]
    ) -> ReaderListSource? {
        guard let start = ReaderListSource.preferenceCases.firstIndex(of: source) else {
            return visible.first
        }
        for offset in 1 ... ReaderListSource.preferenceCases.count {
            let candidate = ReaderListSource.preferenceCases[
                (start + offset) % ReaderListSource.preferenceCases.count
            ]
            if visible.contains(candidate) { return candidate }
        }
        return visible.first
    }

    func refreshAll() async {
        await refreshWireCatalog()
        await refreshSidebarProjection()
        await refreshActiveReaderContentIfNeeded()
    }

    /// Bootstrap stream + sidebar snapshot only (pull-to-refresh on Publications pane).
    func refreshSidebarProjection() async {
        guard let viewerDID else { return }
        if let cachedFeedPreferences = ReaderFeedPreferencesStorage.load(viewerDid: viewerDID) {
            feedPreferences = cachedFeedPreferences
            if case let .topLevel(source) = feedSelection,
               !feedPreferences.visibleFeeds.contains(source),
               let replacement = feedPreferences.visibleFeeds.first {
                applyReaderListSource(replacement, persist: true)
            }
        }
        pendingRestoredFeedSelection = FeedSelectionStorage.load(viewerDid: viewerDID)
        loadSidebarExpandedKeys(for: viewerDID)
        isLoading = true
        sidebarFetching = true
        folderPublicationsLoading = !hasSidebarSnapshot
        bootstrapSawSidebarSection = false
        rebuildSidebarTreeViewModel()

        restoreCachedSidebarSnapshot(viewerDid: viewerDID)
        restoreLastSelectedPublicationEntriesIfCached()
        if hasSidebarSnapshot, let launchStartedAt {
            logBootstrapPhase("cachedContentReady", startedAt: launchStartedAt)
        }

        do {
            try await refreshPublicationSidebarFromBootstrapStream(viewerDID: viewerDID)
            await restorePersistedFeedSelectionIfPossible()
            bootstrapCompletedAt = Date()
            persistSidebarSnapshot(viewerDid: viewerDID)
            Task(priority: .utility) { [weak self] in
                await self?.refreshGatewayPreferencesSnapshot()
            }
            Task(priority: .utility) { [weak self] in
                try? await Task.sleep(for: .seconds(SidebarFetchScheduler.prefetchDelaySeconds))
                await self?.prefetchSidebarPublicationsLimited()
            }
            startProactiveFeedRefreshLoop()
        } catch {
            if !hasSidebarSnapshot {
                errorMessage = "Could not load publications from the server. \(error.localizedDescription)"
            }
        }
    }

    /// Hydrate viewer profile and saved links after sidebar projection refresh.
    func refreshActiveReaderContentIfNeeded() async {
        guard let viewerDID else { return }
        await hydrateViewerStateAfterBootstrap(viewerDID: viewerDID)
    }

    private func refreshPublicationSidebarFromBootstrapStream(viewerDID: String) async throws {
        bootstrapCoordinator.reset()
        bootstrapSawSidebarSection = false
        let streamStarted = Date()

        try await gateway.consumeBootstrapStream { [weak self] event in
            Task { @MainActor in
                self?.applyBootstrapStreamEvent(event, streamStarted: streamStarted)
            }
        }

        await applyPendingStreamedBootstrapSelectionIfNeeded()
        logBootstrapPhase("streamReady", startedAt: streamStarted)
    }

    private func hydrateViewerStateAfterBootstrap(viewerDID: String) async {
        async let profileTask = publicationsService.fetchActorProfile(actor: viewerDID)

        await refreshSavedLinks()
        viewerProfile = try? await profileTask
    }

    private func logBootstrapPhase(_ phase: String, startedAt: Date) {
        #if DEBUG
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        print("[bootstrap-perf] \(phase) +\(ms)ms")
        #endif
    }

    private func applyBootstrapStreamEvent(_ event: BootstrapStreamEventDTO, streamStarted: Date = Date()) {
        switch event.kind {
        case .sidebarPriority:
            guard let projection = event.sidebarPriority else { return }
            applyGatewaySidebarProjection(projection)
            hasSidebarSnapshot = true
            folderPublicationsLoading = true
            sidebarFetching = false
            logBootstrapPhase("sidebarPriority", startedAt: streamStarted)
            bootstrapCoordinator.schedulePendingSelection { [weak self] in
                await self?.applyPendingStreamedBootstrapSelectionIfNeeded()
            }
        case .unreadCounts:
            guard let payload = event.unreadCounts else { return }
            applyStreamUnreadCounts(
                payload.counts,
                replacePublicationIds: payload.replacePublicationIds,
                generation: payload.generation,
                accuracy: payload.accuracy,
                countedAt: payload.countedAt
            )
            logBootstrapPhase("unreadCounts", startedAt: streamStarted)
        case .sidebarSection:
            guard let payload = event.sidebarSection else { return }
            bootstrapSawSidebarSection = true
            mergeSidebarSection(payload)
            folderPublicationsLoading = false
            logBootstrapPhase("sidebarSection", startedAt: streamStarted)
            bootstrapCoordinator.schedulePendingSelection { [weak self] in
                await self?.applyPendingStreamedBootstrapSelectionIfNeeded()
            }
        case .selectedPublication:
            bootstrapCoordinator.pendingStreamSelectedPublicationId =
                event.selectedPublication?.publicationId
            bootstrapCoordinator.schedulePendingSelection { [weak self] in
                await self?.applyPendingStreamedBootstrapSelectionIfNeeded()
            }
        case .entriesPage:
            bootstrapCoordinator.pendingStreamedEntriesPage = event.entriesPage
            logBootstrapPhase("entriesPage", startedAt: streamStarted)
            isLoading = false
            bootstrapCoordinator.schedulePendingSelection { [weak self] in
                await self?.applyPendingStreamedBootstrapSelectionIfNeeded()
            }
        case .sidebarFolders:
            guard let payload = event.sidebarFolders else { return }
            guard !bootstrapSawSidebarSection else {
                folderPublicationsLoading = false
                logBootstrapPhase("sidebarFoldersSkipped", startedAt: streamStarted)
                return
            }
            mergeFolderPublications(from: PublicationSidebarResponseDTO(
                viewerDid: viewerDID ?? "",
                folders: nil,
                publicationPrefs: nil,
                folderSections: payload.folderSections,
                allPublicationRows: payload.allPublicationRows,
                myPublications: [],
                subscribedUnfoldered: [],
                followingTabPublications: [],
                enrollAuthorDids: [],
                refreshedAt: DateFormatters.string(from: Date()),
                unreadCountsByPublicationId: nil
            ))
            folderPublicationsLoading = false
            logBootstrapPhase("sidebarFolders", startedAt: streamStarted)
            bootstrapCoordinator.schedulePendingSelection { [weak self] in
                await self?.applyPendingStreamedBootstrapSelectionIfNeeded()
            }
        case .warning, .error:
            break
        case .done:
            isLoading = false
            sidebarFetching = false
            folderPublicationsLoading = false
            bootstrapCompletedAt = Date()
            rebuildSidebarTreeViewModel()
            logBootstrapPhase("done", startedAt: streamStarted)
            scheduleBootstrapFeedRefresh()
            bootstrapCoordinator.schedulePendingSelection { [weak self] in
                await self?.applyPendingStreamedBootstrapSelectionIfNeeded()
            }
        }
    }

    private func applyPendingStreamedBootstrapSelectionIfNeeded() async {
        guard let publicationId = bootstrapCoordinator.pendingStreamSelectedPublicationId else { return }
        guard let publication = publicationMatchingId(publicationId) else { return }

        let matchesCurrentSelection = selectedPublication.map {
            PublicationUnreadCountLookup.publicationIdsMatch($0.publicationId, publicationId)
        } ?? false

        if let page = bootstrapCoordinator.pendingStreamedEntriesPage,
           PublicationUnreadCountLookup.publicationIdsMatch(page.publicationId, publicationId) {
            guard !matchesCurrentSelection || entries.isEmpty else {
                bootstrapCoordinator.pendingStreamedEntriesPage = nil
                bootstrapCoordinator.pendingStreamSelectedPublicationId = nil
                return
            }
        applyStreamedPublicationSelection(publication: publication, entries: page.entries, cursor: page.cursor)
        bootstrapCoordinator.pendingStreamedEntriesPage = nil
        bootstrapCoordinator.pendingStreamSelectedPublicationId = nil
        if page.entries.isEmpty {
            scheduleBootstrapFeedRefresh()
        }
        return
        }

        guard selectedPublication == nil else { return }
        await selectPublication(publication)
    }

    func publication(forId publicationId: String) -> DiscoveredPublication? {
        publicationMatchingId(publicationId)
    }

    func resolvedSavedLinkPublicationChip(for save: MergedLatrSave) -> SavedLinkPublicationChipModel? {
        SavedLinkPublicationResolver.resolve(
            for: save,
            sidebarPublications: allPublicationRows,
            publicationScopes: sidebarScopesByPublicationId
        )
    }

    private func publicationMatchingId(_ publicationId: String) -> DiscoveredPublication? {
        var seen = Set<String>()
        let candidates = gatewayAllPublicationRows
            + myPublications
            + subscribedUnfolderedPublications
            + subscribedPublications
            + followingTabPublications
        for publication in candidates where seen.insert(publication.publicationId).inserted {
            if PublicationUnreadCountLookup.publicationIdsMatch(publication.publicationId, publicationId) {
                return publication
            }
        }
        return nil
    }

    private func applyStreamedPublicationSelection(
        publication: DiscoveredPublication,
        entries: [EntryListItem],
        cursor: String?
    ) {
        prepareForPublicationSelection()
        selectedPublication = publication
        selectedSidebar = .publication(publication.publicationId)
        self.entries = entries
        entriesNextCursor = cursor
        persistPublicationEntries(publication.publicationId, entries: entries)
        Task {
            await prefetchThumbnailImages(for: entries)
        }
    }

    private func mergeFolderPublications(from projection: PublicationSidebarResponseDTO) {
        for (publicationId, scope) in projection.scopesByPublicationId() {
            sidebarScopesByPublicationId[publicationId] = scope
        }

        let folderRows = projection.allPublicationRows.map { $0.toDiscoveredPublication() }
        var seen = Set(gatewayAllPublicationRows.map(\.publicationId))
        var mergedRows = gatewayAllPublicationRows
        for row in folderRows where seen.insert(row.publicationId).inserted {
            mergedRows.append(row)
        }
        gatewayAllPublicationRows = mergedRows

        if let grouped = PublicationProjectionMapping.folderMap(from: projection.folderSections) {
            for (folderRkey, publications) in grouped {
                gatewayFolderMap[folderRkey] = publications
            }
            cachedFolderSections = projection.folderSections
            cachedFolderRows = projection.allPublicationRows
        }

        prefetchPublicationAvatarImages(folderRows)
        refreshSidebarUnreadSumCaches()
    }

    private func mergeSidebarSection(_ payload: BootstrapSidebarSectionPayloadDTO) {
        if let generation = payload.sectionGeneration,
           let current = sidebarSectionGenerations[payload.sectionKey],
           generation < current
        {
            return
        }
        if let generation = payload.sectionGeneration {
            sidebarSectionGenerations[payload.sectionKey] = generation
        }

        guard let folderRkey = payload.folderRkey,
              let folderUri = payload.folderUri
        else { return }

        let replacePublicationIds = payload.replacePublicationIds ?? payload.publications.map(\.publicationId)
        let sectionRows = payload.publications.map { row in
            guard let counts = payload.unreadCounts else { return row }
            let count = PublicationUnreadCountLookup.lookup(in: counts, publicationId: row.publicationId)
            return row.withUnreadCount(max(0, count))
        }

        for row in sectionRows {
            sidebarScopesByPublicationId[row.publicationId] = row.appViewScope
        }

        let discoveredRows = sectionRows.map { $0.toDiscoveredPublication() }
        gatewayAllPublicationRows = upsertingDiscoveredPublications(
            into: gatewayAllPublicationRows,
            rows: discoveredRows
        )
        gatewayFolderMap[folderRkey] = discoveredRows

        let section = PublicationFolderSectionDTO(
            folderRkey: folderRkey,
            folderUri: folderUri,
            publications: sectionRows
        )
        cachedFolderSections = replacingFolderSection(
            in: cachedFolderSections ?? [],
            with: section
        )
        cachedFolderRows = upsertingSidebarRows(
            into: cachedFolderRows ?? [],
            rows: sectionRows
        )

        if let counts = payload.unreadCounts {
            applySectionUnreadCounts(counts, publicationIds: replacePublicationIds)
        } else {
            refreshSidebarUnreadSumCaches()
        }

        prefetchPublicationAvatarImages(discoveredRows)
    }

    private func applySectionUnreadCounts(_ counts: [String: Int], publicationIds: [String]) {
        var map = unreadCountsByPublicationId
        for publicationId in publicationIds {
            let count = PublicationUnreadCountLookup.lookup(in: counts, publicationId: publicationId)
            PublicationUnreadCountLookup.store(max(0, count), for: publicationId, in: &map)
        }
        unreadCountsByPublicationId = map
        sidebarUnread.unreadCountsByPublicationId = map
        if let projection = cachedPriorityProjection {
            cachedPriorityProjection = PublicationProjectionMapping.applyingUnreadCounts(
                to: projection,
                counts: counts,
                replacePublicationIds: publicationIds
            )
            sidebarUnread.cachedPriorityProjection = cachedPriorityProjection
        }
        refreshSidebarUnreadSumCaches()
    }

    private func replacingFolderSection(
        in sections: [PublicationFolderSectionDTO],
        with section: PublicationFolderSectionDTO
    ) -> [PublicationFolderSectionDTO] {
        var next = sections
        if let index = next.firstIndex(where: {
            $0.folderRkey == section.folderRkey || $0.folderUri == section.folderUri
        }) {
            next[index] = section
        } else {
            next.append(section)
        }
        return next
    }

    private func upsertingDiscoveredPublications(
        into existing: [DiscoveredPublication],
        rows: [DiscoveredPublication]
    ) -> [DiscoveredPublication] {
        var next = existing
        for row in rows {
            if let index = next.firstIndex(where: {
                PublicationUnreadCountLookup.publicationIdsMatch($0.publicationId, row.publicationId)
            }) {
                next[index] = row
            } else {
                next.append(row)
            }
        }
        return next
    }

    private func upsertingSidebarRows(
        into existing: [SidebarPublicationRowDTO],
        rows: [SidebarPublicationRowDTO]
    ) -> [SidebarPublicationRowDTO] {
        var next = existing
        for row in rows {
            if let index = next.firstIndex(where: {
                PublicationUnreadCountLookup.publicationIdsMatch($0.publicationId, row.publicationId)
            }) {
                next[index] = row
            } else {
                next.append(row)
            }
        }
        return next
    }

    private func applyGatewaySidebarProjection(_ projection: PublicationSidebarResponseDTO) {
        cachedPriorityProjection = projection
        sidebarUnread.cachedPriorityProjection = projection
        sidebarScopesByPublicationId = projection.scopesByPublicationId()
        unreadCountsByPublicationId = PublicationProjectionMapping.unreadCountsMap(from: projection)
        sidebarUnread.unreadCountsByPublicationId = unreadCountsByPublicationId

        gatewayAllPublicationRows = projection.allPublicationRows.map { $0.toDiscoveredPublication() }
        gatewayMyPublications = projection.myPublications.map { $0.toDiscoveredPublication() }
        gatewaySubscribedUnfoldered = projection.subscribedUnfoldered.map { $0.toDiscoveredPublication() }
        gatewayFollowingTab = projection.followingTabPublications.map { $0.toDiscoveredPublication() }

        folders = PublicationProjectionMapping.folders(from: projection.folders)
        publicationPrefs = PublicationProjectionMapping.publicationPrefsMap(
            from: projection.publicationPrefs ?? []
        )

        if let grouped = PublicationProjectionMapping.folderMap(from: projection.folderSections) {
            gatewayFolderMap = grouped
            cachedFolderSections = projection.folderSections
            cachedFolderRows = projection.allPublicationRows
        } else {
            gatewayFolderMap = PublicationProjectionMapping.folderMap(
                allRows: gatewayAllPublicationRows,
                myPublications: gatewayMyPublications,
                followingTab: gatewayFollowingTab,
                publicationPrefs: publicationPrefs
            )
        }

        prefetchPublicationAvatarImages(gatewayAllPublicationRows)
        refreshSidebarUnreadSumCaches()
    }

    private func restoreCachedSidebarSnapshot(viewerDid: String) {
        guard let coordinator = readerCacheCoordinator,
              let body = coordinator.gatewayCachedBody(for: SidebarProjectionSnapshot.cacheKey(viewerDid: viewerDid)),
              let snapshot = try? JSONDecoder().decode(SidebarProjectionSnapshot.self, from: body),
              SidebarProjectionSnapshot.shouldPersist(snapshot.priority)
        else { return }

        applyGatewaySidebarProjection(snapshot.priority)
        if let payload = SidebarProjectionSnapshotBuilder.folderPayload(
            folderSections: snapshot.folderSections,
            allPublicationRows: snapshot.folderAllPublicationRows ?? []
        ) {
            mergeFolderPublications(from: PublicationSidebarResponseDTO(
                viewerDid: viewerDid,
                folders: nil,
                publicationPrefs: nil,
                folderSections: payload.sections,
                allPublicationRows: payload.rows,
                myPublications: [],
                subscribedUnfoldered: [],
                followingTabPublications: [],
                enrollAuthorDids: [],
                refreshedAt: snapshot.priority.refreshedAt,
                unreadCountsByPublicationId: nil
            ))
        }
        hasSidebarSnapshot = true
    }

    private func persistSidebarSnapshot(viewerDid: String) {
        guard let priority = cachedPriorityProjection,
              SidebarProjectionSnapshot.shouldPersist(priority),
              let coordinator = readerCacheCoordinator
        else { return }

        let snapshot = SidebarProjectionSnapshot(
            priority: priority,
            folderSections: cachedFolderSections,
            folderAllPublicationRows: cachedFolderRows
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? coordinator.upsertGatewayResponse(
            cacheKey: SidebarProjectionSnapshot.cacheKey(viewerDid: viewerDid),
            etag: nil,
            body: data
        )
    }

    private func captureSidebarLayoutRollback() -> SidebarLayoutRollback {
        SidebarLayoutRollback(
            folders: folders,
            folderMap: gatewayFolderMap,
            subscribedUnfoldered: gatewaySubscribedUnfoldered,
            publicationPrefs: publicationPrefs
        )
    }

    private func restoreSidebarLayoutRollback(_ rollback: SidebarLayoutRollback) {
        folders = rollback.folders
        gatewayFolderMap = rollback.folderMap
        gatewaySubscribedUnfoldered = rollback.subscribedUnfoldered
        publicationPrefs = rollback.publicationPrefs
    }

    private func gatewaySubscribedPublicationsList() -> [DiscoveredPublication] {
        var merged = gatewayMyPublications + gatewaySubscribedUnfoldered
        var ids = Set(merged.map(\.publicationId))
        for foldered in gatewayFolderMap.values.flatMap({ $0 }) where ids.insert(foldered.publicationId).inserted {
            merged.append(foldered)
        }
        return merged
    }

    private func refreshSidebarUnreadCounts(publicationIds: [String]? = nil, force: Bool = false) async {
        guard useAppViewEntryTimelines else { return }
        if !force, SidebarFetchScheduler.shouldSkipUnreadRefresh(since: bootstrapCompletedAt) {
            return
        }
        let ids = publicationIds ?? gatewayAllPublicationRows.map(\.publicationId)
        guard !ids.isEmpty else { return }
        do {
            let snapshot = try await gateway.fetchAppViewUnreadCounts(publicationIds: ids)
            applyFetchedUnreadCounts(
                snapshot.counts ?? [:],
                publicationIds: ids,
                generation: snapshot.generation,
                accuracy: snapshot.accuracy,
                countedAt: snapshot.countedAt
            )
        } catch {
            markAppViewUnavailableIfNeeded(error)
        }
    }

    private func refreshGatewayPreferencesSnapshot(forceRefetch: Bool = false) async {
        guard let coordinator = readerCacheCoordinator else { return }
        if forceRefetch {
            try? coordinator.removeGatewayCachedResponse(for: Self.preferencesSyncCacheKey)
        }
        do {
            let storedETag = forceRefetch ? nil : coordinator.gatewayETag(for: Self.preferencesSyncCacheKey)
            let response = try await gateway.fetchSyncPreferences(ifNoneMatch: storedETag)

            if response.statusCode == 304, let body = coordinator.gatewayCachedBody(for: Self.preferencesSyncCacheKey) {
                applyPreferencesGatewayBody(body)
                return
            }

            guard (200 ..< 300).contains(response.statusCode) else { return }

            try coordinator.upsertGatewayResponse(
                cacheKey: Self.preferencesSyncCacheKey,
                etag: response.etagHeader,
                body: response.body
            )
            applyPreferencesGatewayBody(response.body)
        } catch {
            // Non-fatal when the gateway preferences snapshot is unavailable.
        }
    }

    private func applyPreferencesGatewayBody(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(SyncPreferencesEnvelope.self, from: data) else {
            preferencesFromGateway = nil
            return
        }
        preferencesFromGateway = envelope.record
        feedPreferences = ReaderFeedPreferences(record: envelope.record)
        if let viewerDID {
            ReaderFeedPreferencesStorage.save(feedPreferences, viewerDid: viewerDID)
        }
        if isSembleReadLaterEnabled {
            Task { await refreshSembleCollection() }
        }
    }

    private func prefetchSidebarPublicationsLimited() async {
        let selectedId = selectedPublication?.publicationId
            ?? UserDefaults.standard.string(forKey: Self.lastSelectedPublicationKey)

        var targets: [DiscoveredPublication] = []
        if let selectedId, let selected = publicationMatchingId(selectedId) {
            targets.append(selected)
        }
        if targets.count < 2,
           let next = gatewayAllPublicationRows.first(where: { $0.publicationId != selectedId })
        {
            targets.append(next)
        }
        guard !targets.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for publication in targets {
                group.addTask {
                    try? await self.cacheOnlyLoadEntries(publication: publication)
                }
            }
        }
    }

    private func prefetchSidebarPublications() async {
        let publications = gatewayAllPublicationRows
        guard !publications.isEmpty else { return }

        let selectedId = selectedPublication?.publicationId
            ?? UserDefaults.standard.string(forKey: Self.lastSelectedPublicationKey)
        var ordered = publications
        if let selectedId,
           let index = ordered.firstIndex(where: { $0.publicationId == selectedId })
        {
            let selected = ordered.remove(at: index)
            ordered.insert(selected, at: 0)
        }

        await withTaskGroup(of: Void.self) { group in
            var iterator = ordered.makeIterator()
            for _ in 0 ..< min(2, ordered.count) {
                guard let publication = iterator.next() else { break }
                group.addTask {
                    try? await self.cacheOnlyLoadEntries(publication: publication)
                }
            }
            for await _ in group {
                guard let publication = iterator.next() else { continue }
                group.addTask {
                    try? await self.cacheOnlyLoadEntries(publication: publication)
                }
            }
        }
    }

    private static let entryPrefetchMaxEntries = 50
    private static let feedPostBootstrapRefreshDelay: Duration = .seconds(1)
    private static let feedProactiveRefreshInterval: Duration = .seconds(45)
    private var proactiveFeedRefreshTask: Task<Void, Never>?

    private func refreshPublicationIndex(for publication: DiscoveredPublication) async {
        guard useAppViewEntryTimelines else { return }
        guard let scope = sidebarScopesByPublicationId[publication.publicationId] else { return }
        let feedUrls = scope.publicationSiteUrls.filter { !$0.isEmpty }
        if !feedUrls.isEmpty {
            do {
                _ = try await gateway.enrollAuthors(dids: [], feedUrls: feedUrls)
            } catch {
                /* Skyreader subscriptions are PDS records; refresh parsed feed entries */
            }
            return
        }
        let authorDid = scope.authorDid
        guard authorDid.hasPrefix("did:"), !authorDid.hasPrefix("did:web:") else { return }
        do {
            _ = try await gateway.enrollAuthors(dids: [authorDid])
        } catch {
            /* best-effort backfill for posts missing from Jetstream index */
        }
    }

    private func cacheOnlyLoadEntries(publication: DiscoveredPublication) async throws {
        guard let coordinator = readerCacheCoordinator else { return }
        let page = try await fetchEntriesPage(
            for: publication,
            cursor: nil,
            filter: .all,
            maxEntries: Self.entryPrefetchMaxEntries
        )
        try coordinator.upsertPublicationEntries(publicationId: publication.publicationId, entries: page.entries)
        sidebarUnread.bumpCacheRevision()
        refreshSidebarUnreadSumCaches()
        await prefetchThumbnailImages(for: Array(page.entries.prefix(12)))
    }

    private func prefetchPublicationAvatarImages(_ publications: [DiscoveredPublication]) {
        let urls = publications.compactMap(\.displayImageURL)
        guard !urls.isEmpty else { return }
        Task(priority: .utility) {
            await ImageCacheService.shared.prefetch(urls: urls, maxPixelSize: 96, concurrency: 8)
        }
    }

    private func prefetchThumbnailImages(for entries: [EntryListItem]) async {
        let urls = entries.flatMap {
            ThumbnailImageURLAttempts.candidates(
                primary: $0.thumbnailUrl,
                fallback: $0.thumbnailFallbackUrl
            )
        }
        guard !urls.isEmpty else { return }
        await ImageCacheService.shared.prefetch(urls: urls, maxPixelSize: 168, concurrency: 8)
    }

    private func markAppViewUnavailableIfNeeded(_ error: Error) {
        if case SocialWireError.appViewUnavailable = error {
            appViewRoutesAvailable = false
        }
    }

    private func fetchEntriesPage(
        for publication: DiscoveredPublication,
        cursor: String?,
        filter: ReaderFilter? = nil,
        maxEntries: Int? = nil
    ) async throws -> AppViewEntryListResponse {
        guard useAppViewEntryTimelines else {
            throw SocialWireError.appViewUnavailable
        }
        guard let scope = sidebarScopesByPublicationId[publication.publicationId] else {
            throw SocialWireError.badResponse("Missing AppView scope for publication.")
        }
        let page = try await gateway.fetchAppViewEntries(
            scope: scope,
            filter: filter ?? readerFilter,
            cursor: cursor,
            maxEntries: maxEntries
        )
        applyAuthoritativeReadState(from: page.entries)
        return page
    }

    private func applyAuthoritativeReadState(from pageEntries: [EntryListItem]) {
        let confirmedAt = Date.distantPast
        for entry in pageEntries where entry.isRead && readAtByEntryId[entry.entryId] == nil {
            readAtByEntryId[entry.entryId] = confirmedAt
        }
    }

    private func mergeEntryPages(existing: [EntryListItem], newPage: [EntryListItem]) -> [EntryListItem] {
        guard !newPage.isEmpty else { return existing }
        var seen = Set(existing.map(\.entryId))
        var merged = existing
        merged.reserveCapacity(existing.count + newPage.count)
        for item in newPage where seen.insert(item.entryId).inserted {
            merged.append(item)
        }
        return merged
    }

    /// Prepends fresh first-page posts while keeping paginated tail rows (feed-style refresh).
    private func mergeEntryPagesAtTop(
        existing: [EntryListItem],
        freshFirstPage: [EntryListItem]
    ) -> [EntryListItem] {
        guard !freshFirstPage.isEmpty else { return existing }
        var seen = Set(freshFirstPage.map(\.entryId))
        var merged = freshFirstPage
        merged.reserveCapacity(existing.count + freshFirstPage.count)
        for item in existing where seen.insert(item.entryId).inserted {
            merged.append(item)
        }
        return merged
    }

    func startProactiveFeedRefreshLoop() {
        proactiveFeedRefreshTask?.cancel()
        proactiveFeedRefreshTask = Task(priority: .utility) { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.feedProactiveRefreshInterval)
                await self.refreshActivePublicationFeedIfNeeded(skipEnroll: true)
            }
        }
    }

    func stopProactiveFeedRefreshLoop() {
        proactiveFeedRefreshTask?.cancel()
        proactiveFeedRefreshTask = nil
    }

    private func scheduleBootstrapFeedRefresh() {
        Task(priority: .utility) {
            try? await Task.sleep(for: Self.feedPostBootstrapRefreshDelay)
            await self.refreshActivePublicationFeedIfNeeded(skipEnroll: false)
        }
    }

    func refreshActivePublicationFeedIfNeeded(skipEnroll: Bool = true) async {
        guard let publication = selectedPublication else { return }
        guard !isLoadingEntries, !isLoadingMoreEntries else { return }
        await refreshPublicationEntriesInBackground(for: publication, skipEnroll: skipEnroll)
    }

    private func persistPublicationEntries(_ publicationId: String, entries: [EntryListItem]) {
        try? readerCacheCoordinator?.upsertPublicationEntries(
            publicationId: publicationId,
            entries: entries
        )
        sidebarUnread.bumpCacheRevision()
        refreshSidebarUnreadSumCaches()
    }

    private func persistAggregateEntriesByPublication(_ entries: [EntryListItem]) {
        guard let readerCacheCoordinator else { return }
        let grouped = Dictionary(grouping: entries) { $0.publicationId }
        var wroteEntries = false
        for (publicationId, publicationEntries) in grouped {
            guard let publicationId, !publicationId.isEmpty else { continue }
            if (try? readerCacheCoordinator.upsertPublicationEntries(
                publicationId: publicationId,
                entries: publicationEntries
            )) != nil {
                wroteEntries = true
            }
        }
        guard wroteEntries else { return }
        sidebarUnread.bumpCacheRevision()
        refreshSidebarUnreadSumCaches()
    }

    func publications(in folder: RepoRecord<FolderRecord>) -> [DiscoveredPublication] {
        gatewayFolderMap[rkey(from: folder.uri)] ?? []
    }

    /// Synchronously invalidate in-flight entry loads before switching publications.
    func prepareForPublicationSelection() {
        entrySelectionGeneration += 1
        unreadDeferredEntryId = nil
        selectedEntry = nil
        selectedSavedLink = nil
        entriesNextCursor = nil
    }

    func selectPublication(_ publication: DiscoveredPublication) async {
        UserDefaults.standard.set(
            publication.publicationId,
            forKey: Self.lastSelectedPublicationKey
        )
        prepareForPublicationSelection()
        selectedPublication = publication
        selectedSidebar = .publication(publication.publicationId)
        feedSelection = .publication(publication.publicationId)
        if let viewerDID {
            FeedSelectionStorage.save(feedSelection, viewerDid: viewerDID)
        }
        await loadEntries(for: publication)
    }

    func refreshPublication(_ publication: DiscoveredPublication) async {
        if selectedPublication?.publicationId == publication.publicationId {
            await loadEntries(for: publication, forceNetworkRefresh: true)
        } else {
            await refreshPublicationIndex(for: publication)
        }
    }

    func loadEntries(for publication: DiscoveredPublication, forceNetworkRefresh: Bool = false) async {
        entriesNextCursor = nil
        entriesPaginationTriggeredForEntryId = nil
        var hadCachedEntries = false
        if let coordinator = readerCacheCoordinator,
           let snapshot = try? coordinator.publicationEntries(publication.publicationId) {
            entries = snapshot
            hadCachedEntries = !snapshot.isEmpty
            await prefetchThumbnailImages(for: snapshot)
        }

        if !hadCachedEntries {
            isLoadingEntries = true
        }
        defer { isLoadingEntries = false }

        if hadCachedEntries && !forceNetworkRefresh && readerFilter == .all {
            Task(priority: .utility) {
                await self.refreshPublicationEntriesInBackground(for: publication)
            }
            return
        }

        do {
            await refreshPublicationIndex(for: publication)
            let page = try await fetchEntriesPage(for: publication, cursor: nil)
            entries = page.entries
            entriesNextCursor = page.cursor
            if readerFilter == .all {
                persistPublicationEntries(publication.publicationId, entries: entries)
            }
            await prefetchThumbnailImages(for: page.entries)
        } catch {
            markAppViewUnavailableIfNeeded(error)
            if entries.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshPublicationEntriesInBackground(
        for publication: DiscoveredPublication,
        skipEnroll: Bool = true
    ) async {
        guard selectedPublication?.publicationId == publication.publicationId else { return }
        do {
            if !skipEnroll {
                await refreshPublicationIndex(for: publication)
            }
            let page = try await fetchEntriesPage(for: publication, cursor: nil)
            if readerFilter == .unread {
                entries = page.entries
                entriesNextCursor = page.cursor
            } else {
                entries = mergeEntryPagesAtTop(existing: entries, freshFirstPage: page.entries)
                if entriesNextCursor == nil {
                    entriesNextCursor = page.cursor
                }
                persistPublicationEntries(publication.publicationId, entries: entries)
            }
            await prefetchThumbnailImages(for: page.entries)
        } catch {
            markAppViewUnavailableIfNeeded(error)
        }
    }

    private func restoreLastSelectedPublicationEntriesIfCached() {
        guard selectedPublication == nil,
              let publicationId = UserDefaults.standard.string(forKey: Self.lastSelectedPublicationKey),
              !publicationId.isEmpty,
              let coordinator = readerCacheCoordinator,
              let snapshot = try? coordinator.publicationEntries(publicationId),
              !snapshot.isEmpty
        else { return }

        entries = snapshot
        if let publication = publicationMatchingId(publicationId) {
            selectedPublication = publication
            selectedSidebar = .publication(publicationId)
        }
    }

    func loadMoreEntriesIfNeeded(for publication: DiscoveredPublication, triggeredByEntryId entryId: String? = nil) async {
        if let entryId {
            guard entriesPaginationTriggeredForEntryId != entryId else { return }
            entriesPaginationTriggeredForEntryId = entryId
        }
        guard canLoadMoreEntries else { return }
        guard !isLoadingEntries, !isLoadingMoreEntries else { return }
        guard selectedPublication?.publicationId == publication.publicationId else { return }

        isLoadingMoreEntries = true
        defer { isLoadingMoreEntries = false }

        let cursor = entriesNextCursor
        do {
            let page = try await fetchEntriesPage(for: publication, cursor: cursor)
            entries = mergeEntryPages(existing: entries, newPage: page.entries)
            entriesNextCursor = page.cursor
            if readerFilter == .all {
                persistPublicationEntries(publication.publicationId, entries: entries)
            }
            await prefetchThumbnailImages(for: page.entries)
        } catch {
            if entryId != nil {
                entriesPaginationTriggeredForEntryId = nil
            }
            markAppViewUnavailableIfNeeded(error)
        }
    }

    func applyReaderFilter(_ newValue: ReaderFilter) async {
        guard readerListSource.supportsReadState else { return }
        let old = readerFilter
        guard old != newValue else { return }
        readerFilter = newValue

        if old == .unread, newValue == .all {
            if let id = unreadDeferredEntryId {
                await markReadIfNeeded(entryId: id)
            } else if let open = selectedEntry?.entryId {
                await markReadIfNeeded(entryId: open)
            }
            unreadDeferredEntryId = nil
        }

        entriesNextCursor = nil
        entriesPaginationTriggeredForEntryId = nil
        await refreshSelectedArticleFeed()
    }

    func dismissReaderDetail() async {
        if readerListSource.supportsReadState, readerFilter == .unread {
            if let id = unreadDeferredEntryId {
                await markReadIfNeeded(entryId: id)
            } else if let open = selectedEntry?.entryId {
                await markReadIfNeeded(entryId: open)
            }
        }
        unreadDeferredEntryId = nil
        selectedEntry = nil
    }

    func dismissSavedLinkDetail() {
        selectedSavedLink = nil
    }

    func selectEntry(_ item: EntryListItem) async {
        entrySelectionGeneration += 1
        let generation = entrySelectionGeneration

        if readerListSource == .wire {
            unreadDeferredEntryId = nil
            guard let viewerDID else { return }
            do {
                if let coordinator = readerCacheCoordinator,
                   let cached = try coordinator.wireItemDetail(
                       itemId: item.entryId,
                       viewerDID: viewerDID
                   ) {
                    guard generation == entrySelectionGeneration else { return }
                    guard entries.contains(where: { $0.entryId == item.entryId }) else { return }
                    selectedEntry = cached
                } else if selectedEntry?.entryId != item.entryId {
                    selectedEntry = nil
                }

                let wireItem = try await gateway.fetchWireItem(itemId: item.entryId)
                guard generation == entrySelectionGeneration else { return }
                guard entries.contains(where: { $0.entryId == item.entryId }) else { return }
                let detail = wireItem.toEntryDetail()
                selectedEntry = detail
                selectedSavedLink = nil
                try? readerCacheCoordinator?.upsertWireItemDetail(
                    detail,
                    viewerDID: viewerDID
                )
            } catch {
                guard generation == entrySelectionGeneration else { return }
                // Retain cached detail when available; Wire navigation must never create read marks.
            }
            return
        }

        if readerFilter == .unread {
            if let previous = unreadDeferredEntryId, previous != item.entryId {
                await markReadIfNeeded(entryId: previous)
            }
            unreadDeferredEntryId = item.entryId
        } else {
            unreadDeferredEntryId = nil
        }

        do {
            if let coordinator = readerCacheCoordinator,
               let cached = try coordinator.entryDetail(item.entryId) {
                guard generation == entrySelectionGeneration else { return }
                guard entries.contains(where: { $0.entryId == item.entryId }) else { return }
                selectedEntry = cached
            } else if selectedEntry?.entryId != item.entryId {
                guard generation == entrySelectionGeneration else { return }
                selectedEntry = nil
            }

            let detail: EntryDetail?
            if useAppViewEntryTimelines {
                detail = try await gateway.fetchAppViewEntryDetail(entryId: item.entryId)
            } else {
                detail = nil
            }

            guard generation == entrySelectionGeneration else { return }
            guard entries.contains(where: { $0.entryId == item.entryId }) else { return }

            guard let detail else {
                throw SocialWireError.badResponse("Entry detail unavailable.")
            }

            selectedEntry = detail
            selectedSavedLink = nil
            try? readerCacheCoordinator?.upsertEntryDetail(detail)

            if readerFilter == .all {
                await markReadIfNeeded(entryId: item.entryId)
            }
        } catch {
            guard generation == entrySelectionGeneration else { return }
            markAppViewUnavailableIfNeeded(error)
            // Opening an article is part of routine navigation; if the detail fetch fails we keep
            // any cached selection and let the reader show its placeholder rather than popping a modal.
        }
    }

    func recordExternalEntryOpen(_ item: EntryListItem) async {
        guard readerListSource.supportsReadState else { return }
        await markReadIfNeeded(entryId: item.entryId)
    }

    private func markReadIfNeeded(entryId: String) async {
        guard readAtByEntryId[entryId] == nil else { return }
        guard useAppViewEntryTimelines else { return }

        do {
            let readAt = Date()
            try await gateway.upsertReadMark(subjectUri: entryId, readAt: readAt)
            var readMap = readAtByEntryId
            readMap[entryId] = readAt
            readAtByEntryId = readMap
            sidebarUnread.bumpReadRevision()
            if let publicationId = publicationId(for: entryId) {
                adjustUnreadCount(publicationId: publicationId, entryId: entryId, delta: -1)
            } else {
                rebuildSidebarTreeViewModel()
            }
        } catch {
            markAppViewUnavailableIfNeeded(error)
            // Auto mark-as-read fires while scrolling/opening articles; a failure here must not
            // interrupt the user with a modal alert.
        }
    }

    func toggleRead(_ item: EntryListItem) async {
        guard useAppViewEntryTimelines else { return }
        let markingRead = readAtByEntryId[item.entryId] == nil

        do {
            if markingRead {
                let readAt = Date()
                try await gateway.upsertReadMark(subjectUri: item.entryId, readAt: readAt)
                var readMap = readAtByEntryId
                readMap[item.entryId] = readAt
                readAtByEntryId = readMap
                sidebarUnread.bumpReadRevision()
                if let publicationId = publicationId(for: item.entryId) {
                    adjustUnreadCount(
                        publicationId: publicationId,
                        entryId: item.entryId,
                        delta: -1
                    )
                } else {
                    rebuildSidebarTreeViewModel()
                }
            } else {
                try await gateway.deleteReadMark(subjectUri: item.entryId)
                var readMap = readAtByEntryId
                readMap.removeValue(forKey: item.entryId)
                readAtByEntryId = readMap
                sidebarUnread.bumpReadRevision()
                if let publicationId = publicationId(for: item.entryId) {
                    adjustUnreadCount(
                        publicationId: publicationId,
                        entryId: item.entryId,
                        delta: 1
                    )
                } else {
                    rebuildSidebarTreeViewModel()
                }
            }
        } catch {
            markAppViewUnavailableIfNeeded(error)
            // Read-state toggles shouldn't pop a modal; the optimistic UI simply stays unchanged
            // on failure (no mutation happens before the awaited call succeeds).
        }
    }

    /// Refresh AppView unread baselines after another client may have changed them.
    func syncCrossClientReadState() async {
        guard isSignedIn else { return }
        await refreshSidebarUnreadCounts()
        await refreshActivePublicationFeedIfNeeded(skipEnroll: true)
    }

    func purgeIndexedAppViewData() async {
        guard useAppViewEntryTimelines else { return }
        do {
            try await gateway.purgeAppViewPrivacyData()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createFolder(name: String) async {
        guard let viewerDID else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let optimisticRkey = OptimisticSidebarMutation.createOptimisticFolderRkey()
        let rollback = captureSidebarLayoutRollback()
        OptimisticSidebarMutation.addOptimisticFolder(
            folders: &folders,
            folderMap: &gatewayFolderMap,
            viewerDid: viewerDID,
            rkey: optimisticRkey,
            name: trimmed
        )
        refreshSidebarUnreadSumCaches()

        do {
            let created = try await pds.createFolder(name: trimmed)
            OptimisticSidebarMutation.replaceOptimisticFolder(
                folders: &folders,
                folderMap: &gatewayFolderMap,
                publicationPrefs: &publicationPrefs,
                optimisticRkey: optimisticRkey,
                created: created,
                name: trimmed
            )
            migrateSidebarFolderExpandKey(
                oldRkey: optimisticRkey,
                newRkey: created.rkey
            )
            persistSidebarSnapshot(viewerDid: viewerDID)
        } catch {
            restoreSidebarLayoutRollback(rollback)
            refreshSidebarUnreadSumCaches()
            errorMessage = error.localizedDescription
        }
    }

    func deleteFolder(_ folder: RepoRecord<FolderRecord>) async {
        let folderRkey = rkey(from: folder.uri)
        let rollback = captureSidebarLayoutRollback()
        OptimisticSidebarMutation.removeFolder(
            folders: &folders,
            folderMap: &gatewayFolderMap,
            subscribedUnfoldered: &gatewaySubscribedUnfoldered,
            publicationPrefs: &publicationPrefs,
            folderRkey: folderRkey
        )
        refreshSidebarUnreadSumCaches()

        do {
            try await pds.deleteFolder(rkey: folderRkey)
            if let viewerDID {
                persistSidebarSnapshot(viewerDid: viewerDID)
            }
        } catch {
            restoreSidebarLayoutRollback(rollback)
            refreshSidebarUnreadSumCaches()
            errorMessage = error.localizedDescription
        }
    }

    func updateFolder(_ folder: RepoRecord<FolderRecord>, name: String, icon: String?) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let trimmedIcon = icon?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await pds.updateFolder(
                rkey: rkey(from: folder.uri),
                existing: folder.value,
                name: trimmedName,
                icon: trimmedIcon?.isEmpty == false ? trimmedIcon : nil
            )
            await refreshSidebarProjection()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func assign(_ publication: DiscoveredPublication, to folder: RepoRecord<FolderRecord>?) async {
        let rollback = captureSidebarLayoutRollback()
        let toFolderRkey = folder.map { rkey(from: $0.uri) }
        OptimisticSidebarMutation.movePublication(
            publication: publication,
            toFolderRkey: toFolderRkey,
            subscribedUnfoldered: &gatewaySubscribedUnfoldered,
            folderMap: &gatewayFolderMap,
            publicationPrefs: &publicationPrefs,
            myPublicationIds: Set(gatewayMyPublications.map(\.publicationId)),
            followingPublicationIds: Set(gatewayFollowingTab.map(\.publicationId))
        )
        refreshSidebarUnreadSumCaches()

        do {
            let existing = publicationPrefs[publication.publicationId]
            try await pds.upsertPublicationPrefs(
                publicationId: publication.publicationId,
                folderId: toFolderRkey,
                existing: existing
            )
            if let viewerDID {
                persistSidebarSnapshot(viewerDid: viewerDID)
            }
        } catch {
            restoreSidebarLayoutRollback(rollback)
            refreshSidebarUnreadSumCaches()
            errorMessage = error.localizedDescription
        }
    }

    func addPublication(input: String, title: String?) async {
        do {
            let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if let resolved = try? await gateway.resolveAddPublication(input: normalized),
               let result = resolved.result
            {
                try await addResolvedPublication(result, title: title)
            } else if normalized.contains(".") || normalized.hasPrefix("http") {
                try await pds.createSkyreaderSubscription(
                    feedURL: rss.normalizeFeedURL(normalized),
                    title: title
                )
            } else {
                let did = try await resolver.resolveDID(handleOrDID: normalized)
                try await pds.createPublicationSubscription(publication: did)
            }
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resolvePublication(input: String) async throws -> ResolveAddPublicationResultDTO {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw SocialWireError.invalidURL }
        let response = try await gateway.resolveAddPublication(input: normalized)
        if let result = response.result { return result }
        throw SocialWireError.badResponse(response.error ?? "Publication could not be resolved.")
    }

    func addResolvedPublication(
        _ result: ResolveAddPublicationResultDTO,
        title: String? = nil
    ) async throws {
        switch result.kind {
        case "standard-site":
            guard let publicationAtUri = result.publicationAtUri else {
                throw SocialWireError.badResponse("The publication record is missing.")
            }
            try await pds.createPublicationSubscription(publication: publicationAtUri)
        case "rss":
            guard let feedUrl = result.feedUrl else {
                throw SocialWireError.badResponse("The feed URL is missing.")
            }
            try await pds.createSkyreaderSubscription(
                feedURL: rss.normalizeFeedURL(feedUrl),
                title: title ?? result.title,
                siteURL: result.siteUrl
            )
        default:
            throw SocialWireError.badResponse("This publication type is not supported.")
        }
        await refreshAll()
    }

    func isSubscribed(to result: ResolveAddPublicationResultDTO) -> Bool {
        if let publicationAtUri = result.publicationAtUri {
            return subscribedPublications.contains {
                normalizeATRepoParam($0.publicationId) == normalizeATRepoParam(publicationAtUri)
                    || normalizeATRepoParam($0.subscriptionPublicationId ?? "")
                        == normalizeATRepoParam(publicationAtUri)
            }
        }
        if let feedUrl = result.feedUrl {
            let publicationId = rss.publicationID(normalizedFeedURL: rss.normalizeFeedURL(feedUrl))
            return subscribedPublications.contains { $0.publicationId == publicationId }
        }
        return false
    }

    func subscribe(to publication: DiscoveredPublication) async {
        do {
            if let feedURL = rss.normalizedFeedURL(from: publication.publicationId) {
                try await pds.createSkyreaderSubscription(
                    feedURL: feedURL,
                    title: publication.title,
                    siteURL: publication.publicationSiteUrls.first
                )
            } else {
                try await pds.createPublicationSubscription(
                    publication: publication.subscriptionPublicationId ?? publication.publicationId
                )
            }
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func unsubscribe(from publication: DiscoveredPublication) async {
        do {
            if let feedURL = rss.normalizedFeedURL(from: publication.publicationId) {
                let normalized = rss.normalizeFeedURL(feedURL)
                let subscriptions = try await pds.listSkyreaderSubscriptions()
                guard let record = subscriptions.first(where: {
                    $0.value.feedUrl.map(rss.normalizeFeedURL) == normalized
                }) else { return }
                try await pds.deleteSkyreaderSubscription(rkey: rkey(from: record.uri))
            } else {
                let targetKeys = Set(publicationSubscriptionMatchKeys(for: publication))
                let subscriptions = try await pds.listPublicationSubscriptions()
                guard let record = subscriptions.first(where: { subscription in
                    var keys = Set<String>()
                    addPublicationSubscriptionLookupKeys(
                        into: &keys,
                        value: subscription.value.publication
                    )
                    return !targetKeys.isDisjoint(with: keys)
                }) else { return }
                try await pds.deletePublicationSubscription(rkey: rkey(from: record.uri))
            }
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func existingSkyreaderFeedURLs() async -> Set<String> {
        guard let records = try? await pds.listSkyreaderSubscriptions() else { return [] }
        return Set(records.compactMap { record in
            record.value.feedUrl.flatMap(OPMLParser.normalizeFeedURL)
        })
    }

    func importOPMLFeeds(
        _ feeds: [OPMLFeed],
        progress: @escaping @MainActor (_ completed: Int, _ total: Int) -> Void
    ) async -> [OPMLImportFailure] {
        var failures: [OPMLImportFailure] = []
        for (index, feed) in feeds.enumerated() {
            do {
                try await pds.createSkyreaderSubscription(
                    feedURL: feed.feedURL,
                    title: feed.title,
                    siteURL: feed.siteURL
                )
            } catch {
                failures.append(OPMLImportFailure(feed: feed, message: error.localizedDescription))
            }
            progress(index + 1, feeds.count)
        }
        await refreshAll()
        return failures
    }

    var currentSavedLinks: [MergedLatrSave] {
        readerListSource == .archive ? archivedSavedLinks : savedLinks
    }

    var filteredCurrentSavedLinks: [MergedLatrSave] {
        return currentSavedLinks.filter { save in
            let matchesSource = selectedSavedSourceKey.map { sourceKey in
                savedFeedSourceKey(for: save) == sourceKey
            } ?? true
            let matchesTag = selectedSavedTag.map { selectedTag in
                save.tags.contains(selectedTag)
            } ?? true
            return matchesSource && matchesTag
        }
    }

    var currentSavedTagCounts: [SavedTagCount] {
        SavedTagCatalog.counts(in: currentSavedLinks)
    }

    var currentSavedFeedSources: [SavedFeedSource] {
        var models: [String: SavedLinkPublicationChipModel] = [:]
        var counts: [String: Int] = [:]
        for save in currentSavedLinks {
            guard let key = savedFeedSourceKey(for: save),
                  let model = resolvedSavedLinkPublicationChip(for: save)
            else { continue }
            models[key] = model
            counts[key, default: 0] += 1
        }
        return models.map { key, model in
            SavedFeedSource(id: key, model: model, count: counts[key] ?? 0)
        }
        .sorted { $0.model.name.localizedCaseInsensitiveCompare($1.model.name) == .orderedAscending }
    }

    func selectSavedFeedSource(_ source: SavedFeedSource) {
        selectedSavedSourceKey = source.id
        selectedSavedLink = nil
        feedSelection = .savedSource(readerListSource, source.id)
        if let viewerDID {
            FeedSelectionStorage.save(feedSelection, viewerDid: viewerDID)
        }
    }

    func clearSavedFeedSource() {
        selectedSavedSourceKey = nil
        selectedSavedLink = nil
        feedSelection = .topLevel(readerListSource)
        if let viewerDID {
            FeedSelectionStorage.save(feedSelection, viewerDid: viewerDID)
        }
    }

    func selectSavedTag(_ tag: String?) {
        selectedSavedTag = tag
        selectedSavedLink = nil
        if let viewerDID {
            SavedTagSelectionStorage.save(tag, viewerDid: viewerDID)
            savedTagSelectionViewerDid = viewerDID
        }
    }

    private func restorePersistedFeedSelectionIfPossible() async {
        guard let selection = pendingRestoredFeedSelection else { return }
        switch selection {
        case .topLevel(let source):
            guard visibleReaderListSources.contains(source) else {
                pendingRestoredFeedSelection = nil
                return
            }
            pendingRestoredFeedSelection = nil
            applyReaderListSource(source, persist: true)
        case .folder(let folderRkey):
            guard folders.contains(where: { rkey(from: $0.uri) == folderRkey }) else {
                pendingRestoredFeedSelection = nil
                return
            }
            pendingRestoredFeedSelection = nil
            await selectFolderFeed(folderRkey: folderRkey)
        case .publication(let publicationId):
            guard let publication = publication(forId: publicationId) else {
                pendingRestoredFeedSelection = nil
                return
            }
            pendingRestoredFeedSelection = nil
            await selectPublication(publication)
        case .savedSource(let source, let sourceId):
            guard source == .readLater || source == .archive,
                  feedPreferences.visibleFeeds.contains(source)
            else {
                pendingRestoredFeedSelection = nil
                return
            }
            applyReaderListSource(source, persist: true)
            await refreshSavedLinks()
            guard let savedSource = currentSavedFeedSources.first(where: { $0.id == sourceId }) else {
                pendingRestoredFeedSelection = nil
                return
            }
            pendingRestoredFeedSelection = nil
            selectSavedFeedSource(savedSource)
        }
    }

    private func savedFeedSourceKey(for save: MergedLatrSave) -> String? {
        guard let chip = resolvedSavedLinkPublicationChip(for: save) else { return nil }
        if let host = chip.homepageURL?.host?.lowercased() {
            return "site:\(host.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression))"
        }
        let normalized = chip.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : "site:\(normalized)"
    }

    func refreshSavedLinks() async {
        if isSembleReadLaterEnabled {
            await refreshSembleCollection()
            return
        }
        do {
            restoreSavedTagSelectionIfNeeded()
            if !attemptedBookmarkMigration, let viewerDID {
                attemptedBookmarkMigration = true
                do {
                    let conflicts = try await latrGateway.migrateLegacyIfNeeded(viewerDID: viewerDID)
                    if conflicts > 0 {
                        errorMessage = "\(conflicts) legacy bookmark conflict\(conflicts == 1 ? " was" : "s were") left unchanged and will be retried later."
                    }
                } catch {
                    attemptedBookmarkMigration = false
                    errorMessage = error.localizedDescription
                    return
                }
            }
            let bookmarks = try await latrGateway.listBookmarks()
            savedLinks = bookmarks.filter { ($0.state ?? "unread") != "archived" }
            archivedSavedLinks = bookmarks.filter { ($0.state ?? "unread") == "archived" }
        } catch {
            // Passive refresh (runs on pane appear and after mutations). Keep whatever links are
            // already shown and don't interrupt navigation with a modal alert.
        }
    }

    private func restoreSavedTagSelectionIfNeeded() {
        guard let viewerDID, savedTagSelectionViewerDid != viewerDID else { return }
        selectedSavedTag = SavedTagSelectionStorage.load(viewerDid: viewerDID)
        savedTagSelectionViewerDid = viewerDID
    }

    private func applyOptimisticLatrArchive(_ save: MergedLatrSave) {
        savedLinks.removeAll { $0.id == save.id }
        if !archivedSavedLinks.contains(where: { $0.id == save.id }) {
            var archived = save
            archived = archived.withState("archived")
            archivedSavedLinks.insert(archived, at: 0)
        }
    }

    private func applyOptimisticLatrUnarchive(_ save: MergedLatrSave) {
        archivedSavedLinks.removeAll { $0.id == save.id }
        if !savedLinks.contains(where: { $0.id == save.id }) {
            var active = save
            active = active.withState("unread")
            savedLinks.insert(active, at: 0)
        }
    }

    private func applyOptimisticLatrDelete(_ save: MergedLatrSave) {
        savedLinks.removeAll { $0.id == save.id }
        archivedSavedLinks.removeAll { $0.id == save.id }
    }

    private func replaceSavedLink(_ replacement: MergedLatrSave) {
        if let index = savedLinks.firstIndex(where: { $0.itemRkey == replacement.itemRkey }) {
            savedLinks[index] = replacement
        }
        if let index = archivedSavedLinks.firstIndex(where: { $0.itemRkey == replacement.itemRkey }) {
            archivedSavedLinks[index] = replacement
        }
        if selectedSavedLink?.itemRkey == replacement.itemRkey {
            selectedSavedLink = replacement
        }
    }

    func saveCurrentEntry() async {
        guard let selectedEntry else { return }
        await saveEntry(
            entryId: selectedEntry.entryId,
            url: selectedEntry.canonicalURL,
            title: selectedEntry.title
        )
    }

    func saveEntry(
        entryId: String,
        url: URL?,
        title: String?,
        excerpt: String? = nil,
        linkedWebURL: String? = nil,
        tags: [String]? = nil,
        note: String? = nil
    ) async {
        if isSembleReadLaterEnabled {
            await saveEntryToSemble(
                entryId: entryId,
                url: url,
                title: title,
                linkedWebURL: linkedWebURL,
                note: note
            )
            return
        }
        do {
            let subject = url?.absoluteString
                ?? linkedWebURL?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? entryId
            try await latrGateway.save(subject: subject, tags: tags)
            await refreshSavedLinks()
        } catch {
            errorMessage = "Couldn't save this article to Read Later. \(error.localizedDescription)"
        }
    }

    func loadOwnedSembleCollections() async {
        guard let viewerDID else { return }
        isLoadingSemble = true
        defer { isLoadingSemble = false }
        do {
            var rows: [SembleCollectionSummary] = []
            var cursor: String?
            repeat {
                let page = try await gateway.fetchSembleCollections(cursor: cursor)
                rows.append(contentsOf: page.collections)
                cursor = page.cursor
            } while cursor != nil
            sembleCollections = rows
                .filter { $0.ownerDID == viewerDID }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            errorMessage = "Couldn't load your Semble collections. \(error.localizedDescription)"
        }
    }

    func configureReadLater(serviceID: String, sembleCollection selection: SembleCollectionSummary? = nil) async {
        if serviceID == "semble", selection == nil {
            errorMessage = "Choose a Semble collection before using it for Saved."
            return
        }
        do {
            try await pds.upsertReadLaterPreference(serviceID: serviceID, sembleCollection: selection)
            let previous = preferencesFromGateway
            let now = DateFormatters.string()
            var connections = previous?.readLaterConnections ?? [:]
            if let selection {
                connections["semble"] = ReadLaterConnectionPreferenceRecord(
                    connectedAt: now,
                    collectionUri: selection.uri,
                    collectionName: selection.name
                )
            }
            preferencesFromGateway = PreferencesRecord(
                type: PDSRecordService.preferences,
                readLaterService: serviceID,
                readLaterConnections: connections.isEmpty ? nil : connections,
                visibleFeeds: previous?.visibleFeeds,
                showTopLevelFeedUnreadCounts: previous?.showTopLevelFeedUnreadCounts,
                feedsWithUnreadCounts: previous?.feedsWithUnreadCounts,
                rssArticleOpenMode: previous?.rssArticleOpenMode,
                createdAt: previous?.createdAt ?? now,
                updatedAt: now
            )
            selectedSavedLink = nil
            selectedSembleItem = nil
            if serviceID == "semble" {
                sembleCollectionUnavailable = false
                sembleCollectionLoadFailed = false
                await refreshSembleCollection()
            } else {
                await refreshSavedLinks()
            }
        } catch {
            errorMessage = "Couldn't update the Saved provider. \(error.localizedDescription)"
        }
    }

    func refreshSembleCollection() async {
        guard let viewerDID, let collectionURI = configuredSembleCollectionURI else {
            sembleCollection = nil
            sembleItems = []
            sembleCollectionUnavailable = false
            sembleCollectionLoadFailed = false
            return
        }
        let cacheKey = Self.sembleCollectionCacheKey(viewerDID: viewerDID, collectionURI: collectionURI)
        var restoredCache = false
        if let body = readerCacheCoordinator?.gatewayCachedBody(for: cacheKey),
           let cached = try? JSONDecoder().decode(SembleCollectionItemsPage.self, from: body)
        {
            applySemblePage(cached)
            restoredCache = true
        }
        if !restoredCache { isLoadingSemble = true }
        defer { isLoadingSemble = false }

        do {
            var cursor: String?
            var collection: SembleCollectionSummary?
            var items: [SembleCollectionItem] = []
            var membershipComplete = true
            var recordLinksComplete = true
            repeat {
                let page = try await gateway.fetchSembleCollection(
                    collectionURI: collectionURI,
                    cursor: cursor
                )
                collection = page.collection
                items.append(contentsOf: page.items)
                membershipComplete = membershipComplete && page.membershipComplete
                recordLinksComplete = recordLinksComplete && page.recordLinksComplete
                cursor = page.cursor
            } while cursor != nil
            guard let collection else { return }
            let page = SembleCollectionItemsPage(
                collection: collection,
                items: items,
                cursor: nil,
                membershipComplete: membershipComplete,
                recordLinksComplete: recordLinksComplete
            )
            applySemblePage(page)
            sembleCollectionUnavailable = false
            sembleCollectionLoadFailed = false
            if let body = try? JSONEncoder().encode(page) {
                try? readerCacheCoordinator?.upsertGatewayResponse(cacheKey: cacheKey, etag: nil, body: body)
            }
        } catch let error as SocialWireError {
            if case .sembleCollectionUnavailable = error {
                sembleCollectionUnavailable = true
                sembleCollectionLoadFailed = false
                sembleCollection = nil
                sembleItems = []
                selectedSembleItem = nil
            } else {
                sembleCollectionLoadFailed = true
            }
            if !restoredCache {
                errorMessage = "Couldn't load the Semble collection. \(error.localizedDescription)"
            }
        } catch {
            sembleCollectionLoadFailed = true
            if !restoredCache {
                errorMessage = "Couldn't load the Semble collection. \(error.localizedDescription)"
            }
        }
    }

    func removeSembleItem(_ item: SembleCollectionItem) async {
        guard let collectionURI = configuredSembleCollectionURI else { return }
        let snapshot = sembleItems
        sembleItems.removeAll { $0.id == item.id }
        if selectedSembleItem?.id == item.id { selectedSembleItem = nil }
        do {
            try await sembleRecords.removeMembership(item: item, collectionURI: collectionURI)
            await refreshSembleCollection()
        } catch {
            sembleItems = snapshot
            errorMessage = "Couldn't remove this card from the collection. \(error.localizedDescription)"
        }
    }

    func addSembleNote(_ text: String, to item: SembleCollectionItem) async {
        guard let cardCID = item.cardCid else {
            errorMessage = "This Semble card is missing the CID required for a note."
            return
        }
        do {
            _ = try await sembleRecords.addNote(text, to: StrongRef(uri: item.cardUri, cid: cardCID))
            await refreshSembleCollection()
        } catch {
            errorMessage = "Couldn't add the note. \(error.localizedDescription)"
        }
    }

    func updateSembleNote(_ text: String, on item: SembleCollectionItem) async {
        guard let note = item.note, let noteURI = note.uri, let cardCID = item.cardCid else { return }
        do {
            try await sembleRecords.updateNote(
                uri: noteURI,
                text: text,
                parentCard: StrongRef(uri: item.cardUri, cid: cardCID)
            )
            await refreshSembleCollection()
        } catch {
            errorMessage = "Couldn't update the note. \(error.localizedDescription)"
        }
    }

    func loadSembleConnections(for item: SembleCollectionItem) async {
        guard let url = item.url else {
            sembleConnections = []
            return
        }
        do {
            var rows: [SembleConnection] = []
            var cursor: String?
            repeat {
                let page = try await gateway.fetchSembleConnections(url: url, cursor: cursor)
                rows.append(contentsOf: page.connections)
                cursor = page.cursor
            } while cursor != nil
            sembleConnections = rows
        } catch {
            sembleConnections = []
        }
    }

    func createSembleConnection(
        from source: SembleCollectionItem,
        to target: SembleCollectionItem,
        connectionType: String?,
        note: String?
    ) async {
        do {
            _ = try await sembleRecords.createConnection(
                source: source.cardUri,
                target: target.cardUri,
                connectionType: connectionType,
                note: note
            )
            await loadSembleConnections(for: source)
        } catch {
            errorMessage = "Couldn't create the Semble connection. \(error.localizedDescription)"
        }
    }

    func updateSembleConnection(
        _ connection: SembleConnection,
        from source: SembleCollectionItem,
        to target: SembleCollectionItem,
        connectionType: String?,
        note: String?
    ) async {
        guard connection.editable, let connectionURI = connection.uri else { return }
        do {
            try await sembleRecords.updateConnection(
                uri: connectionURI,
                source: source.cardUri,
                target: target.cardUri,
                connectionType: connectionType,
                note: note,
                createdAt: connection.createdAt ?? DateFormatters.string()
            )
            await loadSembleConnections(for: source)
        } catch {
            errorMessage = "Couldn't update the Semble connection. \(error.localizedDescription)"
        }
    }

    func deleteSembleConnection(_ connection: SembleConnection, from item: SembleCollectionItem) async {
        guard connection.editable, let connectionURI = connection.uri else { return }
        do {
            try await sembleRecords.deleteConnection(uri: connectionURI)
            await loadSembleConnections(for: item)
        } catch {
            errorMessage = "Couldn't delete the Semble connection. \(error.localizedDescription)"
        }
    }

    func resumeSembleSave() async {
        guard let pendingSembleSaveRetry else { return }
        do {
            try await sembleRecords.resumeSave(pendingSembleSaveRetry)
            self.pendingSembleSaveRetry = nil
            await refreshSembleCollection()
        } catch {
            errorMessage = "Couldn't finish adding this card to the collection. \(error.localizedDescription)"
        }
    }

    private func saveEntryToSemble(
        entryId: String,
        url: URL?,
        title: String?,
        linkedWebURL: String?,
        note: String?
    ) async {
        guard let collectionURI = configuredSembleCollectionURI else {
            errorMessage = "Choose a Semble collection in Settings before saving."
            return
        }
        guard !sembleCollectionUnavailable else {
            errorMessage = "Choose another Semble collection in Settings before saving."
            return
        }
        let rawURL = url?.absoluteString
            ?? linkedWebURL?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (entryId.hasPrefix("http") ? entryId : nil)
        guard let rawURL, let normalizedURL = SembleRecordService.normalizeURL(rawURL) else {
            errorMessage = "This article doesn't have a web URL Semble can save."
            return
        }
        if sembleItems.contains(where: { $0.url.flatMap(SembleRecordService.normalizeURL) == normalizedURL }) {
            return
        }
        do {
            switch try await sembleRecords.saveURL(normalizedURL, title: title, to: collectionURI) {
            case .saved(let card):
                pendingSembleSaveRetry = nil
                if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    _ = try await sembleRecords.addNote(note, to: card)
                }
                await refreshSembleCollection()
            case .membershipRetry(let retry, let message):
                pendingSembleSaveRetry = retry
                errorMessage = "The card was created, but adding it to the collection needs to be resumed. \(message)"
            }
        } catch {
            errorMessage = "Couldn't save this article to Semble. \(error.localizedDescription)"
        }
    }

    private func applySemblePage(_ page: SembleCollectionItemsPage) {
        sembleCollection = page.collection
        sembleItems = page.items
        if let selectedID = selectedSembleItem?.id {
            selectedSembleItem = page.items.first { $0.id == selectedID }
        }
    }

    nonisolated static func sembleCollectionCacheKey(viewerDID: String, collectionURI: String) -> String {
        "semble:v1|viewer=\(viewerDID)|provider=semble|collection=\(collectionURI)"
    }

    func archive(_ save: MergedLatrSave) async {
        let snapshotActive = savedLinks
        let snapshotArchived = archivedSavedLinks
        applyOptimisticLatrArchive(save)
        if selectedSavedLink?.id == save.id {
            selectedSavedLink = nil
        }
        do {
            try await latrGateway.archive(bookmarkURI: save.itemRkey)
            await refreshSavedLinks()
        } catch {
            savedLinks = snapshotActive
            archivedSavedLinks = snapshotArchived
            errorMessage = "Couldn't archive this link. \(error.localizedDescription)"
        }
    }

    func unarchive(_ save: MergedLatrSave) async {
        let snapshotActive = savedLinks
        let snapshotArchived = archivedSavedLinks
        applyOptimisticLatrUnarchive(save)
        if selectedSavedLink?.id == save.id {
            selectedSavedLink = nil
        }
        do {
            try await latrGateway.unarchive(bookmarkURI: save.itemRkey)
            await refreshSavedLinks()
        } catch {
            savedLinks = snapshotActive
            archivedSavedLinks = snapshotArchived
            errorMessage = "Couldn't move this link back to Read Later. \(error.localizedDescription)"
        }
    }

    func delete(_ save: MergedLatrSave) async {
        let snapshotActive = savedLinks
        let snapshotArchived = archivedSavedLinks
        applyOptimisticLatrDelete(save)
        if selectedSavedLink?.id == save.id {
            selectedSavedLink = nil
        }
        do {
            try await latrGateway.delete(bookmarkURI: save.itemRkey)
            await refreshSavedLinks()
        } catch {
            savedLinks = snapshotActive
            archivedSavedLinks = snapshotArchived
            errorMessage = "Couldn't delete this saved link. \(error.localizedDescription)"
        }
    }

    func replaceTags(on save: MergedLatrSave, with tags: [String]) async {
        let snapshotActive = savedLinks
        let snapshotArchived = archivedSavedLinks
        let snapshotSelected = selectedSavedLink
        replaceSavedLink(save.withTags(tags))
        do {
            let updated = try await latrGateway.setTags(
                bookmarkURI: save.itemRkey,
                tags: tags
            )
            replaceSavedLink(updated)
        } catch {
            savedLinks = snapshotActive
            archivedSavedLinks = snapshotArchived
            selectedSavedLink = snapshotSelected
            errorMessage = "Couldn't update tags. \(error.localizedDescription)"
        }
    }

    func clearTags(on save: MergedLatrSave) async {
        await replaceTags(on: save, with: [])
    }

    func renameSavedTag(_ tag: String, replacement: String) async {
        savedTagMutationProgress = SavedTagMutationProgress(
            tag: tag,
            action: .rename(replacement: replacement)
        )
        await resumeSavedTagMutation()
    }

    func deleteSavedTag(_ tag: String) async {
        savedTagMutationProgress = SavedTagMutationProgress(tag: tag, action: .delete)
        await resumeSavedTagMutation()
    }

    func resumeSavedTagMutation() async {
        guard var progress = savedTagMutationProgress, !isMutatingSavedTags else { return }
        isMutatingSavedTags = true
        progress.errorMessage = nil
        savedTagMutationProgress = progress
        defer { isMutatingSavedTags = false }

        do {
            repeat {
                let batchCursor = progress.cursor
                let page: LatrTagMutationResult
                switch progress.action {
                case .rename(let replacement):
                    page = try await latrGateway.renameTag(
                        progress.tag,
                        replacement: replacement,
                        cursor: progress.cursor
                    )
                case .delete:
                    page = try await latrGateway.deleteTag(
                        progress.tag,
                        cursor: progress.cursor
                    )
                }
                progress.applyPage(
                    scanned: page.scanned,
                    matched: page.matched,
                    updated: page.updated,
                    cursor: page.cursor
                )
                if !page.ok {
                    // Preserve the last safe cursor when the provider reports a partial batch
                    // without advancing. Retrying tag mutations is idempotent.
                    if progress.cursor == nil { progress.cursor = batchCursor }
                    progress.errorMessage = "The last batch completed only partially. Resume to continue from the last safe cursor."
                    savedTagMutationProgress = progress
                    return
                }
                savedTagMutationProgress = progress
                await Task.yield()
            } while progress.cursor != nil

            if selectedSavedTag == progress.tag {
                switch progress.action {
                case .rename(let replacement): selectSavedTag(replacement)
                case .delete: selectSavedTag(nil)
                }
            }
            await refreshSavedLinks()
        } catch {
            progress.errorMessage = error.localizedDescription
            savedTagMutationProgress = progress
        }
    }

    func dismissSavedTagMutationProgress() {
        guard !isMutatingSavedTags else { return }
        savedTagMutationProgress = nil
    }

    func savedLinkSocialEntry(for save: MergedLatrSave) async -> EntryDetail? {
        if let originalEntryId = SavedLinkSocialTarget.originalEntryId(from: save) {
            if let cached = try? readerCacheCoordinator?.entryDetail(originalEntryId) {
                return cached
            }
            if let detail = try? await gateway.fetchAppViewEntryDetail(entryId: originalEntryId) {
                return detail
            }
            if let detail = try? await publicationsService.entryDetail(entryId: originalEntryId) {
                return detail
            }
        }
        return SavedLinkSocialTarget.fallbackEntryDetail(from: save)
    }

    func quoteEntry(_ entry: EntryDetail, text: String) async throws {
        try await publicationsService.createQuote(text: text, entry: entry)
    }

    func replyToEntry(_ entry: EntryDetail, text: String) async throws {
        try await publicationsService.createReply(text: text, entry: entry)
    }

    func likeEntry(_ entry: EntryDetail) async {
        let loadingKey = "like:\(entry.entryId)"
        guard articleSocialStateLoadingKeys.insert(loadingKey).inserted else { return }
        defer { articleSocialStateLoadingKeys.remove(loadingKey) }
        do {
            if let recordURI = likeRecordURIByEntryID[entry.entryId] {
                try await publicationsService.deleteLike(recordURI: recordURI)
                likeRecordURIByEntryID.removeValue(forKey: entry.entryId)
            } else {
                likeRecordURIByEntryID[entry.entryId] = try await publicationsService.createLike(entry: entry)
            }
        } catch {
            errorMessage = "Couldn't update your like. \(error.localizedDescription)"
        }
    }

    func repostEntry(_ entry: EntryDetail) async {
        let loadingKey = "repost:\(entry.entryId)"
        guard articleSocialStateLoadingKeys.insert(loadingKey).inserted else { return }
        defer { articleSocialStateLoadingKeys.remove(loadingKey) }
        do {
            if let recordURI = repostRecordURIByEntryID[entry.entryId] {
                try await publicationsService.deleteRepost(recordURI: recordURI)
                repostRecordURIByEntryID.removeValue(forKey: entry.entryId)
            } else {
                repostRecordURIByEntryID[entry.entryId] = try await publicationsService.createRepost(entry: entry)
            }
        } catch {
            errorMessage = "Couldn't update your repost. \(error.localizedDescription)"
        }
    }

    func isEntryLiked(_ entry: EntryDetail) -> Bool {
        likeRecordURIByEntryID[entry.entryId] != nil
    }

    func isEntryReposted(_ entry: EntryDetail) -> Bool {
        repostRecordURIByEntryID[entry.entryId] != nil
    }

    func wireArticleFeedbackValue(for entry: EntryDetail) -> WireArticleFeedbackValue? {
        guard let canonicalURL = normalizedWireFeedbackURL(for: entry) else { return nil }
        return wireFeedbackByCanonicalURL[canonicalURL]
    }

    func isStandardSiteRecommended(_ entry: EntryDetail) -> Bool {
        guard let documentURI = entry.standardSiteDocumentURI else { return false }
        return recommendedStandardSiteDocumentURIs.contains(documentURI)
    }

    func isArticleSocialStateLoading(for entry: EntryDetail) -> Bool {
        articleSocialLoadingKeys(for: entry).contains { articleSocialStateLoadingKeys.contains($0) }
    }

    func loadArticleSocialState(for entry: EntryDetail) async {
        let loadingKeys = articleSocialLoadingKeys(for: entry)
        guard !loadingKeys.isEmpty,
              loadingKeys.allSatisfy({ !articleSocialStateLoadingKeys.contains($0) })
        else { return }
        articleSocialStateLoadingKeys.formUnion(loadingKeys)
        defer { articleSocialStateLoadingKeys.subtract(loadingKeys) }

        if let canonicalURL = normalizedWireFeedbackURL(for: entry) {
            do {
                let records = try await pds.listWireArticleFeedback()
                let matching = records.first { record in
                    WireArticleFeedbackContract.normalizeCanonicalURL(record.value.canonicalUrl) == canonicalURL
                }
                if let value = matching?.value.value {
                    wireFeedbackByCanonicalURL[canonicalURL] = value
                } else {
                    wireFeedbackByCanonicalURL.removeValue(forKey: canonicalURL)
                }
            } catch {
                errorMessage = "Couldn't load your Wire rating. \(error.localizedDescription)"
            }
        }

        if let documentURI = entry.standardSiteDocumentURI {
            do {
                let records = try await pds.listStandardSiteRecommendations()
                if records.contains(where: { $0.value.document == documentURI }) {
                    recommendedStandardSiteDocumentURIs.insert(documentURI)
                } else {
                    recommendedStandardSiteDocumentURIs.remove(documentURI)
                }
            } catch {
                errorMessage = "Couldn't load your recommendation. \(error.localizedDescription)"
            }
        }

        if let postURI = entry.bskyPostUri {
            do {
                let viewer = try await publicationsService.viewerState(for: postURI)
                if let like = viewer?.like {
                    likeRecordURIByEntryID[entry.entryId] = like
                } else {
                    likeRecordURIByEntryID.removeValue(forKey: entry.entryId)
                }
                if let repost = viewer?.repost {
                    repostRecordURIByEntryID[entry.entryId] = repost
                } else {
                    repostRecordURIByEntryID.removeValue(forKey: entry.entryId)
                }
            } catch {
                errorMessage = "Couldn't load your article reactions. \(error.localizedDescription)"
            }
        }
    }

    func toggleWireArticleFeedback(
        for entry: EntryDetail,
        value: WireArticleFeedbackValue
    ) async {
        guard let canonicalURL = normalizedWireFeedbackURL(for: entry) else { return }
        let loadingKey = "wire:\(canonicalURL)"
        guard articleSocialStateLoadingKeys.insert(loadingKey).inserted else { return }
        defer { articleSocialStateLoadingKeys.remove(loadingKey) }
        do {
            let next = try await pds.toggleWireArticleFeedback(
                canonicalURL: canonicalURL,
                subject: entry.wireFeedbackSubject,
                value: value
            )
            wireFeedbackByCanonicalURL[canonicalURL] = next
        } catch {
            errorMessage = "Couldn't rate this article. \(error.localizedDescription)"
        }
    }

    func toggleStandardSiteRecommendation(for entry: EntryDetail) async {
        guard let documentURI = entry.standardSiteDocumentURI else { return }
        let loadingKey = "recommend:\(documentURI)"
        guard articleSocialStateLoadingKeys.insert(loadingKey).inserted else { return }
        defer { articleSocialStateLoadingKeys.remove(loadingKey) }
        do {
            let isRecommended = try await pds.toggleStandardSiteRecommendation(
                documentURI: documentURI
            )
            if isRecommended {
                recommendedStandardSiteDocumentURIs.insert(documentURI)
            } else {
                recommendedStandardSiteDocumentURIs.remove(documentURI)
            }
        } catch {
            errorMessage = "Couldn't update your recommendation. \(error.localizedDescription)"
        }
    }

    private func normalizedWireFeedbackURL(for entry: EntryDetail) -> String? {
        entry.wireFeedbackCanonicalUrl.flatMap(WireArticleFeedbackContract.normalizeCanonicalURL)
    }

    private func articleSocialLoadingKeys(for entry: EntryDetail) -> Set<String> {
        var keys = Set<String>()
        if let canonicalURL = normalizedWireFeedbackURL(for: entry) {
            keys.insert("wire:\(canonicalURL)")
        }
        if let documentURI = entry.standardSiteDocumentURI {
            keys.insert("recommend:\(documentURI)")
        }
        if entry.bskyPostUri != nil {
            keys.insert("like:\(entry.entryId)")
            keys.insert("repost:\(entry.entryId)")
        }
        return keys
    }

    func replyToCurrentEntry(text: String) async {
        guard let selectedEntry else { return }
        do {
            try await publicationsService.createReply(text: text, entry: selectedEntry)
        } catch {
            errorMessage = "Couldn't post your reply. \(error.localizedDescription)"
        }
    }

    func quoteCurrentEntry(text: String) async {
        guard let selectedEntry else { return }
        do {
            try await publicationsService.createQuote(text: text, entry: selectedEntry)
        } catch {
            errorMessage = "Couldn't post your quote. \(error.localizedDescription)"
        }
    }

    func likeCurrentEntry() async {
        guard let selectedEntry else { return }
        await likeEntry(selectedEntry)
    }

    func repostCurrentEntry() async {
        guard let selectedEntry else { return }
        await repostEntry(selectedEntry)
    }

    private func publicationsAffected(by scope: ReaderMarkReadScope) -> [DiscoveredPublication] {
        switch scope {
        case .allLists:
            publicationsForAllListsBulkRead()
        case .list(let source):
            publicationsForBulkRead(list: source)
        case .folder(let folderRkey):
            gatewayFolderMap[folderRkey] ?? []
        case .publication(let publicationId):
            gatewayAllPublicationRows.filter { $0.publicationId == publicationId }
        case .entry, .unavailable:
            []
        }
    }

    private func clearUnreadCounts(for publications: [DiscoveredPublication]) {
        guard !publications.isEmpty else { return }
        markUnreadCountsOptimistic()
        for publication in publications {
            PublicationUnreadCountLookup.remove(
                for: publication.publicationId,
                from: &unreadCountsByPublicationId
            )
        }
        refreshSidebarUnreadSumCaches()
    }

    private func gatewayMarkAllReadScopes(for scope: ReaderMarkReadScope) -> [GatewayMarkAllReadScopeDTO] {
        switch scope {
        case .allLists:
            [.subscribed, .following]
        case .list(.subscribed):
            [.subscribed]
        case .list(.following):
            [.following]
        case .list(.wire), .list(.readLater), .list(.archive):
            []
        case .folder(let folderRkey):
            [.folder(folderRkey: folderRkey)]
        case .publication(let publicationId):
            [.publication(publicationId: publicationId)]
        case .entry, .unavailable:
            []
        }
    }
}
