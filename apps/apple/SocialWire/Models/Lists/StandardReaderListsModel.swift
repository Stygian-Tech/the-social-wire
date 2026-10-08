import Foundation
import ReadStateCore
import Observation

@Observable
@MainActor
final class StandardReaderListsModel {
    private let gateway: SocialWireGatewayClient
    private let pds: StandardReaderListPDSService
    private var viewer: String?
    private var epoch = 0
    private var feedEpoch = 0
    private var detailEpoch = 0
    private var fixtureFeed = false
    private(set) var selectedEntry: EntryDetail?
    private(set) var isLoadingEntry = false
    private(set) var entryError: String?
    private var deleted = Set<String>()
    private(set) var lists: [StandardReaderList] = []
    private(set) var selectedList: StandardReaderList?
    private(set) var entries: [EntryListItem] = []
    private(set) var cursor: String?
    private(set) var error: String?
    private(set) var feedError: String?
    private(set) var isLoading = false
    private(set) var isLoadingFeed = false
    private(set) var isSaving = false
    var filter: ReaderFilter = .all
    var signedIn: Bool { viewer != nil || fixtureFeed }

    init(gateway: SocialWireGatewayClient, xrpc: XRPCClient) {
        self.gateway = gateway
        pds = StandardReaderListPDSService(xrpc: xrpc)
    }

    func bind(viewer: String?) {
        guard self.viewer != viewer else { return }
        self.viewer = viewer
        epoch += 1
        feedEpoch += 1
        detailEpoch += 1
        selectedEntry = nil
        fixtureFeed = false
        isLoadingEntry = false
        entryError = nil
        lists = []
        selectedList = nil
        entries = []
        cursor = nil
        deleted = []
        error = nil
        feedError = nil
        isLoading = false
        isLoadingFeed = false
        isSaving = false
    }

    func load(refresh: Bool = false) async {
        if fixtureFeed { return }
        guard let viewer else { return }
        epoch += 1
        let revision = epoch
        isLoading = true
        defer { if revision == epoch { isLoading = false } }
        do {
            let page: StandardReaderListsPage = try await gateway.standardReaderListsRequest(
                method: refresh ? "POST" : "GET", path: refresh ? "/v1/lists/refresh" : "/v1/lists",
                body: refresh ? Data("{}".utf8) : nil, expectedViewer: viewer)
            guard self.viewer == viewer, revision == epoch else { return }
            apply(page)
        } catch {
            guard self.viewer == viewer, revision == epoch else { return }
            self.error = error.localizedDescription
        }
    }

    func apply(_ page: StandardReaderListsPage) {
        lists = page.merging(previous: lists).filter { !deleted.contains($0.uri) }
        error = page.complete == false ? "Some lists could not be refreshed. Showing previously loaded lists. Try Refresh." : nil
        if let selectedList {
            if let updated = lists.first(where: { $0.uri == selectedList.uri }) { self.selectedList = updated }
            else if page.complete != false { clearSelection() }
        }
    }

    func resolveCreator(_ creator: String) async throws -> String {
        guard let viewer else { throw SocialWireError.badResponse("Sign in to find authors.") }
        let page: StandardReaderListsPage = try await gateway.standardReaderListsRequest(path: "/v1/lists/search",
            query: ["creator": creator.trimmingCharacters(in: .whitespacesAndNewlines)], expectedViewer: viewer)
        guard self.viewer == viewer else { throw ReadStateSyncFailure.accountChanged }
        guard let did = page.creatorDid, did.range(of: #"^did:[a-z]+:[A-Za-z0-9._:%-]+$"#, options: .regularExpression) != nil else {
            throw SocialWireError.badResponse("The creator could not be resolved. Try again.")
        }
        return did
    }

    func openEntry(_ item: EntryListItem) async {
#if DEBUG
        if fixtureFeed, selectedList != nil, entries.contains(where: { $0.entryId == item.entryId }) {
            selectedEntry = EntryDetail(entryId: item.entryId, title: item.title, publishedAt: item.publishedAt,
                contentHtml: "<p>Fixture list article.</p>", originalUrl: item.originalUrl, embedUrl: nil, bskyPostUri: nil, bskyPostCid: nil)
            return
        }
#endif
        guard let viewer, let listURI = selectedList?.uri, entries.contains(where: { $0.entryId == item.entryId }) else { return }
        detailEpoch += 1
        let revision = detailEpoch, currentFeedEpoch = feedEpoch
        isLoadingEntry = true
        entryError = nil
        selectedEntry = nil
        defer { if revision == detailEpoch { isLoadingEntry = false } }
        do {
            let detail = try await gateway.fetchAppViewEntryDetail(entryId: item.entryId)
            guard self.viewer == viewer, selectedList?.uri == listURI,
                  revision == detailEpoch, feedEpoch == currentFeedEpoch else { return }
            guard let detail else { throw SocialWireError.badResponse("This article is unavailable.") }
            selectedEntry = detail
        } catch {
            guard self.viewer == viewer, revision == detailEpoch else { return }
            entryError = error.localizedDescription
        }
    }

#if DEBUG
    func configureFixture(lists: [StandardReaderList], entries: [EntryListItem]) {
        self.lists = lists
        self.entries = entries
        selectedList = nil
        fixtureFeed = true
    }
#endif

