import Foundation
import Observation

@Observable
@MainActor
final class SocialWireAppModel {
    let authService: ATProtoOAuthService
    let resolver: ATProtoResolver
    let xrpc: XRPCClient
    let pds: PDSRecordService
    let publicationsService: PublicationService
    let rss: RSSService

    var folders: [RepoRecord<FolderRecord>] = []
    var publicationPrefs: [String: RepoRecord<PublicationPrefsRecord>] = [:]
    var publications: [DiscoveredPublication] = []
    var savedLinks: [MergedLatrSave] = []
    var readAtByEntryId: [String: Date] = [:]
    var entries: [EntryListItem] = []
    var selectedPublication: DiscoveredPublication?
    var selectedEntry: EntryDetail?
    var selectedSavedLink: MergedLatrSave?
    var selectedSidebar: SidebarSelection? = .readingList
    var readerFilter: ReaderFilter = .all
    var isLoading = false
    var isLoadingEntries = false
    var errorMessage: String?

    init() {
        authService = ATProtoOAuthService()
        resolver = ATProtoResolver()
        xrpc = XRPCClient(auth: authService, resolver: resolver)
        pds = PDSRecordService(xrpc: xrpc)
        publicationsService = PublicationService(xrpc: xrpc)
        rss = RSSService()
    }

    var isSignedIn: Bool {
        authService.session != nil
    }

    var viewerDID: String? {
        authService.session?.did
    }

    var visiblePublications: [DiscoveredPublication] {
        publications.filter { !(publicationPrefs[$0.publicationId]?.value.hidden ?? false) }
    }

    var myPublications: [DiscoveredPublication] {
        guard let viewerDID else { return [] }
        return publications.filter { $0.authorDid == viewerDID }
    }

    var followingPublications: [DiscoveredPublication] {
        guard let viewerDID else { return visiblePublications }
        return visiblePublications.filter { $0.authorDid != viewerDID }
    }

    var hiddenPublications: [DiscoveredPublication] {
        publications.filter { publicationPrefs[$0.publicationId]?.value.hidden ?? false }
    }

    var unfolderedPublications: [DiscoveredPublication] {
        visiblePublications.filter { pub in
            guard pub.authorDid != viewerDID else { return false }
            return publicationPrefs[pub.publicationId]?.value.folderId == nil
        }
    }

    var filteredEntries: [EntryListItem] {
        switch readerFilter {
        case .all: entries
        case .unread: entries.filter { readAtByEntryId[$0.entryId] == nil }
        }
    }

    func restoreSession() async {
        await authService.restoreSession()
        if isSignedIn {
            await refreshAll()
        }
    }

    func signIn(handle: String) async {
        do {
            try await authService.signIn(handle: handle)
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleOAuthCallback(_ url: URL) async {
        do {
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
        publications = []
        savedLinks = []
        entries = []
        selectedEntry = nil
        selectedPublication = nil
        selectedSavedLink = nil
    }

    func refreshAll() async {
        guard let viewerDID else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let foldersTask = pds.listFolders()
            async let prefsTask = pds.listPublicationPrefs()
            async let standardTask = publicationsService.discoverPublications(viewerDID: viewerDID)
            async let skyreaderTask = pds.listSkyreaderSubscriptions()
            async let readTask = pds.listEntryReadStates()
            async let savedTask = pds.listMergedLatrSaves()

            folders = try await foldersTask
            let prefs = try await prefsTask
            publicationPrefs = Dictionary(uniqueKeysWithValues: prefs.map { ($0.value.publicationId, $0) })
            let rssPublications = try await skyreaderTask.compactMap { rss.discoveredPublication(from: $0) }
            publications = try await standardTask + rssPublications
            readAtByEntryId = try await readTask
            savedLinks = try await savedTask
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func publications(in folder: RepoRecord<FolderRecord>) -> [DiscoveredPublication] {
        visiblePublications.filter { publicationPrefs[$0.publicationId]?.value.folderId == rkey(from: folder.uri) }
    }

    func selectPublication(_ publication: DiscoveredPublication) async {
        selectedPublication = publication
        selectedSidebar = .publication(publication.publicationId)
        selectedSavedLink = nil
        selectedEntry = nil
        await loadEntries(for: publication)
    }

    func loadEntries(for publication: DiscoveredPublication) async {
        isLoadingEntries = true
        defer { isLoadingEntries = false }
        do {
            if let feedURL = rss.normalizedFeedURL(from: publication.publicationId) {
                entries = try await rss.entries(feedURL: feedURL)
            } else {
                entries = try await publicationsService.listEntries(publicationId: publication.publicationId)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectEntry(_ item: EntryListItem) async {
        do {
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
            try await pds.markRead(subjectURI: item.entryId)
            readAtByEntryId[item.entryId] = Date()
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
                hidden: false,
                existing: publicationPrefs[publication.publicationId]
            )
            await refreshAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setHidden(_ publication: DiscoveredPublication, hidden: Bool) async {
        do {
            try await pds.upsertPublicationPrefs(
                publicationId: publication.publicationId,
                folderId: publicationPrefs[publication.publicationId]?.value.folderId,
                hidden: hidden,
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
        guard let selectedEntry, let url = selectedEntry.canonicalURL else { return }
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
