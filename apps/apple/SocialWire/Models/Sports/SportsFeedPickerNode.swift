import Foundation

/// A presentation tree: canonical references select feeds; reviewed labels organize browsing.
struct SportsFeedPickerNode: Identifiable, Sendable {
    let id: String
    let title: String
    let kind: String
    var feed: SportsNamedFeed?
    var children: [SportsFeedPickerNode] = []

    static func make(feeds: [SportsNamedFeed], entities: [SportsEntity]) -> [SportsFeedPickerNode] {
        let catalog = Dictionary(entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let feedByEntity = Dictionary(feeds.compactMap { feed in
            feed.entityIDs.count == 1 ? (feed.entityIDs[0], feed) : nil
        }, uniquingKeysWith: { first, _ in first })
        let sportsByName = Dictionary(entities.filter { $0.active && $0.kind == "sport" }.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let categoryLabels: Set<String> = ["Sports", "Competitions", "Teams", "National Sides", "NCAA Teams", "Programs", "Athletes", "Drivers"]
        var root = SportsFeedPickerNode(id: "root", title: "Sports Feeds", kind: "global")
        for feed in feeds {
            if feed.kind == "global" {
                root.children.append(.init(id: "feed:\(feed.id)", title: feed.title, kind: feed.kind, feed: feed))
                continue
            }
            guard let entityID = feed.entityIDs.first, let entity = catalog[entityID], entity.isSelectable else { continue }
            let canonicalSport = entity.kind == "sport" ? entity : entity.sportID.flatMap { catalog[$0] }
            let reviewed = feed.groupPath ?? entity.groupPath ?? []
            let firstReviewedLabel = reviewed.first { !categoryLabels.contains($0) }
            // Reviewed umbrella paths organize browsing without replacing canonical sport references.
            let sport = firstReviewedLabel.flatMap { sportsByName[$0] } ?? canonicalSport
            let sportKey = sport.map { "sport:\($0.id)" } ?? "other-sports"
            let sportTitle = sport?.name ?? "Other Sports"
            var components: [(id: String, title: String, kind: String, feed: SportsNamedFeed?)] = [
                (sportKey, sportTitle, "sport", sport.flatMap { feedByEntity[$0.id] })
            ]
            if entity.kind != "sport" || entity.id != sport?.id {
                var path = reviewed.filter { label in
                    !categoryLabels.contains(label) && label != sportTitle
                        && !(reviewed.contains("NCAA") && sportTitle == "American Football" && label == "Football")
                }
                if path.isEmpty, let competition = entity.competitionIDs.first.flatMap({ catalog[$0] }), competition.active {
                    path = [competition.name]
                }
                if path.last == feed.title { path.removeLast() }
                for label in path {
                    // Match only related competitions, never unrelated entities sharing a display name.
                    let competition = entity.competitionIDs.compactMap { catalog[$0] }.first { $0.active && $0.name == label }
                    let discipline = sportsByName[label]
                    let key = discipline.map { "sport:\($0.id)" } ?? competition.map { "competition:\($0.id)" } ?? "group:\(label.utf8.count):\(label)"
                    let related = discipline ?? competition
                    components.append((key, label, related?.kind ?? "group", related.flatMap { feedByEntity[$0.id] }))
                }
                let leafKey = entity.kind == "sport" ? "sport:\(entity.id)" : entity.kind == "competition" ? "competition:\(entity.id)" : "feed:\(feed.id)"
                components.append((leafKey, feed.title, feed.kind, feed))
            }
            root.insert(components[...])
        }
        return root.sorted().children
    }

    func find(_ identifier: String) -> SportsFeedPickerNode? {
        if id == identifier { return self }
        return children.lazy.compactMap { $0.find(identifier) }.first
    }

    private mutating func insert(_ components: ArraySlice<(id: String, title: String, kind: String, feed: SportsNamedFeed?)>) {
        guard let component = components.first else { return }
        let identifier = "\(id)/\(component.id.utf8.count):\(component.id)"
        let index: Int
        if let existing = children.firstIndex(where: { $0.id == identifier }) {
            index = existing
            if let feed = component.feed { children[index].feed = feed }
        } else {
            children.append(.init(id: identifier, title: component.title, kind: component.kind, feed: component.feed))
            index = children.count - 1
        }
        children[index].insert(components.dropFirst())
    }

    private func sorted() -> SportsFeedPickerNode {
        var result = self
        result.children = children.map { $0.sorted() }.sorted { lhs, rhs in
            if lhs.kind == "global" || rhs.kind == "global" { return lhs.kind == "global" && rhs.kind != "global" }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        return result
    }
}
