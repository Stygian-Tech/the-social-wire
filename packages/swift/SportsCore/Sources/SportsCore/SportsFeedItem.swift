import WireCore

public struct SportsFeedItem: Codable, Equatable, Sendable {
  public let story: WireFeedItem
  public let entities: [SportsEntity]
  public let associations: [SportsAssociation]
  public let sportIDs: [String]
  public let competitionIDs: [String]
  public let materiality: String
  public let majorGlobal: Bool
  public init(story: WireFeedItem, entities: [SportsEntity], associations: [SportsAssociation] = [],
    materiality: String = "reporting", majorGlobal: Bool = false, sportIDs: [String] = [], competitionIDs: [String] = []) {
    self.story = story; self.entities = entities; self.associations = associations
    self.sportIDs = sportIDs; self.competitionIDs = competitionIDs; self.materiality = materiality; self.majorGlobal = majorGlobal
  }
}