    func searchCreator(_ creator: String) async throws -> [StandardReaderList] {
        guard let viewer else { throw SocialWireError.badResponse("Sign in to find Lists.") }
        let page: StandardReaderListsPage = try await gateway.standardReaderListsRequest(path: "/v1/lists/search",
            query: ["creator": creator.trimmingCharacters(in: .whitespacesAndNewlines)], expectedViewer: viewer)
        guard self.viewer == viewer else { throw ReadStateSyncFailure.accountChanged }
        return page.lists
    }

    func resolve(_ input: String) async throws -> StandardReaderList {
        struct Input: Encodable { let input: String }
        struct Response: Decodable { let list: StandardReaderList }
        guard let viewer else { throw SocialWireError.badResponse("Sign in to open Lists.") }
        let value: Response = try await gateway.standardReaderListsRequest(method: "POST", path: "/v1/lists/resolve",
            body: JSONEncoder().encode(Input(input: input)), expectedViewer: viewer)
        guard self.viewer == viewer else { throw ReadStateSyncFailure.accountChanged }
        return value.list
    }

    func select(_ list: StandardReaderList) async {
        detailEpoch += 1
        selectedEntry = nil
        isLoadingEntry = false
        entryError = nil
        selectedList = list
        if fixtureFeed { return }
        await loadFeed()
    }

    func loadFeed(nextPage: Bool = false) async {
        guard !fixtureFeed, let viewer, let selectedList else { return }
        if nextPage && (cursor == nil || isLoadingFeed) { return }
        feedEpoch += 1
        let revision = feedEpoch
        let requestedCursor = nextPage ? cursor : nil
        let requestedFilter = filter
        if !nextPage { entries = []; cursor = nil; detailEpoch += 1; selectedEntry = nil; isLoadingEntry = false; entryError = nil }
        isLoadingFeed = true
        feedError = nil
        defer { if revision == feedEpoch { isLoadingFeed = false } }
        do {
            let page = try await gateway.fetchAggregateAppViewFeed(kind: "list", id: selectedList.uri,
                filter: requestedFilter, cursor: requestedCursor)
            guard self.viewer == viewer, revision == feedEpoch, self.selectedList?.uri == selectedList.uri else { return }
            let existing = Set(entries.map(\.entryId))
            entries += page.entries.filter { !existing.contains($0.entryId) }
            cursor = page.cursor == requestedCursor ? nil : page.cursor
        } catch {
            guard self.viewer == viewer, revision == feedEpoch else { return }
            feedError = error.localizedDescription
        }
    }

    func save(_ list: StandardReaderList, remove: Bool = false) async throws {
        try await mutate { viewer in
            if remove { try await self.pds.remove(list.uri, viewer: viewer) }
            else { try await self.pds.save(list.uri, viewer: viewer) }
            guard self.viewer == viewer else { throw ReadStateSyncFailure.accountChanged }
            self.lists.removeAll { $0.uri == list.uri }
            if !remove || list.owned {
                var updated = list
                updated.saved = !remove
                self.lists.append(updated)
                if self.selectedList?.uri == list.uri { self.selectedList = updated }
            } else if self.selectedList?.uri == list.uri { self.clearSelection() }
        }
    }

    func create(name: String, description: String, publications: [String], users: [String] = []) async throws -> StandardReaderList {
        let record = try StandardReaderListContract.makeRecord(name: name, description: description, publications: publications, users: users)
        var created: StandardReaderList?
        try await mutate { viewer in
            let list = try await self.pds.create(record, viewer: viewer)
            guard self.viewer == viewer else { throw ReadStateSyncFailure.accountChanged }
            self.lists.append(list)
            created = list
        }
        guard let created else { throw ReadStateSyncFailure.accountChanged }
        return created
    }

    func delete(_ list: StandardReaderList) async throws {
        try await mutate { viewer in
            try await self.pds.delete(list.uri, viewer: viewer)
            guard self.viewer == viewer else { throw ReadStateSyncFailure.accountChanged }
            self.deleted.insert(list.uri); self.lists.removeAll { $0.uri == list.uri }
            if self.selectedList?.uri == list.uri { self.clearSelection() }
            do { try await self.pds.remove(list.uri, viewer: viewer) }
            catch { throw SocialWireError.badResponse("Your list was deleted, but its saved reference could not be removed. Refresh Lists and retry removing the saved reference.") }
        }
    }

    private func clearSelection() {
        selectedList = nil
        entries = []
        cursor = nil
        selectedEntry = nil
        feedEpoch += 1
        detailEpoch += 1
        isLoadingFeed = false
        isLoadingEntry = false
        feedError = nil
        entryError = nil
    }

    private func mutate(_ action: (String) async throws -> Void) async throws {
        guard let viewer else { throw SocialWireError.badResponse("Sign in to update Lists.") }
        guard !isSaving else { throw SocialWireError.badResponse("A list is already being updated. Try again when it finishes.") }
        isSaving = true
        error = nil
        defer { if self.viewer == viewer { isSaving = false } }
        do {
            try await action(viewer)
            guard self.viewer == viewer else { throw ReadStateSyncFailure.accountChanged }
            await load(refresh: true)
        } catch {
            guard self.viewer == viewer else { throw ReadStateSyncFailure.accountChanged }
            let message = error.localizedDescription
            self.error = message.range(of: "scope|permission|unauthor|403|401", options: [.regularExpression, .caseInsensitive]) == nil
                ? message : "Sign out and sign in again to allow updating Lists on your PDS."
            throw SocialWireError.badResponse(self.error ?? message)
        }
    }
}
