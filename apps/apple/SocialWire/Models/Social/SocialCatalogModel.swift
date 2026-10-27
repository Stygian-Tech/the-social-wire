import Foundation
import Observation

@MainActor
@Observable
final class SocialCatalogModel {
    private let client: SocialWireSocialClient
    private(set) var feeds: [SocialFeedSummary] = []
    private(set) var lists: [SocialListSummary] = []
    private(set) var bookmarks: [SocialPost] = []
    private(set) var isLoading = false
    private(set) var error: String?
    var feedQuery = ""

    init(client: SocialWireSocialClient) { self.client = client }
    func loadFeeds() async { await load { self.feeds = try await self.client.suggestedFeeds(query: self.feedQuery).items } }
    func loadLists() async { await load { self.lists = try await self.client.lists().items } }
    func loadBookmarks() async { await load { self.bookmarks = try await self.client.bookmarks().items } }
    func saveList(_ list: SocialListSummary?, name: String, description: String, memberDID: String) async -> Bool {
        do {
            if let list {
                try await client.updateList(list, name: name, description: description)
                if !memberDID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try await client.addListMember(listURI: list.uri, did: memberDID) }
            } else { try await client.createList(name: name, description: description) }
            await loadLists(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func deleteList(_ list: SocialListSummary) async {
        do { try await client.deleteList(list); lists.removeAll { $0.id == list.id } }
        catch { self.error = error.localizedDescription }
    }
    private func load(_ operation: () async throws -> Void) async {
        isLoading = true; error = nil; defer { isLoading = false }
        do { try await operation() } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }
}
