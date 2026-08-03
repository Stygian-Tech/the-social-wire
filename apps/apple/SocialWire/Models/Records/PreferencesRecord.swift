import Foundation

struct PreferencesRecord: Codable, Equatable, Sendable {
    let type: String
    var readLaterService: String?
    var readLaterConnections: [String: ReadLaterConnectionPreferenceRecord]?
    var visibleFeeds: [String]?
    var showTopLevelFeedUnreadCounts: Bool?
    var feedsWithUnreadCounts: [String]?
    var rssArticleOpenMode: String?
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case readLaterService
        case readLaterConnections
        case visibleFeeds
        case showTopLevelFeedUnreadCounts
        case feedsWithUnreadCounts
        case rssArticleOpenMode
        case createdAt
        case updatedAt
    }
}
