import Foundation

@MainActor
enum PodcastOPMLImportBatch {
    static func run(_ feeds: [OPMLFeed], privateFeeds: Bool, viewer: String,
                    existingFeedURLs: Set<String>, existingIDs: Set<String>,
                    currentViewer: () -> String?,
                    resolve: (OPMLFeed, Bool) async throws -> PodcastShow,
                    subscribe: (PodcastShow) async throws -> Void,
                    progress: (Int, Int) -> Void) async -> [OPMLImportFailure] {
        var knownURLs = existingFeedURLs
        var knownIDs = existingIDs
        var failures: [OPMLImportFailure] = []
        for (index, feed) in feeds.enumerated() {
            guard !Task.isCancelled, currentViewer() == viewer else {
                failures += feeds[index...].map { OPMLImportFailure(feed: $0, message: "Import Stopped Because the Account Changed or Import Was Cancelled.") }
                break
            }
            if knownURLs.contains(feed.feedURL) { progress(index + 1, feeds.count); continue }
            do {
                let show = try await resolve(feed, privateFeeds)
                guard !Task.isCancelled, currentViewer() == viewer else { throw CancellationError() }
                if !privateFeeds, !knownIDs.contains(show.id) { try await subscribe(show) }
                guard currentViewer() == viewer else { throw CancellationError() }
                knownIDs.insert(show.id)
                knownURLs.insert(feed.feedURL)
            } catch is CancellationError {
                failures += feeds[index...].map { OPMLImportFailure(feed: $0, message: "Import Stopped Because the Account Changed or Import Was Cancelled.") }
                break
            } catch {
                failures.append(OPMLImportFailure(feed: feed, message: "Could Not Import This Podcast. Retry, or Check the Private Feeds Option for Subscriber Feeds."))
            }
            progress(index + 1, feeds.count)
        }
        return failures
    }
}
