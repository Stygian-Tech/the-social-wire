public struct ThreadEntry: Sendable, Equatable, Identifiable {
    public var id: String { post.id }

    public let post: TimelinePost
    public let depth: Int
    public let isFocused: Bool
    public let replyingTo: TimelineAuthor?

    public init(
        post: TimelinePost,
        depth: Int,
        isFocused: Bool,
        replyingTo: TimelineAuthor? = nil
    ) {
        self.post = post
        self.depth = depth
        self.isFocused = isFocused
        self.replyingTo = replyingTo
    }
}
