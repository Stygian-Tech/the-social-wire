import Foundation

struct MergedLatrExternalSave: Codable, Equatable, Hashable, Sendable {
    var normalizedUrl: String
    var url: String
    var savedAt: String
    var externalRkey: String
    var itemRkey: String
    var externalUri: String
    var itemUri: String
    var subjectUri: String
    var state: String?
    var lastOpenedAt: String?
    var title: String?
    var excerpt: String?
    var image: String?
    var site: String?
    var author: String?
    var publishedAt: String?
    var language: String?
    var linkedWebUrl: String?
    var rowSubtitle: String?
    var tags: [String]? = nil
}
