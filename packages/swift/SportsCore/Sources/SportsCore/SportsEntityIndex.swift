import Foundation

/// Token preselection keeps roster-scale resolution bounded by article tokens, not every athlete.
public struct SportsEntityIndex: Sendable {
  public let entities: [SportsEntity]
  let byFirstToken: [String: [Int]]
  public init(entities: [SportsEntity]) {
    self.entities = entities
    var index: [String: Set<Int>] = [:]
    for (offset, entity) in entities.enumerated() where entity.active {
      for alias in [entity.name] + entity.aliases {
        if let token = SportsResolver.normalize(alias).split(separator: " ").first {
          index[String(token), default: []].insert(offset)
        }
      }
    }
    self.byFirstToken = index.mapValues { $0.sorted() }
  }
}
