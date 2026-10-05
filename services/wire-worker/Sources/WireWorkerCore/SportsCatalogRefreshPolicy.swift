import Foundation
import SportsCore

/// A new reviewed manifest activates on the next Coordinator cycle, even within the daily TTL.
enum SportsCatalogRefreshPolicy {
  private static let reviewedDefinitions = SportsReviewedCatalog.entities

  static func shouldRefresh(_ snapshot: SportsCatalogSnapshot, asOf: Date) -> Bool {
    let matchesManifest = snapshot.version == SportsReviewedCatalog.version
      || snapshot.version.hasPrefix(SportsReviewedCatalog.version + ":")
    guard matchesManifest, asOf.timeIntervalSince(snapshot.generatedAt) < 86400 else { return true }
    // Provider snapshots can carry the current version while retaining an older
    // reviewed hierarchy. Compare reviewed fields independently of provider IDs,
    // imported aliases, membership history, and delisting status.
    let existing = Dictionary(snapshot.entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return reviewedDefinitions.contains { definition in
      guard let entity = existing[definition.id] else { return true }
      return entity.name != definition.name || entity.kind != definition.kind
        || entity.sportID != definition.sportID || entity.schoolID != definition.schoolID
        || entity.gender != definition.gender || entity.division != definition.division
        || entity.groupPath != definition.groupPath
        || !Set(definition.aliases).isSubset(of: Set(entity.aliases))
    }
  }
}
