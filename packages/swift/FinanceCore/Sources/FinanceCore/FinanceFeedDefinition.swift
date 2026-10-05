import Foundation

public struct FinanceFeedDefinition: Codable, Equatable, Sendable {
  public let id: String
  public let title: String
  public let kind: String
  public let instrumentIDs: [String]
  public let sectorIDs: [String]
  public let description: String

  public init(id: String, title: String, kind: String, instrumentIDs: [String] = [], sectorIDs: [String] = [], description: String) {
    self.id = id; self.title = title; self.kind = kind; self.instrumentIDs = instrumentIDs
    self.sectorIDs = sectorIDs; self.description = description
  }

  public func matches(_ analysis: FinanceArticleAnalysis, title: String, summary: String?) -> Bool {
    guard analysis.eligible, analysis.resolverVersion == FinanceResolver.version else { return false }
    if id == "finance" { return true }
    let association = analysis.associations.contains {
      $0.confidence.isFinite && (0.9...1).contains($0.confidence) && $0.resolverVersion == FinanceResolver.version
        && instrumentIDs.contains($0.instrumentID)
    }
    if let industry = FinanceIndustry.all.first(where: { "industry:" + $0.id == id }) {
      let topic = FinanceTopicEvidence(title: title, summary: summary)
      if !association && industry.id == "oil-gas" && ["cooking oil", "vegetable oil", "olive oil", "palm oil"].contains(where: { FinanceTopicEvidence.contains($0, in: topic.text) }) { return false }
      if !association && industry.id == "mining" && ["bitcoin", "cryptocurrency", "crypto mining"].contains(where: { FinanceTopicEvidence.contains($0, in: topic.text) }) { return false }
      let headlineMatch = industry.keywords.contains { FinanceTopicEvidence.contains($0, in: title.lowercased()) }
      var leadSubject = FinanceTopicEvidence(title: "", summary: summary).text.trimmingCharacters(in: .whitespacesAndNewlines)
      // Industry must be the opening subject, not one item in an unrelated product list.
      for prefix in ["the ", "a ", "an ", "small ", "large ", "global ", "major ", "leading "] {
        if leadSubject.hasPrefix(prefix) { leadSubject = String(leadSubject.dropFirst(prefix.count)) }
      }
      let leadMatch = industry.keywords.contains { leadSubject == $0 || leadSubject.hasPrefix($0 + " ") }
      return association || (topic.financeContext && (headlineMatch || leadMatch))
    }
    if !association && ["industry:energy", "industry:materials"].contains(id) {
      let topic = FinanceTopicEvidence(title: title, summary: summary)
      if id == "industry:energy" && ["cooking oil", "vegetable oil", "olive oil", "palm oil"].contains(where: { FinanceTopicEvidence.contains($0, in: topic.text) }) { return false }
      if id == "industry:materials" && ["bitcoin", "cryptocurrency", "crypto mining"].contains(where: { FinanceTopicEvidence.contains($0, in: topic.text) }) { return false }
    }
    return association || !Set(sectorIDs).isDisjoint(with: analysis.sectorIDs)
  }
}
