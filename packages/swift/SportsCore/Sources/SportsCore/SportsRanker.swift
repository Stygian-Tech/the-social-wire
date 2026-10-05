import Foundation

public enum SportsRanker {
  public static func rank(candidates: [SportsRankCandidate], selections: [SportsSelection] = [], catalog: [SportsEntity], reserveGlobal: Bool = true) -> [SportsRankCandidate] {
    rank(candidates: candidates, followIDs: Set(selections.filter { $0.action == "follow" }.map(\.reference)),
      muteIDs: Set(selections.filter { $0.action == "mute" }.map(\.reference)), entities: catalog, reserveGlobal: reserveGlobal)
  }
  public static func rank(candidates: [SportsRankCandidate], followIDs: Set<String> = [], muteIDs: Set<String> = [], entities: [SportsEntity], reserveGlobal: Bool = true) -> [SportsRankCandidate] {
    let byID = Dictionary(entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let sportParents = SportsSportHierarchy.parentIDs(catalog: entities)
    func direct(_ candidate: SportsRankCandidate) -> Set<String> {
      Set(candidate.analysis.associations.filter { $0.confidence >= 0.9 && $0.resolverVersion == SportsResolver.version }.map(\.entityID))
    }
    func broad(_ candidate: SportsRankCandidate) -> Set<String> {
      SportsSportHierarchy.ancestors(of: Set(candidate.analysis.sportIDs), parents: sportParents).union(candidate.analysis.competitionIDs)
        .union(direct(candidate).filter { byID[$0]?.kind == "classification" })
    }
    func personal(_ id: String) -> Bool { ["team", "national-side", "athlete", "driver", "ncaa-team"].contains(byID[id]?.kind ?? "") }
    func permitted(_ candidate: SportsRankCandidate) -> Bool {
      let ids = direct(candidate)
      // Explicit team/person exclusions win; direct follows only override broader exclusions.
      if ids.contains(where: { muteIDs.contains($0) && personal($0) }) { return false }
      if broad(candidate).isDisjoint(with: muteIDs) && ids.isDisjoint(with: muteIDs) { return true }
      return ids.contains { followIDs.contains($0) && !muteIDs.contains($0) && personal($0) }
    }
    func computedScore(_ candidate: SportsRankCandidate) -> Double {
      let ids = direct(candidate)
      let personalBoost = ids.contains { followIDs.contains($0) && personal($0) } ? 0.25 : 0
      let competitionBoost = !broad(candidate).filter { byID[$0]?.kind != "sport" }.isDisjoint(with: followIDs) ? 0.10 : 0
      let sportBoost = !SportsSportHierarchy.ancestors(of: Set(candidate.analysis.sportIDs), parents: sportParents).isDisjoint(with: followIDs) ? 0.05 : 0
      let materiality: Double
      switch candidate.analysis.materiality {
      case "championship", "record": materiality = 1.2
      case "transfer", "injury", "disciplinary": materiality = 1.15
      case "organizational-change", "consequential-game": materiality = 1.10
      case "routine-chatter": materiality = 0.45
      default: materiality = 1
      }
      return candidate.baseScore * materiality * (1 + min(0.35, personalBoost + competitionBoost + sportBoost))
    }
    let occurrences = Dictionary(candidates.map { ($0.item.itemID, 1) }, uniquingKeysWith: +)
    let scores = Dictionary(uniqueKeysWithValues: candidates.filter { occurrences[$0.item.itemID] == 1 }.map { ($0.item.itemID, computedScore($0)) })
    // Duplicate IDs may carry different evidence/scores; preserve their original comparison semantics.
    func score(_ candidate: SportsRankCandidate) -> Double { scores[candidate.item.itemID] ?? computedScore(candidate) }
    var seenIDs = Set<String>(); var seenURLs = Set<String>(); var coverageDates: [String: Date] = [:]
    var remaining = candidates.filter { $0.analysis.eligible && $0.analysis.resolverVersion == SportsResolver.version && $0.baseScore.isFinite && $0.baseScore >= 0 && permitted($0) }
      .sorted { score($0) == score($1) ? $0.item.itemID < $1.item.itemID : score($0) > score($1) }
      .filter { candidate in
        guard seenIDs.insert(candidate.item.itemID).inserted, seenURLs.insert(candidate.item.canonicalURL).inserted else { return false }
        let title = SportsResolver.normalize(candidate.item.title)
        let coverage = title + "|" + direct(candidate).sorted().joined(separator: ",")
        if title.count >= 20, let date = candidate.item.publishedAt {
          if let old = coverageDates[coverage], abs(date.timeIntervalSince(old)) <= 6 * 3600 { return false }
          coverageDates[coverage] = date
        }
        return true
      }
    var result: [SportsRankCandidate] = []
    var domainCounts = Dictionary(remaining.map { ($0.item.source.domain, 1) }, uniquingKeysWith: +)
    var sportCounts = Dictionary(remaining.flatMap { candidate in Set(candidate.analysis.sportIDs).map { ($0, 1) } }, uniquingKeysWith: +)
    while !remaining.isEmpty {
      let global = reserveGlobal && result.count % 5 == 4 ? remaining.enumerated().filter { $0.element.majorGlobal }.max { $0.element.baseScore < $1.element.baseScore }?.offset : nil
      var position = global ?? 0
      if global == nil, result.count >= 2 {
        let recent = Array(result.suffix(2))
        let domains = Set(recent.map { $0.item.source.domain })
        let sports = Set(recent.flatMap { $0.analysis.sportIDs })
        let top = score(remaining[0])
        // A matching-only feed often has one sport/source. Do not repeatedly scan
        // every remaining candidate when no diversity choice can possibly exist.
        let canVaryDomain = domains.count != 1 || domainCounts[domains.first!] != remaining.count
        let canVarySport = sports.count != 1 || sportCounts[sports.first!] != remaining.count
        if canVaryDomain && canVarySport, let diverse = remaining.firstIndex(where: { candidate in
          score(candidate) >= top * 0.7
            && (domains.count != 1 || !domains.contains(candidate.item.source.domain))
            && (sports.count != 1 || Set(candidate.analysis.sportIDs).isDisjoint(with: sports))
        }) { position = diverse }
      }
      let selected = remaining.remove(at: position)
      domainCounts[selected.item.source.domain, default: 0] -= 1
      for sport in Set(selected.analysis.sportIDs) { sportCounts[sport, default: 0] -= 1 }
      result.append(selected)
    }
    return result
  }
}
