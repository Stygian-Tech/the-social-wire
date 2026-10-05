import Foundation

/// Provisional adaptation of loaded rows; the server owns the committed ordering.
enum SportsPersonalization {
    static func isPermitted(_ item: SportsFeedItem, selections: [SportsSelectionRecord]) -> Bool {
        let followed = Set(selections.filter { $0.action == "follow" }.map(\.reference))
        let muted = Set(selections.filter { $0.action == "mute" }.map(\.reference))
        let directKinds = Set(["team", "athlete", "driver", "national-side", "ncaa-team"])
        let ids = Set(item.associations.filter { $0.confidence >= 0.9 }.map(\.entityID))
        let entities = item.entities.filter { ids.contains($0.id) }
        let direct = entities.filter { directKinds.contains($0.kind) }
        if direct.contains(where: { muted.contains($0.id) }) { return false }
        let broad = Set((item.sportIDs ?? []) + (item.competitionIDs ?? []) + entities.flatMap { [$0.id] + $0.competitionIDs + [$0.sportID].compactMap { $0 } })
        guard !broad.isDisjoint(with: muted) else { return true }
        return direct.contains { followed.contains($0.id) }
    }

    static func reorder(_ items: [SportsFeedItem], selections: [SportsSelectionRecord], global: Bool) -> [SportsFeedItem] {
        let followed = Set(selections.filter { $0.action == "follow" }.map(\.reference))
        let permitted = items.filter { isPermitted($0, selections: selections) }
        guard global else { return permitted }
        var remaining = permitted.enumerated().sorted { lhs, rhs in
            func score(_ pair: (offset: Int, element: SportsFeedItem)) -> Double {
                let ids = Set(pair.element.associations.filter { $0.confidence >= 0.9 }.map(\.entityID))
                let entities = pair.element.entities.filter { ids.contains($0.id) }
                let direct = entities.contains { ["team", "athlete", "driver", "national-side", "ncaa-team"].contains($0.kind) && followed.contains($0.id) }
                let broadIDs = Set((pair.element.sportIDs ?? []) + (pair.element.competitionIDs ?? []) + entities.flatMap { $0.competitionIDs + [$0.sportID].compactMap { $0 } } + entities.filter { $0.kind == "classification" }.map(\.id))
                let broad = !broadIDs.isDisjoint(with: followed)
                let boost = min(0.35, (direct ? 0.25 : 0) + (broad ? 0.1 : 0))
                return (1 - Double(pair.offset) / Double(max(1, permitted.count)) * 0.5) * (1 + boost)
            }
            let left = score(lhs), right = score(rhs)
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
        var result: [SportsFeedItem] = []
        while !remaining.isEmpty {
            let index = result.count % 5 == 4 ? remaining.firstIndex(where: \.majorGlobal) ?? 0 : 0
            result.append(remaining.remove(at: index))
        }
        return result
    }
}
