import Foundation

struct WireFeedCatalog: Codable, Equatable, Sendable {
    var financeAvailable: Bool? = nil
    var sportsAvailable: Bool? = nil
    let enabled: Bool
    let available: Bool
    let title: String
    let subtitle: String
    let supportedLanguages: [String]
    let latestGenerationId: String?
    let generatedAt: String?

    var isAvailable: Bool { enabled && available }
}
