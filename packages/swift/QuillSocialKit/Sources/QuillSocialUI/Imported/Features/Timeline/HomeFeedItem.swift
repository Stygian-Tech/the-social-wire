#if os(iOS)
import Feeds

struct HomeFeedItem: Identifiable, Hashable {
    static let home = HomeFeedItem(id: "home", title: "Following", feed: nil)

    let id: String
    let title: String
    let feed: PinnedFeed?

    init(feed: PinnedFeed) {
        id = feed.uri.description
        title = feed.name
        self.feed = feed
    }

    private init(id: String, title: String, feed: PinnedFeed?) {
        self.id = id
        self.title = title
        self.feed = feed
    }
}

#endif
