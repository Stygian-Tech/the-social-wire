import Foundation

struct ReaderFeedPreferences: Codable, Equatable, Sendable {
    var visibleFeeds: [ReaderListSource]
    var showTopLevelFeedUnreadCounts: Bool

    static let defaults = ReaderFeedPreferences(
        visibleFeeds: ReaderListSource.allCases,
        showTopLevelFeedUnreadCounts: true
    )

    init(visibleFeeds: [ReaderListSource], showTopLevelFeedUnreadCounts: Bool) {
        let unique = visibleFeeds.reduce(into: [ReaderListSource]()) { result, source in
            if !result.contains(source) { result.append(source) }
        }
        self.visibleFeeds = unique.isEmpty ? ReaderListSource.allCases : unique
        self.showTopLevelFeedUnreadCounts = showTopLevelFeedUnreadCounts
    }

    init(record: PreferencesRecord?) {
        self.init(
            visibleFeeds: record?.visibleFeeds?.compactMap(ReaderListSource.init(preferenceKey:))
                ?? ReaderListSource.allCases,
            showTopLevelFeedUnreadCounts: record?.showTopLevelFeedUnreadCounts ?? true
        )
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
