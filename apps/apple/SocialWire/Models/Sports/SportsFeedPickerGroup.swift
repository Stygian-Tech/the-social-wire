import Foundation

struct SportsFeedPickerGroup: Identifiable {
    let id: String
    let title: String
    let feeds: [SportsNamedFeed]

    static func make(feeds: [SportsNamedFeed], selectedID: String, query: String, activeEntityIDs: Set<String>, aliasesByEntityID: [String: [String]] = [:]) -> [SportsFeedPickerGroup] {
        let kinds = ["global", "sport", "competition", "classification", "team", "national-side", "ncaa-team", "athlete", "driver"]
        let labels = ["global": "Sports", "sport": "Sports", "competition": "Competitions", "classification": "Classes and Medley Indices", "team": "Teams", "national-side": "National Sides", "ncaa-team": "NCAA Teams", "athlete": "Athletes", "driver": "Drivers"]
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var grouped: [String: [SportsNamedFeed]] = [:]
        var titles: [String: String] = [:]
        for feed in feeds {
            guard let label = labels[feed.kind] else { continue }
            let selected = feed.id == selectedID
            let active = feed.entityIDs.isEmpty || feed.entityIDs.allSatisfy(activeEntityIDs.contains)
            let personVisible = !["athlete", "driver"].contains(feed.kind) || search.count >= 2
            let path = (feed.groupPath ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            let text = ([feed.title, feed.description] + path + feed.entityIDs.flatMap { aliasesByEntityID[$0] ?? [] }).joined(separator: " ")
            guard selected || (active && personVisible && (feed.kind == "global" || search.isEmpty || text.localizedCaseInsensitiveContains(search))) else { continue }
            // Length-prefixed components avoid collisions when provider labels contain separators.
            let key = ([feed.kind] + path).map { "\($0.utf8.count):\($0)" }.joined()
            grouped[key, default: []].append(feed)
            titles[key] = (path.first == label ? path : [label] + path).joined(separator: " › ")
        }
        return grouped.map { SportsFeedPickerGroup(id: $0.key, title: titles[$0.key] ?? "Sports", feeds: $0.value) }.sorted { lhs, rhs in
            let leftKind = kinds.firstIndex(of: lhs.feeds[0].kind) ?? kinds.count
            let rightKind = kinds.firstIndex(of: rhs.feeds[0].kind) ?? kinds.count
            return leftKind == rightKind ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending : leftKind < rightKind
        }
    }
}
