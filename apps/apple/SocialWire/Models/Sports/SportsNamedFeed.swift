import Foundation

struct SportsNamedFeed: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let kind: String
    let entityIDs: [String]
    let description: String
    var groupPath: [String]? = nil

    static let all = SportsNamedFeed(id: "sports", title: "All Sports", kind: "global", entityIDs: [], description: "Global Sports Coverage")

    func matchesSearch(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || title.localizedCaseInsensitiveContains(text) || description.localizedCaseInsensitiveContains(text) || (groupPath ?? []).contains { $0.localizedCaseInsensitiveContains(text) }
    }
}
