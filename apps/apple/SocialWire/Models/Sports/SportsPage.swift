import Foundation

struct SportsPage: Codable, Equatable, Sendable {
    let feedId: String
    let eventsEnabled: Bool?
    let items: [SportsFeedItem]
    let generationId: String
    let generatedAt: String
    let expiresAt: String
    let language: String
    let preferenceRevision: String
    let cursor: String?
    let source: String
    let degraded: Bool
}
