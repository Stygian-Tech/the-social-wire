public struct SportsFeedDefinition: Codable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let kind: String
  public let entityIDs: [String]
  public let description: String
  public let groupPath: [String]?
  public init(id: String, title: String, kind: String, entityIDs: [String] = [], description: String, groupPath: [String]? = nil) {
    self.groupPath = groupPath
    self.id = id; self.title = title; self.kind = kind; self.entityIDs = entityIDs; self.description = description
  }
  public func matches(_ analysis: SportsArticleAnalysis) -> Bool {
    guard analysis.eligible, analysis.resolverVersion == SportsResolver.version else { return false }
    if id == "sports" { return true }
    let references = Set(entityIDs)
    return analysis.associations.contains { references.contains($0.entityID) && $0.confidence >= 0.9 && $0.resolverVersion == SportsResolver.version }
      || !references.isDisjoint(with: analysis.sportIDs) || !references.isDisjoint(with: analysis.competitionIDs)
  }
  public func matches(_ analysis: SportsArticleAnalysis, title: String, summary: String?) -> Bool { matches(analysis) }
}
