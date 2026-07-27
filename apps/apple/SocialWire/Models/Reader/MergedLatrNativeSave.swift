import Foundation

struct MergedLatrNativeSave: Codable, Equatable, Hashable, Sendable {
    var savedAt: String
    var itemRkey: String
    var itemUri: String
    var subjectUri: String
    var state: String?
    var lastOpenedAt: String?
    var title: String?
    var excerpt: String?
    var url: String?
    var image: String?
    var site: String?
    var author: String?
    var publishedAt: String?
    var language: String?
    var linkedWebUrl: String?
    var rowSubtitle: String?
}
