import Foundation

struct OPMLImportFailure: Identifiable, Equatable, Sendable {
    let feed: OPMLFeed
    let message: String

    var id: String { feed.id }
}
