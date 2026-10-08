import Foundation

struct SportsNamedFeed: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let kind: String
    let entityIDs: [String]
    let description: String
    var groupPath: [String]? = nil

    static let all = SportsNamedFeed(id: "sports", title: "All Sports", kind: "global", entityIDs: [], description: "Global Sports Coverage")

    static func followedFeeds(_ feeds: [SportsNamedFeed], entities: [SportsEntity], selections: [SportsSelectionRecord]) -> [SportsNamedFeed] {
        let followed = Set(SportsEntity.followedIDs(selections: selections))
        let active = Set(entities.filter(\.active).map(\.id))
        return feeds.filter { feed in
            feed.kind != "global" && feed.entityIDs.count == 1
                && followed.contains(feed.entityIDs[0]) && active.contains(feed.entityIDs[0])
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func matchesSearch(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || title.localizedCaseInsensitiveContains(text) || description.localizedCaseInsensitiveContains(text) || (groupPath ?? []).contains { $0.localizedCaseInsensitiveContains(text) }
    }
}
