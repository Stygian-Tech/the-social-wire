import Foundation
import Observation

@MainActor
@Observable
final class SocialTimelineModel {
    private let client: SocialWireSocialClient
    private(set) var posts: [SocialPost] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var cursor: String?
    private(set) var error: String?
    var feedURI: String?
    var listURI: String?

    init(client: SocialWireSocialClient) { self.client = client }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let page = if let listURI { try await client.listFeed(listURI) } else { try await client.timeline(feed: feedURI) }
            try Task.checkCancellation()
            posts = page.items
            cursor = page.cursor
        } catch is CancellationError { } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMore(after postID: String) async {
        guard posts.last?.id == postID, let cursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = if let listURI { try await client.listFeed(listURI, cursor: cursor) } else { try await client.timeline(cursor: cursor, feed: feedURI) }
            let known = Set(posts.map(\.id))
            posts.append(contentsOf: page.items.filter { !known.contains($0.id) })
            self.cursor = page.cursor
        } catch is CancellationError { } catch {
            self.error = error.localizedDescription
        }
    }

    func toggleLike(_ post: SocialPost) async {
        guard let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
        let previous = posts[index]
        if let recordURI = post.viewerLikeURI {
            posts[index].viewerLikeURI = nil
            posts[index].likeCount = max(0, posts[index].likeCount - 1)
            do { try await client.deleteRecord(uri: recordURI, collection: "app.bsky.feed.like") }
            catch { posts[index] = previous; self.error = error.localizedDescription }
        } else {
            posts[index].viewerLikeURI = "pending"
            posts[index].likeCount += 1
            do { posts[index].viewerLikeURI = try await client.like(post) }
            catch { posts[index] = previous; self.error = error.localizedDescription }
        }
    }

    func toggleRepost(_ post: SocialPost) async {
        guard let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
        let previous = posts[index]
        if let recordURI = post.viewerRepostURI {
            posts[index].viewerRepostURI = nil
            posts[index].repostCount = max(0, posts[index].repostCount - 1)
            do { try await client.deleteRecord(uri: recordURI, collection: "app.bsky.feed.repost") }
            catch { posts[index] = previous; self.error = error.localizedDescription }
        } else {
            posts[index].viewerRepostURI = "pending"
            posts[index].repostCount += 1
            do { posts[index].viewerRepostURI = try await client.repost(post) }
            catch { posts[index] = previous; self.error = error.localizedDescription }
        }
    }
}
