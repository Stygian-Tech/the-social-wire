public struct StoryFeedItem: Hashable, Sendable, Identifiable {
    public let author: StoryAuthor
    public let stories: [StoryRecord]
    public let isCurrentUser: Bool

    public var id: String { author.id }

    public init(author: StoryAuthor, stories: [StoryRecord], isCurrentUser: Bool) {
        self.author = author
        self.stories = stories
        self.isCurrentUser = isCurrentUser
    }
}
