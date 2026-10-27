public struct TimelinePage: Sendable, Equatable {
    public let posts: [TimelinePost]
    public let cursor: String?

    public init(posts: [TimelinePost], cursor: String?) {
        self.posts = posts
        self.cursor = cursor
    }
}
