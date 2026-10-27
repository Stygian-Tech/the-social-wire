/// A conversation assembled from posts already loaded in the timeline.
public struct TimelineThreadGroup: Hashable, Sendable, Identifiable {
    public let id: String
    public let posts: [TimelinePost]
    public var hasMissingRoot: Bool { !posts.contains { $0.uri == id } }

    private init(rootURI: String, posts: [TimelinePost]) {
        id = rootURI
        self.posts = posts
    }

    /// Keeps conversations at their first feed occurrence, then orders each
    /// conversation from oldest to newest without changing equal-date order.
    public static func grouping(_ posts: [TimelinePost]) -> [Self] {
        var rootURIs: [String] = []
        var postsByRoot: [String: [(index: Int, post: TimelinePost)]] = [:]
        for (index, post) in posts.enumerated() {
            let rootURI = post.replyRootURI ?? post.uri
            if postsByRoot[rootURI] == nil { rootURIs.append(rootURI) }
            postsByRoot[rootURI, default: []].append((index, post))
        }
        return rootURIs.map { rootURI in
            let ordered = postsByRoot[rootURI, default: []].sorted {
                if $0.post.createdAt == $1.post.createdAt { return $0.index < $1.index }
                return $0.post.createdAt < $1.post.createdAt
            }
            return Self(rootURI: rootURI, posts: ordered.map(\.post))
        }
    }
}
