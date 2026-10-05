import Foundation

struct SportsCatalog: Codable, Sendable {
    let enabled: Bool
    let available: Bool
    let eventsEnabled: Bool
    let feeds: [SportsNamedFeed]
    let entities: [SportsEntity]
    let version: String
}
