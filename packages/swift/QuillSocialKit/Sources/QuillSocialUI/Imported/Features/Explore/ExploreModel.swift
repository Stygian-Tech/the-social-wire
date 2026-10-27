#if os(iOS)
import Foundation
import Observation

@MainActor
@Observable
final class ExploreModel {
    struct Trend: Decodable, Identifiable, Sendable {
        let topic: String
        let displayName: String
        let description: String?
        let postCount: Int
        let category: String?
        let link: String?

        var id: String { topic }
    }

    struct Actor: Decodable, Identifiable, Sendable {
        let did: String
        let handle: String
        let displayName: String?
        let avatar: URL?

        var id: String { did }
    }

    struct Feed: Decodable, Identifiable, Sendable {
        struct Creator: Decodable, Sendable {
            let did: String
            let handle: String
            let displayName: String?
        }

        let uri: String
        let displayName: String
        let description: String?
        let avatar: URL?
        let creator: Creator
        let likeCount: Int?

        var id: String { uri }
    }

    private(set) var trends: [Trend] = []
    private(set) var suggestedFeeds: [Feed] = []
    private(set) var actors: [Actor] = []
    private(set) var matchingFeeds: [Feed] = []
    private(set) var isLoading = false
    private(set) var isSearching = false
    private(set) var errorMessage: String?

    private var searchTask: Task<Void, Never>?

    func load(using request: @escaping AppServices.AppViewRequest) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let trendsData = request("app.bsky.unspecced.getTrends", ["limit": "10"])
            async let feedsData = request("app.bsky.feed.getSuggestedFeeds", ["limit": "20"])
            let (resolvedTrends, resolvedFeeds) = try await (trendsData, feedsData)
            trends = try JSONDecoder().decode(TrendsResponse.self, from: resolvedTrends).trends
            suggestedFeeds = try JSONDecoder().decode(FeedsResponse.self, from: resolvedFeeds).feeds
        } catch {
            errorMessage = "Explore couldn't be loaded. Pull to try again."
        }
    }

    func search(_ query: String, using request: @escaping AppServices.AppViewRequest) {
        searchTask?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            actors = []
            matchingFeeds = []
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }

            do {
                async let actorData = request(
                    "app.bsky.actor.searchActors",
                    ["q": query, "limit": "20"]
                )
                async let feedData = request(
                    "app.bsky.feed.searchFeedGenerators",
                    ["q": query, "limit": "20"]
                )
                let (resolvedActors, resolvedFeeds) = try await (actorData, feedData)
                guard !Task.isCancelled else { return }
                actors = try JSONDecoder().decode(ActorsResponse.self, from: resolvedActors).actors
                matchingFeeds = try JSONDecoder().decode(FeedsResponse.self, from: resolvedFeeds).feeds
            } catch {
                guard !Task.isCancelled else { return }
                actors = []
                matchingFeeds = []
            }
            isSearching = false
        }
    }
}

private extension ExploreModel {
    struct TrendsResponse: Decodable {
        let trends: [Trend]
    }

    struct ActorsResponse: Decodable {
        let actors: [Actor]
    }

    struct FeedsResponse: Decodable {
        let feeds: [Feed]
    }
}

#endif
