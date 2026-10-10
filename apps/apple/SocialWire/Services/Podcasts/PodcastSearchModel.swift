import Foundation
import Observation

@MainActor
@Observable
final class PodcastSearchModel {
    private(set) var identity: PodcastSearchIdentity?
    private(set) var candidates: [PodcastDirectoryCandidate] = []
    private(set) var shows: [PodcastShow] = []
    private(set) var episodes: [PodcastEpisode] = []
    private(set) var loading = false
    private(set) var hasMore = false
    private(set) var error: String?
    private var cursor: String?
    private var revision = 0

    func search(_ identity: PodcastSearchIdentity, debounce: Bool = true,
                fetch: (PodcastSearchIdentity, String?) async throws -> PodcastSearchPage) async {
        revision += 1
        let revision = revision
        self.identity = identity
        candidates = []
        shows = []
        episodes = []
        cursor = nil
        hasMore = false
        error = nil
        loading = identity.isValid
        guard identity.isValid else { return }
        defer { if self.revision == revision { loading = false } }
        do {
            if debounce { try await Task.sleep(for: .milliseconds(300)) }
            try Task.checkCancellation()
            let page = try await fetch(identity, nil)
            guard !Task.isCancelled, self.revision == revision, self.identity == identity else { return }
            append(page)
        } catch is CancellationError { } catch {
            guard !Task.isCancelled, self.revision == revision else { return }
            self.error = identity.scope == .library ? "Could Not Search Your Library. Try Again." : "Could Not Search Podcast Index. Try Again."
        }
    }

    func loadMore(fetch: (PodcastSearchIdentity, String?) async throws -> PodcastSearchPage) async {
        guard let identity, identity.isValid, hasMore, !loading, let cursor else { return }
        let revision = revision
        loading = true
        error = nil
        defer { if self.revision == revision { loading = false } }
        do {
            let page = try await fetch(identity, cursor)
            guard !Task.isCancelled, self.revision == revision, self.identity == identity else { return }
            append(page)
        } catch is CancellationError { } catch {
            guard !Task.isCancelled, self.revision == revision else { return }
            self.error = "Could Not Load More Results. Try Again."
        }
    }

    private func append(_ page: PodcastSearchPage) {
        for candidate in page.candidates ?? [] where !candidates.contains(where: { $0.id == candidate.id && $0.provider == candidate.provider }) { candidates.append(candidate) }
        for show in page.shows where !shows.contains(where: { $0.id == show.id }) { shows.append(show) }
        for episode in page.episodes where !episodes.contains(where: { $0.id == episode.id }) { episodes.append(episode) }
        cursor = page.cursor
        hasMore = page.hasMore && page.cursor != nil
    }
}
