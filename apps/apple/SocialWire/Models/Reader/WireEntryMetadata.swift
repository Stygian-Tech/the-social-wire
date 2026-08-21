import Foundation

struct WireEntryMetadata: Codable, Equatable, Sendable {
    let source: WireFeedSource
    let reasons: [String]
    let provenance: [String]
    let representativeUri: String?

    var reasonLabels: [String] {
        reasons.compactMap(Self.reasonLabel)
    }

    var primaryReasonLabel: String? {
        reasonLabels.first
    }

    private static func reasonLabel(_ reason: String) -> String? {
        switch reason {
        case "widely_discussed": "Widely Discussed"
        case "breaking_story": "Breaking Story"
        case "shared_across_communities": "Shared Across Communities"
        case "fresh_publication": "Fresh Publication"
        case "resurfacing": "Resurfacing"
        default: nil
        }
    }
}
