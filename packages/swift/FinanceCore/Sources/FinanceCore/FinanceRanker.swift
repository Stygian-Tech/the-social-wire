import Foundation

public enum FinanceRanker {
  public static func rank(candidates: [FinanceRankCandidate], instrumentIDs: Set<String> = [],
    sectorIDs: Set<String> = [], reserveGlobal: Bool = true) -> [FinanceRankCandidate] {
    func score(_ candidate: FinanceRankCandidate) -> Double {
      let instrument = candidate.analysis.associations.contains { instrumentIDs.contains($0.instrumentID) }
      let sector = !sectorIDs.isDisjoint(with: candidate.analysis.sectorIDs)
      let boost = min(0.35, (instrument ? 0.25 : 0) + (sector ? 0.10 : 0))
      let materiality: Double
      switch candidate.analysis.materiality {
      case "earnings", "merger": materiality = 1.2
      case "filing", "regulation": materiality = 1.15
      case "leadership", "announcement": materiality = 1.1
      case "price-chatter": materiality = 0.5
      default: materiality = 1
      }
      return candidate.baseScore * materiality * (1 + boost)
    }
    var seenIDs = Set<String>(); var seenURLs = Set<String>()
    var coverageDates: [String: Date] = [:]
    var remaining = candidates.filter { $0.analysis.eligible && $0.baseScore.isFinite && $0.baseScore >= 0 }
      .sorted { score($0) == score($1) ? $0.item.itemID < $1.item.itemID : score($0) > score($1) }
      .filter { candidate in
        guard !seenIDs.contains(candidate.item.itemID), !seenURLs.contains(candidate.item.canonicalURL) else { return false }
        let headline = candidate.item.title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
          .filter { !$0.isEmpty }.joined(separator: " ")
        let entities = candidate.analysis.associations.map(\.instrumentID).sorted().joined(separator: ",")
        let coverage = headline + "|" + entities
        if headline.count >= 20, let date = candidate.item.publishedAt {
          if let previous = coverageDates[coverage], abs(date.timeIntervalSince(previous)) <= 6 * 3600 { return false }
          coverageDates[coverage] = date
        }
        seenIDs.insert(candidate.item.itemID); seenURLs.insert(candidate.item.canonicalURL); return true
      }
    var result: [FinanceRankCandidate] = []
    while !remaining.isEmpty {
      let global = reserveGlobal && result.count % 5 == 4 ? remaining.enumerated().filter { $0.element.majorGlobal }
        .max { $0.element.baseScore < $1.element.baseScore }?.offset : nil
      result.append(remaining.remove(at: global ?? 0))
    }
    return result
  }
}
