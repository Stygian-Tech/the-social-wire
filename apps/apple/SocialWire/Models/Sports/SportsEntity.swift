import Foundation

struct SportsEntity: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let kind: String
    let sportID: String?
    let competitionIDs: [String]
    let aliases: [String]
    let providerIDs: [String: String]
    var groupPath: [String]? = nil
    var abbreviation: String? = nil
    let active: Bool

    var displayName: String { Self.displayName(name, kind: kind) }

    static func displayName(_ name: String, kind: String) -> String {
        ["sport", "competition"].contains(kind) ? name.replacingOccurrences(of: " ", with: "\u{00A0}") : name
    }

    var isSelectable: Bool {
        active && ["sport", "competition", "classification", "team", "national-side", "ncaa-team", "athlete", "driver"].contains(kind)
    }

    static func preferredIDs(entities: [SportsEntity], selections: [SportsSelectionRecord], scope: String) -> [String] {
        let follows = Set(followedIDs(selections: selections))
        let allowedKinds: Set<String>?
        switch scope {
        case "sports": allowedKinds = ["sport"]
        case "leagues": allowedKinds = ["competition", "classification", "conference", "group", "league", "tournament"]
        case "teams": allowedKinds = ["team", "national-side", "ncaa-team"]
        case "all": allowedKinds = nil
        default: return []
        }
        return entities.filter { entity in
            entity.active && follows.contains(entity.id) && (allowedKinds?.contains(entity.kind) ?? true)
        }.map(\.id).sorted()
    }

    static func followedIDs(selections: [SportsSelectionRecord]) -> [String] {
        let muted = Set(selections.filter { $0.action == "mute" }.map(\.reference))
        return Set(selections.filter { $0.action == "follow" }.map(\.reference)).subtracting(muted).sorted()
    }

    static func followedTeamIDs(entities: [SportsEntity], selections: [SportsSelectionRecord]) -> [String] {
        let muted = Set(selections.filter { $0.action == "mute" }.map(\.reference))
        let followed = Set(selections.filter { $0.action == "follow" }.map(\.reference)).subtracting(muted)
        return entities.filter { $0.active && ["team", "national-side", "ncaa-team"].contains($0.kind) && followed.contains($0.id) }
            .map(\.id).sorted()
    }

    static func eventContext(competitionID: String, entities: [SportsEntity]) -> String? {
        guard let competition = entities.first(where: { $0.id == competitionID }) else { return nil }
        let sport = entities.first { $0.id == competition.sportID }
        return [sport?.displayName, competition.displayName].compactMap { $0 }.joined(separator: " · ")
    }

    var systemImage: String {
        switch kind {
        case "athlete", "driver": "person.fill"
        case "team", "national-side", "ncaa-team": "person.3.fill"
        case "competition", "league", "tournament": "trophy"
        default: "sportscourt"
        }
    }
}
