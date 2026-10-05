import SportsCore

/// Reviewed names and display grouping coexist with activated provider identities.
enum SportsReviewedCatalogMerge {
  static func definition(_ definition: SportsEntity, existing: SportsEntity?) -> SportsEntity {
    guard let existing, !existing.providerIDs.isEmpty else { return definition }
    return SportsEntity(id: definition.id, name: definition.name, kind: definition.kind, sportID: definition.sportID,
      competitionIDs: existing.competitionIDs, aliases: Array(Set(definition.aliases + existing.aliases)), providerIDs: existing.providerIDs,
      active: existing.active, memberships: existing.memberships ?? [], schoolID: definition.schoolID, gender: definition.gender,
      division: definition.division, groupPath: definition.groupPath, abbreviation: definition.abbreviation ?? existing.abbreviation)
  }
}
