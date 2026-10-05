import Foundation

struct SportsStandingRow: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let entityID: String?
    let name: String
    let rank: Int?
    let played: Int?
    let won: Int?
    let drawn: Int?
    let lost: Int?
    let points: String?
    let group: String?
    var zone: SportsStandingZone? = nil
}
