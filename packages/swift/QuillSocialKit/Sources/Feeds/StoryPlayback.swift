/// A snapshot of active stories in rail order, oldest first within each person.
public struct StoryPlayback: Sendable {
    public struct Page: Identifiable, Sendable {
        public let author: StoryAuthor
        public let story: StoryRecord
        public let isCurrentUser: Bool
        public var id: String { story.id }
    }
    public let pages: [Page]
    public private(set) var index: Int
    public var current: Page? { pages.indices.contains(index) ? pages[index] : nil }

    public init(items: [StoryFeedItem], startingAuthorID: String) {
        pages = items.flatMap { item in
            item.stories.sorted { $0.createdAt < $1.createdAt }.map {
                Page(author: item.author, story: $0, isCurrentUser: item.isCurrentUser)
            }
        }
        index = pages.firstIndex { $0.author.id == startingAuthorID } ?? 0
    }

    /// Returns false at the end so the presentation can dismiss.
    public mutating func next() -> Bool {
        guard pages.indices.contains(index + 1) else { return false }
        index += 1
        return true
    }

    public mutating func previous() { index = max(0, index - 1) }
    public mutating func select(id: String) {
        if let target = pages.firstIndex(where: { $0.id == id }) { index = target }
    }
}
