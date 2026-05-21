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
    private var readerCacheCoordinator: ReaderCacheCoordinator?

    private static let preferencesSyncCacheKey = "v1/sync/preferences"

    var folders: [RepoRecord<FolderRecord>] = []
    var publicationPrefs: [String: RepoRecord<PublicationPrefsRecord>] = [:]
    var savedLinks: [MergedLatrSave] = []
    var readAtByEntryId: [String: Date] = [:]
    var entries: [EntryListItem] = []
    var selectedPublication: DiscoveredPublication?
    var selectedEntry: EntryDetail?
    var selectedSavedLink: MergedLatrSave?
    var selectedSidebar: SidebarSelection?
    var publicationSidebarTab: PublicationSidebarTab = .subscribed
    var readerListSource: ReaderListSource = .subscribed
    var viewerProfile: ActorProfileResponse?
    var readerFilter: ReaderFilter = .all
    var isLoading = false
    var isLoadingEntries = false
    var errorMessage: String?
    /// Lexical account preferences returned from **`GET /v1/sync/preferences`** (optional read-later hints).
    var preferencesFromGateway: PreferencesRecord?
    /// Entry id currently open under **Unread** filter — `markRead` is deferred until navigation away.
    private var unreadDeferredEntryId: String?
    /// AppView scope keys from **`GET /v1/publications/sidebar`**.
    private var sidebarScopesByPublicationId: [String: PublicationAppViewScopeDTO] = [:]
    /// Server unread counts keyed by publication id (sidebar projection + optional refresh).
    private var unreadCountsByPublicationId: [String: Int] = [:]
    /// Set false after a 404 from `/v1/appview/*` (API deployed without `ENABLE_THIN_APPVIEW`).
    private var appViewRoutesAvailable = true
    /// Read-later picker save in-flight (mirror web mutation pending state).
    var isUpdatingReadLaterPreference = false

    private var gatewaySubscribedUnfoldered: [DiscoveredPublication] = []
    private var gatewayMyPublications: [DiscoveredPublication] = []
    private var gatewayFollowingTab: [DiscoveredPublication] = []
    private var gatewayAllPublicationRows: [DiscoveredPublication] = []
    private var gatewayFolderMap: [String: [DiscoveredPublication]] = [:]

    init() {
        authService = ATProtoOAuthService()
        resolver = ATProtoResolver()
        xrpc = XRPCClient(auth: authService, resolver: resolver)
        pds = PDSRecordService(xrpc: xrpc)
        publicationsService = PublicationService(xrpc: xrpc)
        gateway = SocialWireGatewayClient(auth: authService)
        applyReaderListSource(ReaderListSourceStorage.load(), persist: false)
    }

    /// Call once SwiftData injects **`ModelContext`** (see **`RootView`**).
    func configureReaderPersistence(modelContext: ModelContext) {
        readerCacheCoordinator = ReaderCacheCoordinator(modelContext: modelContext)
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
        case .readLater:
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
        return readerCacheCoordinator?.distinctCachedEntryIds(publicationIds: publicationIds) ?? []
    }

    func cachedEntryIds(for scope: ReaderMarkReadScope) -> [String] {
        switch scope {
        case .allLists:
            cachedEntryIdsForBulkRead(publications: publicationsForAllListsBulkRead())
        case .list(let source):
            cachedEntryIdsForBulkRead(publications: publicationsForBulkRead(list: source))
        case .publication(let publicationId):
            readerCacheCoordinator?.distinctCachedEntryIds(publicationIds: [publicationId]) ?? []
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
            let entryIds = cachedEntryIds(for: scope)
            return entryIds.isEmpty || entryIds.allSatisfy { readAtByEntryId[$0] != nil }
        }
    }

    func markRead(for scope: ReaderMarkReadScope) async {
        switch scope {
        case .unavailable:
            return
        case .entry(let entryId):
            await markReadIfNeeded(entryId: entryId)
        case .allLists, .list, .publication:
            guard useAppViewEntryTimelines else { return }
            do {
                let scopes = gatewayMarkAllReadScopes(for: scope)
                guard !scopes.isEmpty else { return }
                let readAt = Date()
                for gatewayScope in scopes {
                    _ = try await gateway.markAllRead(scope: gatewayScope)
                }
                let entryIds = cachedEntryIds(for: scope).filter { readAtByEntryId[$0] == nil }
                for entryId in entryIds {
                    readAtByEntryId[entryId] = readAt
                }
                unreadDeferredEntryId = nil
                await refreshSidebarUnreadCounts()
            } catch {
                markAppViewUnavailableIfNeeded(error)
                errorMessage = error.localizedDescription
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

    var effectiveReadLaterServiceId: String {
        let g = preferencesFromGateway?.readLaterService?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let g, ReadLaterServiceCatalog.isKnownServiceId(g) { return g }
        let stored = UserDefaults.standard.string(forKey: ReadLaterServiceCatalog.userDefaultsStorageKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, ReadLaterServiceCatalog.isKnownServiceId(stored) { return stored }
        return ReadLaterServiceCatalog.defaultServiceId
    }

    var readLaterLatrConfigured: Bool {
        effectiveReadLaterServiceId == ReadLaterServiceCatalog.defaultServiceId
    }

    func unreadCachedBadge(for publication: DiscoveredPublication) -> Int {
        if let serverCount = unreadCountsByPublicationId[publication.publicationId], serverCount > 0 {
            return serverCount
        }
        return readerCacheCoordinator?.unreadCachedCount(
            publicationId: publication.publicationId,
            readAtByEntryId: readAtByEntryId
        ) ?? 0
    }

    func restoreSession() async {
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
        gatewaySubscribedUnfoldered = []
        gatewayMyPublications = []
        gatewayFollowingTab = []
        gatewayAllPublicationRows = []
        gatewayFolderMap = [:]
        appViewRoutesAvailable = true
        savedLinks = []
        entries = []
        selectedEntry = nil
        selectedPublication = nil
        selectedSavedLink = nil
        selectedSidebar = nil
        viewerProfile = nil
        preferencesFromGateway = nil
        unreadDeferredEntryId = nil
    }

    func sumUnread(for publications: [DiscoveredPublication]) -> Int {
        sumUnreadCount(for: publications, unreadCount: unreadCachedBadge(for:))
    }

    func openMyPublications() {
        selectedSidebar = .myPublications
        selectedPublication = nil
        selectedEntry = nil
        selectedSavedLink = nil
        entries = []
    }

    func selectReaderListSource(_ source: ReaderListSource) {
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
        case .readLater:
            selectedSidebar = .saved
            selectedPublication = nil
            selectedSavedLink = nil
            entries = []
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
        guard let viewerDID else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            try await refreshPublicationSidebarFromGateway(viewerDID: viewerDID)
            await refreshGatewayPreferencesSnapshot()
            Task(priority: .utility) { await self.prefetchSidebarPublications() }
        } catch {
            errorMessage = "Could not load publications from the server. \(error.localizedDescription)"
        }
    }

    private func refreshPublicationSidebarFromGateway(viewerDID: String) async throws {
        let projection = try await gateway.fetchPublicationSidebar()
        applyGatewaySidebarProjection(projection)

        async let readTask = pds.listEntryReadStates()
        async let savedTask = pds.listMergedLatrSaves()
        async let profileTask = publicationsService.fetchActorProfile(actor: viewerDID)

        readAtByEntryId = try await readTask
        savedLinks = try await savedTask
        viewerProfile = try? await profileTask

        if useAppViewEntryTimelines, !projection.enrollAuthorDids.isEmpty {
            Task(priority: .utility) {
                do {
                    _ = try await self.gateway.enrollAuthors(dids: projection.enrollAuthorDids)
                } catch {
                    self.markAppViewUnavailableIfNeeded(error)
                }
            }
        }

        await refreshSidebarUnreadCounts()
    }

    private func applyGatewaySidebarProjection(_ projection: PublicationSidebarResponseDTO) {
        sidebarScopesByPublicationId = projection.scopesByPublicationId()
        unreadCountsByPublicationId = PublicationProjectionMapping.unreadCountsMap(from: projection)

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
        } else {
            gatewayFolderMap = PublicationProjectionMapping.folderMap(
                allRows: gatewayAllPublicationRows,
                myPublications: gatewayMyPublications,
                followingTab: gatewayFollowingTab,
                publicationPrefs: publicationPrefs
            )
        }
    }

    private func gatewaySubscribedPublicationsList() -> [DiscoveredPublication] {
        var merged = gatewayMyPublications + gatewaySubscribedUnfoldered
        var ids = Set(merged.map(\.publicationId))
        for foldered in gatewayFolderMap.values.flatMap({ $0 }) where ids.insert(foldered.publicationId).inserted {
            merged.append(foldered)
        }
        return merged
    }

    private func refreshSidebarUnreadCounts() async {
        guard useAppViewEntryTimelines else { return }
        let publicationIds = gatewayAllPublicationRows.map(\.publicationId)
        guard !publicationIds.isEmpty else { return }
        do {
            let counts = try await gateway.fetchAppViewUnreadCounts(publicationIds: publicationIds)
            for (publicationId, count) in counts where count > 0 {
                unreadCountsByPublicationId[publicationId] = count
            }
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
        if let raw = envelope.record?.readLaterService?.trimmingCharacters(in: .whitespacesAndNewlines),
           ReadLaterServiceCatalog.isKnownServiceId(raw)
        {
            UserDefaults.standard.set(raw, forKey: ReadLaterServiceCatalog.userDefaultsStorageKey)
        }
    }

    func selectReadLaterService(_ serviceId: String) async {
        guard ReadLaterServiceCatalog.isKnownServiceId(serviceId) else { return }
        isUpdatingReadLaterPreference = true
        defer { isUpdatingReadLaterPreference = false }

        UserDefaults.standard.set(serviceId, forKey: ReadLaterServiceCatalog.userDefaultsStorageKey)

        do {
            try await pds.upsertReadLaterServicePreference(serviceId)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        await refreshGatewayPreferencesSnapshot(forceRefetch: true)
    }

    private func prefetchSidebarPublications() async {
        for publication in subscribedUnfolderedPublications.prefix(8) {
            try? await cacheOnlyLoadEntries(publication: publication)
        }
    }

    private func cacheOnlyLoadEntries(publication: DiscoveredPublication) async throws {
        guard let coordinator = readerCacheCoordinator else { return }
        let list = try await fetchEntriesForPublication(publication)
        try coordinator.upsertPublicationEntries(publicationId: publication.publicationId, entries: list)
    }

    private func markAppViewUnavailableIfNeeded(_ error: Error) {
        if case SocialWireError.appViewUnavailable = error {
            appViewRoutesAvailable = false
        }
    }

    private func fetchEntriesForPublication(_ publication: DiscoveredPublication) async throws -> [EntryListItem] {
        guard useAppViewEntryTimelines else {
            throw SocialWireError.appViewUnavailable
        }
        guard let scope = sidebarScopesByPublicationId[publication.publicationId] else {
            throw SocialWireError.badResponse("Missing AppView scope for publication.")
        }
        let page = try await gateway.fetchAppViewEntries(
            scope: scope,
            filter: readerFilter,
            cursor: nil
        )
        return page.entries
    }

    func publications(in folder: RepoRecord<FolderRecord>) -> [DiscoveredPublication] {
        gatewayFolderMap[rkey(from: folder.uri)] ?? []
    }

    func selectPublication(_ publication: DiscoveredPublication) async {
        unreadDeferredEntryId = nil
        selectedPublication = publication
        selectedSidebar = .publication(publication.publicationId)
        selectedSavedLink = nil
        selectedEntry = nil
        await loadEntries(for: publication)
    }

    func loadEntries(for publication: DiscoveredPublication) async {
        isLoadingEntries = true
        defer { isLoadingEntries = false }

        if let coordinator = readerCacheCoordinator,
           let snapshot = try? coordinator.publicationEntries(publication.publicationId) {
            entries = snapshot
        }

        do {
            let fresh = try await fetchEntriesForPublication(publication)
            entries = fresh
            try? readerCacheCoordinator?.upsertPublicationEntries(
                publicationId: publication.publicationId,
                entries: fresh
            )
        } catch {
            markAppViewUnavailableIfNeeded(error)
            if entries.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    func applyReaderFilter(_ newValue: ReaderFilter) async {
        let old = readerFilter
        readerFilter = newValue

        if useAppViewEntryTimelines,
           old != newValue,
           let publication = selectedPublication {
            await loadEntries(for: publication)
        }

        guard old == .unread, newValue == .all else { return }

        if let id = unreadDeferredEntryId {
            await markReadIfNeeded(entryId: id)
        } else if let open = selectedEntry?.entryId {
            await markReadIfNeeded(entryId: open)
        }
        unreadDeferredEntryId = nil
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
                selectedEntry = cached
            } else {
                selectedEntry = nil
            }

            let detail: EntryDetail?
            if useAppViewEntryTimelines {
                detail = try await gateway.fetchAppViewEntryDetail(entryId: item.entryId)
            } else {
                detail = nil
            }

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
            markAppViewUnavailableIfNeeded(error)
            errorMessage = error.localizedDescription
        }
    }

    private func markReadIfNeeded(entryId: String) async {
        guard readAtByEntryId[entryId] == nil else { return }
        guard useAppViewEntryTimelines else { return }
        do {
            let readAt = Date()
            try await gateway.upsertReadMark(subjectUri: entryId, readAt: readAt)
            readAtByEntryId[entryId] = readAt
            if let publicationId = selectedPublication?.publicationId,
               let current = unreadCountsByPublicationId[publicationId], current > 0 {
                unreadCountsByPublicationId[publicationId] = current - 1
            }
        } catch {
            markAppViewUnavailableIfNeeded(error)
            errorMessage = error.localizedDescription
        }
    }

    func toggleRead(_ item: EntryListItem) async {
        guard useAppViewEntryTimelines else { return }
        do {
            if readAtByEntryId[item.entryId] == nil {
                let readAt = Date()
                try await gateway.upsertReadMark(subjectUri: item.entryId, readAt: readAt)
                readAtByEntryId[item.entryId] = readAt
                if let publicationId = selectedPublication?.publicationId,
                   let current = unreadCountsByPublicationId[publicationId], current > 0 {
                    unreadCountsByPublicationId[publicationId] = current - 1
                }
            } else {
                try await gateway.deleteReadMark(subjectUri: item.entryId)
                readAtByEntryId.removeValue(forKey: item.entryId)
            }
        } catch {
            markAppViewUnavailableIfNeeded(error)
            errorMessage = error.localizedDescription
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
        do {
            _ = try await gateway.createFolder(GatewayFolderWriteBody(name: name))
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteFolder(_ folder: RepoRecord<FolderRecord>) async {
        do {
            try await gateway.deleteFolder(rkey: rkey(from: folder.uri))
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func assign(_ publication: DiscoveredPublication, to folder: RepoRecord<FolderRecord>?) async {
        do {
            let existing = publicationPrefs[publication.publicationId]
            _ = try await gateway.upsertPublicationPrefs(
                GatewayPublicationPrefsWriteBody(
                    publicationId: publication.publicationId,
                    folderId: folder.map { rkey(from: $0.uri) },
                    sortOrder: existing?.value.sortOrder,
                    hidden: existing?.value.hidden,
                    existingRkey: existing.map { rkey(from: $0.uri) }
                )
            )
            await refreshAll()
        } catch {
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

    func saveCurrentEntry() async {
        guard readLaterLatrConfigured, let selectedEntry, let url = selectedEntry.canonicalURL else { return }
        do {
            try await pds.saveURLToLatr(url, title: selectedEntry.title)
            savedLinks = try await pds.listMergedLatrSaves()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func archive(_ save: MergedLatrSave) async {
        guard case .external(let external) = save else { return }
        do {
            try await pds.archiveLatrExternal(normalizedURL: external.normalizedUrl)
            savedLinks = try await pds.listMergedLatrSaves()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ save: MergedLatrSave) async {
        guard case .external(let external) = save else { return }
        do {
            try await pds.deleteLatrExternal(normalizedURL: external.normalizedUrl)
            savedLinks = try await pds.listMergedLatrSaves()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func quoteCurrentEntry(text: String) async {
        guard let selectedEntry else { return }
        do {
            try await publicationsService.createQuote(text: text, entry: selectedEntry)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func likeCurrentEntry() async {
        guard let selectedEntry else { return }
        do {
            try await publicationsService.createLike(entry: selectedEntry)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func repostCurrentEntry() async {
        guard let selectedEntry else { return }
        do {
            try await publicationsService.createRepost(entry: selectedEntry)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func gatewayMarkAllReadScopes(for scope: ReaderMarkReadScope) -> [GatewayMarkAllReadScopeDTO] {
        switch scope {
        case .allLists:
            [.subscribed, .following]
        case .list(.subscribed):
            [.subscribed]
        case .list(.following):
            [.following]
        case .list(.readLater):
            []
        case .publication(let publicationId):
            [.publication(publicationId: publicationId)]
        case .entry, .unavailable:
            []
        }
    }
}
