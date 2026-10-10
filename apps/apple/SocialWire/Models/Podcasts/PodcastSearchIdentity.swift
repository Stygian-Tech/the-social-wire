import Foundation

struct PodcastSearchIdentity: Hashable, Sendable {
    let viewer: String?
    let query: String
    var scope: PodcastSearchScope = .library
    var kind = "all"
    var showId: String?

    var normalizedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isValid: Bool { viewer != nil && (2...200).contains(normalizedQuery.count) }

    func requestBody(cursor: String?) -> [String: JSONValue] {
        var body: [String: JSONValue] = ["query": .string(normalizedQuery), "scope": .string(scope.rawValue), "limit": .number(scope == .library ? 20 : 50)]
        if scope == .library {
            body["kind"] = .string(kind)
            if let cursor { body["cursor"] = .string(cursor) }
            if let showId { body["showId"] = .string(showId) }
        }
        return body
    }
}
