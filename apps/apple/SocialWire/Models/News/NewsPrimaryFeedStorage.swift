import Foundation

enum NewsPrimaryFeedStorage {
    private static let configuredPrefix = "the-social-wire.primary-feeds.v1"
    private static let lastPrefix = "the-social-wire.last-primary-feed.v1"

    static func configuredFeeds(viewerDID: String) -> [NewsPrimaryFeed] {
        guard let data = UserDefaults.standard.data(forKey: key(prefix: configuredPrefix, viewerDID: viewerDID)),
              let feeds = try? JSONDecoder().decode([NewsPrimaryFeed].self, from: data)
        else {
            return NewsPrimaryFeed.defaultFeeds
        }
        return normalized(feeds)
    }

    static func saveConfiguredFeeds(_ feeds: [NewsPrimaryFeed], viewerDID: String) {
        guard let data = try? JSONEncoder().encode(normalized(feeds)) else { return }
        UserDefaults.standard.set(data, forKey: key(prefix: configuredPrefix, viewerDID: viewerDID))
    }

    static func lastFeed(viewerDID: String) -> NewsPrimaryFeed? {
        UserDefaults.standard.string(forKey: key(prefix: lastPrefix, viewerDID: viewerDID))
            .flatMap(NewsPrimaryFeed.init(rawValue:))
    }

    static func saveLastFeed(_ feed: NewsPrimaryFeed, viewerDID: String) {
        UserDefaults.standard.set(feed.rawValue, forKey: key(prefix: lastPrefix, viewerDID: viewerDID))
    }

    private static func normalized(_ feeds: [NewsPrimaryFeed]) -> [NewsPrimaryFeed] {
        let unique = feeds.reduce(into: [NewsPrimaryFeed]()) { result, feed in
            if !result.contains(feed) {
                result.append(feed)
            }
        }
        return Array(unique.prefix(4))
    }

    private static func key(prefix: String, viewerDID: String) -> String {
        "\(prefix).\(viewerDID)"
    }
}
