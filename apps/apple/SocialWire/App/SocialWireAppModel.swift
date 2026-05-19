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
    let rss: RSSService
    private let gateway: SocialWireGatewayClient
    private var readerCacheCoordinator: ReaderCacheCoordinator?

    private static let preferencesSyncCacheKey = "v1/sync/preferences"

    var folders: [RepoRecord<FolderRecord>] = []
    var publicationPrefs: [String: RepoRecord<PublicationPrefsRecord>] = [:]
    /// Standard.site discovery rows (follow graph); RSS rows are kept separately.
    var discoveredPublications: [DiscoveredPublication] = []
    var rssPublications: [DiscoveredPublication] = []
    var publicationSubscriptions: [RepoRecord<PublicationSubscriptionRecord>] = []
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
    /// Read-later picker save in-flight (mirror web mutation pending state).
    var isUpdatingReadLaterPreference = false

    init() {
        authService = ATProtoOAuthService()
        resolver = ATProtoResolver()
        xrpc = XRPCClient(auth: authService, resolver: resolver)
        pds = PDSRecordService(xrpc: xrpc)
        publicationsService = PublicationService(xrpc: xrpc)
        rss = RSSService()
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

    var allPublicationRows: [DiscoveredPublication] {
        discoveredPublications + rssPublications
    }

    private var subscriptionLookupKeys: Set<String> {
        subscriptionPublicationKeys(from: publicationSubscriptions)
    }

    private var segmentedDiscovery: (
        graphSubscribed: [DiscoveredPublication],
        followOwnedUnsubscribed: [DiscoveredPublication]
    ) {
        segmentDiscoveryPublications(
            discoveredPublications,
            viewerDid: viewerDID,
            subscriptionKeys: subscriptionLookupKeys
        )
    }

    var subscribedPublications: [DiscoveredPublication] {
        mergeSubscribedPublications(
            graphSubscribed: segmentedDiscovery.graphSubscribed,
            rssPublications: rssPublications
        )
    }

    var myPublications: [DiscoveredPublication] {
        guard let viewerDID else { return [] }
        return subscribedPublications.filter { viewerOwnsDiscoveredPublication($0, viewerDid: viewerDID) }
    }

    var subscribedUnfolderedPublications: [DiscoveredPublication] {
        guard let viewerDID else { return [] }
        return subscribedPublications.filter { pub in
            guard !viewerOwnsDiscoveredPublication(pub, viewerDid: viewerDID) else { return false }
            return publicationPrefs[pub.publicationId]?.value.folderId == nil
        }
    }

    var followingTabPublications: [DiscoveredPublication] {
        filterFollowingTabPublications(
            followOwnedUnsubscribed: segmentedDiscovery.followOwnedUnsubscribed,
            myPublications: myPublications
        )
    }

    func publicationsForSidebarTab(_ tab: PublicationSidebarTab) -> [DiscoveredPublication] {
        switch tab {
        case .subscribed: subscribedUnfolderedPublications
        case .following: followingTabPublications
        }
    }

    /// All publications in the active sidebar tab (folders + unfoldered for subscribed), for bulk read scope.
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
            await markReadIfNeededOnPDS(entryId: entryId)
        case .allLists, .list, .publication:
            let entryIds = cachedEntryIds(for: scope).filter { readAtByEntryId[$0] == nil }
            guard !entryIds.isEmpty else { return }
            for entryId in entryIds {
                await markReadIfNeededOnPDS(entryId: entryId)
            }
            unreadDeferredEntryId = nil
        }
    }

    /// Entry id for the article currently open in the reader (detail or deferred unread).
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

    /// Effective read-later designation (gateway → local cache → **`latr-link`**), aligned with **`useConfiguredReadLaterService`** on web.
    var effectiveReadLaterServiceId: String {
        let g = preferencesFromGateway?.readLaterService?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let g, ReadLaterServiceCatalog.isKnownServiceId(g) { return g }
        let stored = UserDefaults.standard.string(forKey: ReadLaterServiceCatalog.userDefaultsStorageKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, ReadLaterServiceCatalog.isKnownServiceId(stored) { return stored }
        return ReadLaterServiceCatalog.defaultServiceId
    }

    /// Whether merged HTTPS read-later is active (mirror web **`readLaterService === "latr-link"`** intent).
    var readLaterLatrConfigured: Bool {
        effectiveReadLaterServiceId == ReadLaterServiceCatalog.defaultServiceId
    }

    func unreadCachedBadge(for publication: DiscoveredPublication) -> Int {
        readerCacheCoordinator?.unreadCachedCount(
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
        discoveredPublications = []
        rssPublications = []
        publicationSubscriptions = []
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
            async let foldersTask = pds.listFolders()
            async let prefsTask = pds.listPublicationPrefs()
            async let standardTask = publicationsService.discoverPublications(viewerDID: viewerDID)
            async let subscriptionsTask = pds.listPublicationSubscriptions()
            async let skyreaderTask = pds.listSkyreaderSubscriptions()
            async let readTask = pds.listEntryReadStates()
            async let savedTask = pds.listMergedLatrSaves()
            async let profileTask = publicationsService.fetchActorProfile(actor: viewerDID)

            folders = try await foldersTask
            let prefs = try await prefsTask
            publicationPrefs = Dictionary(uniqueKeysWithValues: prefs.map { ($0.value.publicationId, $0) })
            discoveredPublications = try await standardTask
            rssPublications = try await skyreaderTask.compactMap { rss.discoveredPublication(from: $0) }
            publicationSubscriptions = try await subscriptionsTask
            readAtByEntryId = try await readTask
            savedLinks = try await savedTask
            viewerProfile = try? await profileTask
        } catch {
            errorMessage = error.localizedDescription
        }

        await refreshGatewayPreferencesSnapshot()
        Task(priority: .utility) { await self.prefetchSidebarPublications() }
    }

    /// Pulls account preferences through the Swift gateway (ETag aware) — failures are non-fatal.
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
            // Prefer staying signed in + using PDS-only paths when the gateway is unavailable.
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
        let list: [EntryListItem]
        if let feedURL = rss.normalizedFeedURL(from: publication.publicationId) {
            list = try await rss.entries(feedURL: feedURL)
        } else {
            list = try await publicationsService.listEntries(publicationId: publication.publicationId)
        }
        try coordinator.upsertPublicationEntries(publicationId: publication.publicationId, entries: list)
    }

    func publications(in folder: RepoRecord<FolderRecord>) -> [DiscoveredPublication] {
        let folderRkey = rkey(from: folder.uri)
        return subscribedPublications.filter { publication in
            guard let viewerDID else { return false }
            guard !viewerOwnsDiscoveredPublication(publication, viewerDid: viewerDID) else { return false }
            return publicationPrefs[publication.publicationId]?.value.folderId == folderRkey
        }
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
            let fresh: [EntryListItem]
            if let feedURL = rss.normalizedFeedURL(from: publication.publicationId) {
                fresh = try await rss.entries(feedURL: feedURL)
            } else {
                fresh = try await publicationsService.listEntries(publicationId: publication.publicationId)
            }
            entries = fresh
            try? readerCacheCoordinator?.upsertPublicationEntries(
                publicationId: publication.publicationId,
                entries: fresh
            )
        } catch {
            if entries.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
    }

    func applyReaderFilter(_ newValue: ReaderFilter) async {
        let old = readerFilter
        readerFilter = newValue
        guard old == .unread, newValue == .all else { return }

        if let id = unreadDeferredEntryId {
            await markReadIfNeededOnPDS(entryId: id)
        } else if let open = selectedEntry?.entryId {
            await markReadIfNeededOnPDS(entryId: open)
        }
        unreadDeferredEntryId = nil
    }

    func dismissReaderDetail() async {
        if readerFilter == .unread {
            if let id = unreadDeferredEntryId {
                await markReadIfNeededOnPDS(entryId: id)
            } else if let open = selectedEntry?.entryId {
                await markReadIfNeededOnPDS(entryId: open)
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
                await markReadIfNeededOnPDS(entryId: previous)
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
            if item.entryId.hasPrefix("rss:"),
               let publication = selectedPublication,
               let feedURL = rss.normalizedFeedURL(from: publication.publicationId) {
                detail = try await rss.detail(entryID: item.entryId, feedURL: feedURL)
            } else {
                detail = try await publicationsService.entryDetail(entryId: item.entryId)
            }

            selectedEntry = detail
            selectedSavedLink = nil

            if let detail {
                try? readerCacheCoordinator?.upsertEntryDetail(detail)
            }

            if readerFilter == .all {
                await markReadIfNeededOnPDS(entryId: item.entryId)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func markReadIfNeededOnPDS(entryId: String) async {
        guard readAtByEntryId[entryId] == nil else { return }
        do {
            try await pds.markRead(subjectURI: entryId)
            readAtByEntryId[entryId] = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleRead(_ item: EntryListItem) async {
        do {
            if readAtByEntryId[item.entryId] == nil {
                try await pds.markRead(subjectURI: item.entryId)
                readAtByEntryId[item.entryId] = Date()
            } else {
                try await pds.markUnread(subjectURI: item.entryId)
                readAtByEntryId.removeValue(forKey: item.entryId)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createFolder(name: String) async {
        do {
            try await pds.createFolder(name: name)
            folders = try await pds.listFolders()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteFolder(_ folder: RepoRecord<FolderRecord>) async {
        do {
            try await pds.deleteFolder(rkey: rkey(from: folder.uri))
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func assign(_ publication: DiscoveredPublication, to folder: RepoRecord<FolderRecord>?) async {
        do {
            try await pds.upsertPublicationPrefs(
                publicationId: publication.publicationId,
                folderId: folder.map { rkey(from: $0.uri) },
                existing: publicationPrefs[publication.publicationId]
            )
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addPublication(input: String, title: String?) async {
        do {
            let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.contains(".") || normalized.hasPrefix("http") {
                try await pds.createSkyreaderSubscription(feedURL: rss.normalizeFeedURL(normalized), title: title)
            } else {
                let did = try await resolver.resolveDID(handleOrDID: normalized)
                try await pds.createPublicationSubscription(publication: did)
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
}
