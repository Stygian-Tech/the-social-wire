import Foundation

public struct AcceptedLabelers: Sendable {
    private static let blueskyModerationDID = "did:plc:ar7c4by46qjdydhdevvrndac"

    public let dids: [String]

    public init(preferencesData: Data, includesBluesky: Bool = true) throws {
        let response = try JSONDecoder().decode(PreferencesResponse.self, from: preferencesData)
        var seen = Set<String>()
        dids = Array(
            ((includesBluesky ? [Self.blueskyModerationDID] : []) + response.labelerDIDs)
                .filter { seen.insert($0).inserted }
                .prefix(20)
        )
    }
}

private extension AcceptedLabelers {
    struct PreferencesResponse: Decodable {
        let preferences: [Preference]

        var labelerDIDs: [String] {
            preferences
                .filter { $0.type == "app.bsky.actor.defs#labelersPref" }
                .flatMap { $0.labelers ?? [] }
                .map(\.did)
        }
    }

    struct Preference: Decodable {
        let type: String?
        let labelers: [Labeler]?

        private enum CodingKeys: String, CodingKey {
            case type = "$type"
            case labelers
        }
    }

    struct Labeler: Decodable {
        let did: String
    }
}
