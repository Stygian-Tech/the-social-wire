import Crypto
import Foundation

public struct SportsCatalogSnapshot: Codable, Equatable, Sendable {
  public let version: String
  public let generatedAt: Date
  public let entities: [SportsEntity]
  public static func revision(entities: [SportsEntity]) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let normalized = entities.map { entity in
      SportsEntity(id: entity.id, name: entity.name, kind: entity.kind, sportID: entity.sportID,
        competitionIDs: Set(entity.competitionIDs).sorted(), aliases: Set(entity.aliases).sorted(), providerIDs: entity.providerIDs,
        active: entity.active, memberships: (entity.memberships ?? []).sorted {
          ($0.entityID, $0.validFrom, $0.validUntil ?? .distantFuture, $0.season ?? "") < ($1.entityID, $1.validFrom, $1.validUntil ?? .distantFuture, $1.season ?? "")
        }, schoolID: entity.schoolID, gender: entity.gender, division: entity.division, groupPath: entity.groupPath, abbreviation: entity.abbreviation)
    }.sorted { $0.id < $1.id }
    let data = try encoder.encode(normalized)
    return SportsReviewedCatalog.version + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  public init(version: String, generatedAt: Date, entities: [SportsEntity]) {
    self.version = version; self.generatedAt = generatedAt; self.entities = entities
  }
}
