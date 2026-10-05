import Foundation

struct PodcastSearchIdentity: Hashable, Sendable {
    let viewer: String?
    let query: String
    var kind = "all"
    var showId: String?

    var normalizedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isValid: Bool { viewer != nil && (2...200).contains(normalizedQuery.count) }
}
