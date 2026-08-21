import Foundation

struct WireFeedPage: Codable, Equatable, Sendable {
    let generationId: String
    let generatedAt: String
    let language: String
    let cursor: String?
    let source: String
    let degraded: Bool
    let items: [WireFeedItem]

    var notice: String? {
        switch source {
        case "stale_generation": "Showing a recently generated edition."
        case "simplified_fallback": "Showing a simplified edition."
        default: degraded ? "The Wire is using a degraded feed." : nil
        }
    }
}
