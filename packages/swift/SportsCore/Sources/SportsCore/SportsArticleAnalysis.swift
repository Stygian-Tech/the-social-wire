public struct SportsArticleAnalysis: Codable, Equatable, Sendable {
  public let resolverVersion: String
  public let eligible: Bool
  public let materiality: String
  public let associations: [SportsAssociation]
  public let sportIDs: [String]
  public let competitionIDs: [String]
  public init(eligible: Bool, materiality: String, associations: [SportsAssociation], sportIDs: [String] = [],
    competitionIDs: [String] = [], resolverVersion: String = SportsResolver.version) {
    self.eligible = eligible; self.materiality = materiality; self.associations = associations
    self.sportIDs = sportIDs; self.competitionIDs = competitionIDs; self.resolverVersion = resolverVersion
  }
}
