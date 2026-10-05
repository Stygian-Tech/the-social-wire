import Foundation

struct SportsAssociation: Codable, Equatable, Sendable {
    let entityID: String
    let confidence: Double
    let evidence: [String]
    let prominence: Double
    let resolverVersion: String
}
