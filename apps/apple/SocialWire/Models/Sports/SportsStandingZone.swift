import Foundation

struct SportsStandingZone: Codable, Equatable, Sendable {
    let kind: String
    let label: String
    let sourceURL: String

    var systemImage: String {
        switch kind {
        case "champion": "trophy.fill"
        case "promotion": "arrow.up.circle.fill"
        case "playoff": "flag.fill"
        case "relegation": "arrow.down.circle.fill"
        case "qualification": "checkmark.seal.fill"
        default: "info.circle"
        }
    }
}
