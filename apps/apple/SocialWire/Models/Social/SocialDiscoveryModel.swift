import Foundation
import Observation

@MainActor
@Observable
final class SocialDiscoveryModel {
    private let client: SocialWireSocialClient
    var query = ""
    private(set) var actors: [SocialAuthor] = []
    private(set) var posts: [SocialPost] = []
    private(set) var isLoading = false
    private(set) var error: String?

    init(client: SocialWireSocialClient) { self.client = client }

    func search() async {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 2 else { actors = []; posts = []; return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            async let actorPage = client.searchActors(query: normalized)
            async let postPage = client.searchPosts(query: normalized)
            let result = try await (actorPage, postPage)
            try Task.checkCancellation()
            actors = result.0.items
            posts = result.1.items
        } catch is CancellationError { } catch {
            self.error = error.localizedDescription
        }
    }
}
