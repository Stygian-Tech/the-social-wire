import Foundation
import Observation

@MainActor
@Observable
final class SocialCatalogModel {
    @ObservationIgnored private var generation = UUID()
    private let client: SocialWireSocialClient
    private(set) var feeds: [SocialFeedSummary] = []
    private(set) var lists: [SocialListSummary] = []
    private(set) var bookmarks: [SocialPost] = []
    private(set) var isLoading = false
    private(set) var error: String?
    var feedQuery = ""

    init(client: SocialWireSocialClient) { self.client = client }

    func reset() {
        generation = UUID()
        feeds = []
        lists = []
        bookmarks = []
        feedQuery = ""
        isLoading = false
        error = nil
    }
    func loadFeeds() async {
        await load(fetch: { try await self.client.suggestedFeeds(query: self.feedQuery).items }) { self.feeds = $0 }
    }

    func loadLists() async {
        await load(fetch: { try await self.client.lists().items }) { self.lists = $0 }
    }

    func loadBookmarks() async {
        await load(fetch: { try await self.client.bookmarks().items }) { self.bookmarks = $0 }
    }

    func saveList(_ list: SocialListSummary?, name: String, description: String, memberDID: String) async -> Bool {
        let current = generation
        do {
            if let list {
                try await client.updateList(list, name: name, description: description)
                guard generation == current else { return false }
                if !memberDID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try await client.addListMember(listURI: list.uri, did: memberDID)
                }
            } else { try await client.createList(name: name, description: description) }
            guard generation == current else { return false }
            await loadLists()
            return generation == current
        } catch {
            if generation == current { self.error = error.localizedDescription }
            return false
        }
    }

    func deleteList(_ list: SocialListSummary) async {
        let current = generation
        do {
            try await client.deleteList(list)
            guard generation == current else { return }
            lists.removeAll { $0.id == list.id }
        } catch { if generation == current { self.error = error.localizedDescription } }
    }

    private func load<Value>(fetch: () async throws -> Value, apply: (Value) -> Void) async {
        let current = generation
        isLoading = true
        error = nil
        defer { if generation == current { isLoading = false } }
        do {
            let value = try await fetch()
            guard generation == current, !Task.isCancelled else { return }
            apply(value)
        } catch is CancellationError { } catch {
            if generation == current { self.error = error.localizedDescription }
        }
    }
}
