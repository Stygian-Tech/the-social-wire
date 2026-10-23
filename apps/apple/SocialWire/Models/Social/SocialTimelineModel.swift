import Foundation
import Observation

@MainActor
@Observable
final class SocialTimelineModel {
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var pendingLikes = Set<String>()
    @ObservationIgnored private var pendingReposts = Set<String>()
    private let client: SocialWireSocialClient
    private(set) var posts: [SocialPost] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var cursor: String?
    private(set) var error: String?
    var feedURI: String?
    var listURI: String?

    init(client: SocialWireSocialClient) { self.client = client }

    func reset() {
        generation = UUID()
        pendingLikes = []
        pendingReposts = []
        posts = []
        cursor = nil
        feedURI = nil
        listURI = nil
        isLoading = false
        isLoadingMore = false
        error = nil
    }

    func refresh() async {
        let current = generation
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { if generation == current { isLoading = false } }
        do {
            let page = if let listURI { try await client.listFeed(listURI) } else { try await client.timeline(feed: feedURI) }
            try Task.checkCancellation()
            guard generation == current else { return }
            posts = page.items
            cursor = page.cursor
        } catch is CancellationError { } catch {
            guard generation == current else { return }
            self.error = error.localizedDescription
        }
    }

    func loadMore(after postID: String) async {
        let current = generation
        guard posts.last?.id == postID, let cursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { if generation == current { isLoadingMore = false } }
        do {
            let page = if let listURI { try await client.listFeed(listURI, cursor: cursor) } else { try await client.timeline(cursor: cursor, feed: feedURI) }
            guard generation == current else { return }
            let known = Set(posts.map(\.id))
            posts.append(contentsOf: page.items.filter { !known.contains($0.id) })
            self.cursor = page.cursor
        } catch is CancellationError { } catch {
            guard generation == current else { return }
            self.error = error.localizedDescription
        }
    }

    func toggleLike(_ post: SocialPost) async {
        let current = generation
        guard !pendingLikes.contains(post.id), let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
        pendingLikes.insert(post.id)
        defer { if generation == current { pendingLikes.remove(post.id) } }
        let previous = posts[index]
        posts[index].viewerLikeURI = post.viewerLikeURI == nil ? "pending" : nil
        posts[index].likeCount = max(0, posts[index].likeCount + (post.viewerLikeURI == nil ? 1 : -1))
        do {
            let uri: String?
            if let recordURI = post.viewerLikeURI {
                try await client.deleteRecord(uri: recordURI, collection: "app.bsky.feed.like")
                uri = nil
            } else { uri = try await client.like(post) }
            guard generation == current, let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
            posts[index].viewerLikeURI = uri
        } catch {
            guard generation == current, let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
            posts[index] = previous
            self.error = error.localizedDescription
        }
    }

    func toggleRepost(_ post: SocialPost) async {
        let current = generation
        guard !pendingReposts.contains(post.id), let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
        pendingReposts.insert(post.id)
        defer { if generation == current { pendingReposts.remove(post.id) } }
        let previous = posts[index]
        posts[index].viewerRepostURI = post.viewerRepostURI == nil ? "pending" : nil
        posts[index].repostCount = max(0, posts[index].repostCount + (post.viewerRepostURI == nil ? 1 : -1))
        do {
            let uri: String?
            if let recordURI = post.viewerRepostURI {
                try await client.deleteRecord(uri: recordURI, collection: "app.bsky.feed.repost")
                uri = nil
            } else { uri = try await client.repost(post) }
            guard generation == current, let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
            posts[index].viewerRepostURI = uri
        } catch {
            guard generation == current, let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
            posts[index] = previous
            self.error = error.localizedDescription
        }
    }
}
