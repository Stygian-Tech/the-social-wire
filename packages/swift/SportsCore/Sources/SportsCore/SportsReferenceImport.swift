import Foundation

public enum SportsReferenceImport {
  /// Provider identities are attributes. Repeated imports reuse the stored opaque identity.
  public static func team(record: [String: String], competition: SportsEntity, existing: [SportsEntity], now: Date) -> SportsEntity? {
    guard let nativeID = record["idTeam"], let name = record["strTeam"], !name.isEmpty else { return nil }
    let suppliedGender = record["strGender"].flatMap(SportsGenderContext.gender)
    if let suppliedGender, let reviewedGender = competition.gender, suppliedGender != reviewedGender { return nil }
    let expectedGender = suppliedGender ?? competition.gender
    let compatibleKinds = Set(["team", "ncaa-team", "national-side"])
    var previous: SportsEntity? = existing.first { entity in
      compatibleKinds.contains(entity.kind) && entity.sportID == competition.sportID
        && entity.providerIDs["thesportsdb"] == nativeID
    }
    if previous == nil {
      previous = existing.first { entity in
        compatibleKinds.contains(entity.kind) && entity.sportID == competition.sportID
          && entity.competitionIDs.contains(competition.id) && entity.name == name
      }
    }
    // Conflicting provider metadata requires review; never rewrite an existing identity.
    if let expectedGender, let previousGender = previous?.gender, expectedGender != previousGender { return nil }
    let newID = "sp_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    let identity: String = previous?.id ?? newID
    let kind: String = previous?.kind ?? (competition.name.contains("NCAA") ? "ncaa-team" : "team")
    var aliases: [String] = previous?.aliases ?? []
    if let oldName = previous?.name, oldName != name { aliases.append(oldName) }
    aliases = Array(Set(aliases)).sorted()
    var providers: [String: String] = previous?.providerIDs ?? [:]
    providers["thesportsdb"] = nativeID
    var memberships: [SportsMembership] = previous?.memberships ?? []
    if !memberships.contains(where: { $0.entityID == competition.id && $0.includes(now) }) {
      memberships.append(SportsMembership(entityID: competition.id, validFrom: now))
    }
    let competitionIDs: [String] = Array(Set((previous?.competitionIDs ?? []) + [competition.id])).sorted()
    return SportsEntity(id: identity, name: name, kind: kind, sportID: competition.sportID,
      competitionIDs: competitionIDs, aliases: aliases, providerIDs: providers, memberships: memberships,
      schoolID: previous?.schoolID, gender: previous?.gender ?? expectedGender, division: previous?.division, groupPath: previous?.groupPath,
      abbreviation: SportsProviderAbbreviation.validated(record["strTeamShort"], providerTeamID: nativeID)
        ?? (previous?.providerIDs["thesportsdb"] == nativeID ? previous?.abbreviation : nil))
  }
}
