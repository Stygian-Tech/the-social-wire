import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class SocialWireAppModel {
    let authService: ATProtoOAuthService
    let resolver: ATProtoResolver
    let xrpc: XRPCClient
    let pds: PDSRecordService
    let publicationsService: PublicationService
    private let rss = RSSService()
    private let gateway: SocialWireGatewayClient
    private let latrGateway: LatrGatewayClient
    private var readerCacheCoordinator: ReaderCacheCoordinator?

    private static let preferencesSyncCacheKey = "v1/sync/preferences"
    private static let lastSelectedPublicationKey = "the-social-wire.last-selected-publication-id"

    var folders: [RepoRecord<FolderRecord>] = []
    var publicationPrefs: [String: RepoRecord<PublicationPrefsRecord>] = [:]
    var savedLinks: [MergedLatrSave] = []
    var archivedSavedLinks: [MergedLatrSave] = []
    var readAtByEntryId: [String: Date] = [:]
    var entries: [EntryListItem] = []
    var selectedPublication: DiscoveredPublication?
    var selectedEntry: EntryDetail?
    var selectedSavedLink: MergedLatrSave?
    var selectedSidebar: SidebarSelection?
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
    /// Lexical account preferences returned from **`GET /v1/sync/preferences`** (optional read-later hints).
    var preferencesFromGateway: PreferencesRecord?
    /// Entry id currently open under **Unread** filter — `markRead` is deferred until navigation away.
    private var unreadDeferredEntryId: String?
    /// Bumped when publication selection clears the reader; stale `selectEntry` tasks must not reopen it.
    private var entrySelectionGeneration = 0
    /// AppView scope keys from **`GET /v1/publications/sidebar`**.
    private var sidebarScopesByPublicationId: [String: PublicationAppViewScopeDTO] = [:]
    /// Server unread counts keyed by publication id (sidebar projection + optional refresh).
    private var unreadCountsByPublicationId: [String: Int] = [:]
    /// Cached sidebar section unread totals (recomputed when counts or folder membership change).
    private(set) var foldersSectionUnreadCount = 0
    private(set) var subscribedUnfolderedSectionUnreadCount = 0
    private(set) var folderUnreadCountsByRkey: [String: Int] = [:]
    private(set) var followingSectionUnreadCount = 0
    /// Dedupes pagination triggers when the last filtered row re-appears during fast scroll.
    private var entriesPaginationTriggeredForEntryId: String?
    /// Set false after a 404 from `/v1/appview/*` (API deployed without `ENABLE_THIN_APPVIEW`).
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
    private var bootstrapCompletedAt: Date?
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
        publicationsService = PublicationService(xrpc: xrpc)
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
        case .readLater, .archive:
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
        case .allLists, .list, .publication:
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
        case .allLists, .list, .publication:
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
                for entryId in entryIds {
                    await syncEntryReadStateToPDS(subjectURI: entryId, readAt: readAt)
                }
                await syncCrossClientReadState()
            } catch {
                unreadCountsByPublicationId = savedUnreadCounts
                readAtByEntryId = savedReadAtByEntryId
                markAppViewUnavailableIfNeeded(error)
                // Mark-all-read is an automatic side effect of navigation; failures roll back the
                // optimistic counts above without interrupting the user with a modal alert.
            }
        }
    }

    var focusedEntryIdForMarkRead: String? {
        selectedEntry?.entryId ?? unreadDeferredEntryId
    }

    func markReadScope(compactPane: ReaderPane?, isCompact: Bool) -> ReaderMarkReadScope {
        if let entryId = focusedEntryIdForMarkRead, showsEntryMarkReadInChrome(
            compactPane: compactPane,
            isCompact: isCompact
        ) {
            return .entry(entryId: entryId)
        }

        if isCompact, let compactPane {
            switch compactPane {
            case .lists:
                return .allLists
            case .publications:
                return .list(readerListSource)
            case .articles:
                if let publicationId = selectedPublication?.publicationId {
                    return .publication(publicationId: publicationId)
                }
                return .list(readerListSource)
            case .reader:
                return selectedSavedLink != nil ? .unavailable : .list(readerListSource)
            }
        }

        if selectedSavedLink != nil {
            return .unavailable
        }
        if let publicationId = selectedPublication?.publicationId {
            return .publication(publicationId: publicationId)
        }
        return .list(readerListSource)
    }

    private func showsEntryMarkReadInChrome(compactPane: ReaderPane?, isCompact: Bool) -> Bool {
        guard focusedEntryIdForMarkRead != nil else { return false }
        if isCompact {
            return compactPane == .reader
        }
        return selectedEntry != nil
    }

    var filteredEntries: [EntryListItem] {
        switch readerFilter {
        case .all: entries
        case .unread: entries.filter { readAtByEntryId[$0.entryId] == nil }
        }
    }

    var canLoadMoreEntries: Bool {
        guard let entriesNextCursor else { return false }
        return !entriesNextCursor.isEmpty
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

  private func adjustUnreadCount(publicationId: String, delta: Int) {
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
        replacePublicationIds: [String]? = nil
    ) {
        applyFetchedUnreadCounts(
            counts,
            publicationIds: replacePublicationIds ?? sidebarPublicationIds()
        )
    }

    private func applyFetchedUnreadCounts(_ counts: [String: Int], publicationIds: [String]) {
        sidebarUnread.cachedPriorityProjection = cachedPriorityProjection
        sidebarUnread.applyFetchedCounts(counts, publicationIds: publicationIds)
        unreadCountsByPublicationId = sidebarUnread.unreadCountsByPublicationId
        cachedPriorityProjection = sidebarUnread.cachedPriorityProjection
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
        authService.signOut()
        folders = []
        publicationPrefs = [:]
        sidebarScopesByPublicationId = [:]
        unreadCountsByPublicationId = [:]
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
        selectedSidebar = nil
        viewerProfile = nil
        preferencesFromGateway = nil
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
        entries = []
    }

    func selectReaderListSource(_ source: ReaderListSource) {
        guard readerListSource != source else { return }
        selectedEntry = nil
        unreadDeferredEntryId = nil
        applyReaderListSource(source, persist: true)
    }

    private func applyReaderListSource(_ source: ReaderListSource, persist: Bool) {
        readerListSource = source
        if persist {
            ReaderListSourceStorage.save(source)
        }

        switch source {
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
        case .following:
            publicationSidebarTab = .following
            selectedSidebar = nil
            selectedPublication = nil
            selectedSavedLink = nil
            entries = []
        }
    }

    func refreshAll() async {
        await refreshSidebarProjection()
        await refreshActiveReaderContentIfNeeded()
    }

    /// Bootstrap stream + sidebar snapshot only (pull-to-refresh on Publications pane).
    func refreshSidebarProjection() async {
        guard let viewerDID else { return }
        loadSidebarExpandedKeys(for: viewerDID)
        isLoading = true
        sidebarFetching = true
        folderPublicationsLoading = !hasSidebarSnapshot
        rebuildSidebarTreeViewModel()

        restoreCachedSidebarSnapshot(viewerDid: viewerDID)
        restoreLastSelectedPublicationEntriesIfCached()
        if hasSidebarSnapshot, let launchStartedAt {
            logBootstrapPhase("cachedContentReady", startedAt: launchStartedAt)
        }

        do {
            await gateway.warmGatewayDpopNonce()
            try await refreshPublicationSidebarFromBootstrapStream(viewerDID: viewerDID)
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

    /// Hydrate PDS read state and saved links after sidebar projection refresh.
    func refreshActiveReaderContentIfNeeded() async {
        guard let viewerDID else { return }
        await hydrateViewerStateAfterBootstrap(viewerDID: viewerDID)
    }

    private func refreshPublicationSidebarFromBootstrapStream(viewerDID: String) async throws {
        bootstrapCoordinator.reset()
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
        async let readTask = pds.listEntryReadStates()
        async let profileTask = publicationsService.fetchActorProfile(actor: viewerDID)

        mergeReadAtByEntryId((try? await readTask) ?? [:])
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
            applyStreamUnreadCounts(payload.counts, replacePublicationIds: payload.replacePublicationIds)
            logBootstrapPhase("unreadCounts", startedAt: streamStarted)
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

    private func refreshSidebarUnreadCounts(publicationIds: [String]? = nil) async {
        guard useAppViewEntryTimelines else { return }
        if SidebarFetchScheduler.shouldSkipUnreadRefresh(since: bootstrapCompletedAt) {
            return
        }
        let ids = publicationIds ?? gatewayAllPublicationRows.map(\.publicationId)
        guard !ids.isEmpty else { return }
        do {
            let counts = try await gateway.fetchAppViewUnreadCounts(publicationIds: ids)
            applyFetchedUnreadCounts(counts, publicationIds: ids)
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
            maxEntries: Self.entryPrefetchMaxEntries
        )
        try coordinator.upsertPublicationEntries(publicationId: publication.publicationId, entries: page.entries)
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
        maxEntries: Int? = nil
    ) async throws -> AppViewEntryListResponse {
        guard useAppViewEntryTimelines else {
            throw SocialWireError.appViewUnavailable
        }
        guard let scope = sidebarScopesByPublicationId[publication.publicationId] else {
            throw SocialWireError.badResponse("Missing AppView scope for publication.")
        }
        return try await gateway.fetchAppViewEntries(
            scope: scope,
            filter: readerFilter,
            cursor: cursor,
            maxEntries: maxEntries
        )
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

        if hadCachedEntries && !forceNetworkRefresh {
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
            persistPublicationEntries(publication.publicationId, entries: entries)
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
            entries = mergeEntryPagesAtTop(existing: entries, freshFirstPage: page.entries)
            if entriesNextCursor == nil {
                entriesNextCursor = page.cursor
            }
            persistPublicationEntries(publication.publicationId, entries: entries)
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
            persistPublicationEntries(publication.publicationId, entries: entries)
            await prefetchThumbnailImages(for: page.entries)
        } catch {
            if entryId != nil {
                entriesPaginationTriggeredForEntryId = nil
            }
            markAppViewUnavailableIfNeeded(error)
        }
    }

    func applyReaderFilter(_ newValue: ReaderFilter) async {
        let old = readerFilter
        readerFilter = newValue

        if old == .unread, newValue == .all {
            if let id = unreadDeferredEntryId {
                await markReadIfNeeded(entryId: id)
            } else if let open = selectedEntry?.entryId {
                await markReadIfNeeded(entryId: open)
            }
            unreadDeferredEntryId = nil
            return
        }

        if newValue == .unread, let publication = selectedPublication {
            entries = []
            entriesNextCursor = nil
            entriesPaginationTriggeredForEntryId = nil
            await loadEntries(for: publication, forceNetworkRefresh: true)
            if filteredEntries.isEmpty, canLoadMoreEntries {
                await chaseUnreadPagesIfNeeded(for: publication)
            }
        }
    }

    func chaseUnreadPagesIfNeeded(for publication: DiscoveredPublication) async {
        guard readerFilter == .unread else { return }
        guard filteredEntries.isEmpty, canLoadMoreEntries else { return }
        guard !isLoadingEntries, !isLoadingMoreEntries else { return }
        guard selectedPublication?.publicationId == publication.publicationId else { return }

        await loadMoreEntriesIfNeeded(for: publication)
        if filteredEntries.isEmpty, canLoadMoreEntries {
            await chaseUnreadPagesIfNeeded(for: publication)
        }
    }

    func dismissReaderDetail() async {
        if readerFilter == .unread {
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

    private func markReadIfNeeded(entryId: String) async {
        guard readAtByEntryId[entryId] == nil else { return }
        guard useAppViewEntryTimelines else { return }

        do {
            let readAt = Date()
            try await gateway.upsertReadMark(subjectUri: entryId, readAt: readAt)
            await syncEntryReadStateToPDS(subjectURI: entryId, readAt: readAt)
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
                await syncEntryReadStateToPDS(subjectURI: item.entryId, readAt: readAt)
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
                await syncEntryReadStateRemovalToPDS(subjectURI: item.entryId)
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

    /// Reload PDS read markers and AppView unread baselines after another client may have changed them.
    func syncCrossClientReadState() async {
        guard isSignedIn else { return }

        let priorReadAtByEntryId = readAtByEntryId
        var remoteReadAtByEntryId: [String: Date] = [:]
        do {
            remoteReadAtByEntryId = try await pds.listEntryReadStates()
            mergeReadAtByEntryId(remoteReadAtByEntryId)
        } catch {
            /* keep in-memory read map */
        }

        if useAppViewEntryTimelines {
            let readsNeedingAppViewSync = remoteReadAtByEntryId.filter { entryId, readAt in
                guard let prior = priorReadAtByEntryId[entryId] else { return true }
                return readAt < prior
            }
            for (entryId, readAt) in readsNeedingAppViewSync {
                try? await gateway.upsertReadMark(subjectUri: entryId, readAt: readAt)
            }
        }

        await refreshSidebarUnreadCounts()
        await refreshActivePublicationFeedIfNeeded(skipEnroll: true)
    }

    private func mergeReadAtByEntryId(_ remote: [String: Date]) {
        var merged = readAtByEntryId
        for (entryId, readAt) in remote {
            if let existing = merged[entryId] {
                merged[entryId] = min(existing, readAt)
            } else {
                merged[entryId] = readAt
            }
        }
        readAtByEntryId = merged
        sidebarUnread.bumpReadRevision()
        refreshSidebarUnreadSumCaches()
    }

    private func syncEntryReadStateToPDS(subjectURI: String, readAt: Date) async {
        do {
            try await pds.markRead(subjectURI: subjectURI, readAt: readAt)
        } catch {
            /* best-effort cross-client sync */
        }
    }

    private func syncEntryReadStateRemovalToPDS(subjectURI: String) async {
        do {
            try await pds.markUnread(subjectURI: subjectURI)
        } catch {
            /* record may already be absent */
        }
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
            let created = try await gateway.createFolder(GatewayFolderWriteBody(name: trimmed))
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
            try await gateway.deleteFolder(rkey: folderRkey)
            if let viewerDID {
                persistSidebarSnapshot(viewerDid: viewerDID)
            }
        } catch {
            restoreSidebarLayoutRollback(rollback)
            refreshSidebarUnreadSumCaches()
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
            _ = try await gateway.upsertPublicationPrefs(
                GatewayPublicationPrefsWriteBody(
                    publicationId: publication.publicationId,
                    folderId: toFolderRkey,
                    sortOrder: existing?.value.sortOrder,
                    hidden: existing?.value.hidden,
                    existingRkey: existing.map { rkey(from: $0.uri) }
                )
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
                switch result.kind {
                case "standard-site":
                    if let publicationAtUri = result.publicationAtUri {
                        _ = try await gateway.createPublicationSubscription(
                            GatewayPublicationSubscriptionWriteBody(publication: publicationAtUri)
                        )
                    }
                case "rss":
                    if let feedUrl = result.feedUrl {
                        _ = try await gateway.createRssSubscription(
                            GatewayRssSubscriptionWriteBody(
                                feedUrl: rss.normalizeFeedURL(feedUrl),
                                title: title ?? result.title,
                                siteUrl: result.siteUrl
                            )
                        )
                    }
                default:
                    break
                }
            } else if normalized.contains(".") || normalized.hasPrefix("http") {
                _ = try await gateway.createRssSubscription(
                    GatewayRssSubscriptionWriteBody(
                        feedUrl: rss.normalizeFeedURL(normalized),
                        title: title,
                        siteUrl: nil
                    )
                )
            } else {
                let did = try await resolver.resolveDID(handleOrDID: normalized)
                _ = try await gateway.createPublicationSubscription(
                    GatewayPublicationSubscriptionWriteBody(publication: did)
                )
            }
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var currentSavedLinks: [MergedLatrSave] {
        readerListSource == .archive ? archivedSavedLinks : savedLinks
    }

    func refreshSavedLinks() async {
        do {
            let latrListGateway = latrGateway
            savedLinks = try await pds.listMergedLatrSaves(state: .active, latrGateway: latrListGateway)
            archivedSavedLinks = try await pds.listMergedLatrSaves(state: .archived, latrGateway: latrListGateway)
        } catch {
            // Passive refresh (runs on pane appear and after mutations). Keep whatever links are
            // already shown and don't interrupt navigation with a modal alert.
        }
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
        linkedWebURL: String? = nil
    ) async {
        do {
            if let url {
                try await latrGateway.saveURL(url, title: title, excerpt: excerpt)
            } else {
                let linked = linkedWebURL
                    ?? selectedEntry?.canonicalURL?.absoluteString
                try await latrGateway.saveNativeSubject(subjectURI: entryId, linkedWebURL: linked)
            }
            await refreshSavedLinks()
        } catch {
            errorMessage = "Couldn't save this article to Read Later. \(error.localizedDescription)"
        }
    }

    func archive(_ save: MergedLatrSave) async {
        let snapshotActive = savedLinks
        let snapshotArchived = archivedSavedLinks
        applyOptimisticLatrArchive(save)
        if selectedSavedLink?.id == save.id {
            selectedSavedLink = nil
        }
        do {
            try await pds.updateLatrSaveState(save, state: "archived")
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
            try await pds.updateLatrSaveState(save, state: "unread")
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
            try await pds.deleteLatrSave(save)
            await refreshSavedLinks()
        } catch {
            savedLinks = snapshotActive
            archivedSavedLinks = snapshotArchived
            errorMessage = "Couldn't delete this saved link. \(error.localizedDescription)"
        }
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
        do {
            try await publicationsService.createLike(entry: entry)
        } catch {
            errorMessage = "Couldn't like this post. \(error.localizedDescription)"
        }
    }

    func repostEntry(_ entry: EntryDetail) async {
        do {
            try await publicationsService.createRepost(entry: entry)
        } catch {
            errorMessage = "Couldn't repost this post. \(error.localizedDescription)"
        }
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
        do {
            try await publicationsService.createLike(entry: selectedEntry)
        } catch {
            errorMessage = "Couldn't like this post. \(error.localizedDescription)"
        }
    }

    func repostCurrentEntry() async {
        guard let selectedEntry else { return }
        do {
            try await publicationsService.createRepost(entry: selectedEntry)
        } catch {
            errorMessage = "Couldn't repost this post. \(error.localizedDescription)"
        }
    }

    private func publicationsAffected(by scope: ReaderMarkReadScope) -> [DiscoveredPublication] {
        switch scope {
        case .allLists:
            publicationsForAllListsBulkRead()
        case .list(let source):
            publicationsForBulkRead(list: source)
        case .publication(let publicationId):
            gatewayAllPublicationRows.filter { $0.publicationId == publicationId }
        case .entry, .unavailable:
            []
        }
    }

    private func clearUnreadCounts(for publications: [DiscoveredPublication]) {
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
        case .list(.readLater), .list(.archive):
            []
        case .publication(let publicationId):
            [.publication(publicationId: publicationId)]
        case .entry, .unavailable:
            []
        }
    }
}
