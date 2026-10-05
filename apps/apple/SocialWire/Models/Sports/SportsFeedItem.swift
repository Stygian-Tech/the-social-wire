import Foundation

struct SportsFeedItem: Codable, Equatable, Identifiable, Sendable {
    let story: WireFeedItem
    let entities: [SportsEntity]
    let associations: [SportsAssociation]
    var sportIDs: [String]? = nil
    var competitionIDs: [String]? = nil
    let materiality: String
    let majorGlobal: Bool
    var id: String { story.itemId }
}
