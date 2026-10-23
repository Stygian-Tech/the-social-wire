import Foundation
import Observation

@MainActor
@Observable
final class SocialDiscoveryModel {
    @ObservationIgnored private var generation = UUID()
    private let client: SocialWireSocialClient
    var query = ""
    private(set) var actors: [SocialAuthor] = []
    private(set) var posts: [SocialPost] = []
    private(set) var isLoading = false
    private(set) var error: String?

    init(client: SocialWireSocialClient) { self.client = client }

    func reset() {
        generation = UUID()
        query = ""
        actors = []
        posts = []
        isLoading = false
        error = nil
    }

    func search() async {
        generation = UUID()
        let current = generation
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 2 else {
            actors = []
            posts = []
            isLoading = false
            error = nil
            return
        }
        isLoading = true
        error = nil
        defer { if generation == current { isLoading = false } }
        do {
            async let actorPage = client.searchActors(query: normalized)
            async let postPage = client.searchPosts(query: normalized)
            let result = try await (actorPage, postPage)
            try Task.checkCancellation()
            guard generation == current else { return }
            actors = result.0.items
            posts = result.1.items
        } catch is CancellationError { } catch {
            guard generation == current else { return }
            self.error = error.localizedDescription
        }
    }
}
