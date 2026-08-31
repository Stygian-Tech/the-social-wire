import Foundation

struct OPMLFeed: Identifiable, Equatable, Sendable {
    let title: String
    let feedURL: String
    let siteURL: String?

    var id: String { feedURL }
}
