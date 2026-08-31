import Foundation

struct ReaderFeedPreferences: Codable, Equatable, Sendable {
    var visibleFeeds: [ReaderListSource]
    var feedsWithUnreadCounts: [ReaderListSource]
    var articleOpenMode: ArticleOpenMode

    static let defaults = ReaderFeedPreferences(
        visibleFeeds: ReaderListSource.preferenceCases,
        feedsWithUnreadCounts: ReaderListSource.preferenceCases,
        articleOpenMode: .original
    )

    init(
        visibleFeeds: [ReaderListSource],
        feedsWithUnreadCounts: [ReaderListSource],
        articleOpenMode: ArticleOpenMode = .original
    ) {
        let unique = visibleFeeds.reduce(into: [ReaderListSource]()) { result, source in
            if !result.contains(source) { result.append(source) }
        }
        let normalizedVisibleFeeds = unique.filter { ReaderListSource.preferenceCases.contains($0) }
        let effectiveVisibleFeeds = normalizedVisibleFeeds.isEmpty
            ? ReaderListSource.preferenceCases
            : normalizedVisibleFeeds
        self.visibleFeeds = effectiveVisibleFeeds
        self.feedsWithUnreadCounts = ReaderListSource.preferenceCases.filter { source in
            effectiveVisibleFeeds.contains(source)
                && feedsWithUnreadCounts.contains(source)
        }
        self.articleOpenMode = articleOpenMode
    }

    init(record: PreferencesRecord?) {
        let visibleFeeds = record?.visibleFeeds?.compactMap(ReaderListSource.init(preferenceKey:))
            ?? ReaderListSource.preferenceCases
        let feedsWithUnreadCounts: [ReaderListSource]
        if let stored = record?.feedsWithUnreadCounts {
            feedsWithUnreadCounts = stored.compactMap(ReaderListSource.init(preferenceKey:))
        } else {
            feedsWithUnreadCounts = (record?.showTopLevelFeedUnreadCounts ?? true)
                ? visibleFeeds
                : []
        }
        self.init(
            visibleFeeds: visibleFeeds,
            feedsWithUnreadCounts: feedsWithUnreadCounts,
            articleOpenMode: record?.rssArticleOpenMode.flatMap(ArticleOpenMode.init(rawValue:))
                ?? .original
        )
    }

    func showsUnreadCount(for source: ReaderListSource) -> Bool {
        visibleFeeds.contains(source) && feedsWithUnreadCounts.contains(source)
    }

    private enum CodingKeys: String, CodingKey {
        case visibleFeeds
        case feedsWithUnreadCounts
        case showTopLevelFeedUnreadCounts
        case articleOpenMode
        case rssArticleOpenMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let visibleFeeds = try container.decodeIfPresent([ReaderListSource].self, forKey: .visibleFeeds)
            ?? ReaderListSource.preferenceCases
        let feedsWithUnreadCounts: [ReaderListSource]
        if let stored = try container.decodeIfPresent(
            [ReaderListSource].self,
            forKey: .feedsWithUnreadCounts
        ) {
            feedsWithUnreadCounts = stored
        } else {
            let legacyShowCounts = try container.decodeIfPresent(
                Bool.self,
                forKey: .showTopLevelFeedUnreadCounts
            ) ?? true
            feedsWithUnreadCounts = legacyShowCounts ? visibleFeeds : []
        }
        let cachedArticleOpenMode = try container.decodeIfPresent(
            ArticleOpenMode.self,
            forKey: .articleOpenMode
        )
        let legacyArticleOpenMode = try container.decodeIfPresent(
            ArticleOpenMode.self,
            forKey: .rssArticleOpenMode
        )
        self.init(
            visibleFeeds: visibleFeeds,
            feedsWithUnreadCounts: feedsWithUnreadCounts,
            articleOpenMode: cachedArticleOpenMode ?? legacyArticleOpenMode ?? .original
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(visibleFeeds, forKey: .visibleFeeds)
        try container.encode(feedsWithUnreadCounts, forKey: .feedsWithUnreadCounts)
        try container.encode(!feedsWithUnreadCounts.isEmpty, forKey: .showTopLevelFeedUnreadCounts)
        try container.encode(articleOpenMode, forKey: .articleOpenMode)
    }
}

enum ReaderFeedPreferencesStorage {
    private static let prefix = "the-social-wire.feed-display.v1"

    static func load(viewerDid: String) -> ReaderFeedPreferences? {
        guard let data = UserDefaults.standard.data(forKey: "\(prefix):\(viewerDid)") else {
            return nil
        }
        return try? JSONDecoder().decode(ReaderFeedPreferences.self, from: data)
    }

    static func save(_ preferences: ReaderFeedPreferences, viewerDid: String) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: "\(prefix):\(viewerDid)")
    }
}
