import Foundation

public enum FinanceResolver {
  public static let version = "finance-resolver-v3.3"
  private static func contains(_ needle: String, in text: String) -> Bool {
    FinanceTopicEvidence.contains(needle, in: text)
  }
  public static func analyze(title: String, summary: String? = nil,
    structuredInstrumentIDs: [String] = [], verifiedInstrumentIDs: [String] = [],
    catalog: [FinanceInstrument]) -> FinanceArticleAnalysis {
    let headline = title.lowercased()
    let topic = FinanceTopicEvidence(title: title, summary: summary)
    let text = topic.text
    let macroDefinitions: [(String, [String])] = [
      ("inflation", ["inflation", "consumer prices"]),
      ("monetary-policy", ["interest rate", "central bank", "monetary policy"]),
      ("growth", ["gdp", "economic growth", "recession"]),
      ("employment", ["unemployment", "employment report", "jobs report"]),
      ("trade", ["tariff", "trade deficit", "trade surplus"]),
      ("fiscal-policy", ["fiscal", "government budget"])
    ]
    let macroTopics = macroDefinitions.filter { $0.1.contains { contains($0, in: text) } }.map { $0.0 }
    let businessEvidence = topic.businessEvidence
    let financeContext = topic.financeContext
    let announcementContext = contains("announces", in: text) || contains("launches", in: text)
    guard financeContext || announcementContext || businessEvidence || !structuredInstrumentIDs.isEmpty || !verifiedInstrumentIDs.isEmpty else {
      return .init(eligible: false, materiality: "reporting", associations: [], sectorIDs: [])
    }
    let active = catalog.filter(\.isActive)
    var symbols: [String: Int] = [:]
    var namesCount: [String: Int] = [:]
    var qualified: [String: Int] = [:]
    for instrument in active {
      symbols[instrument.symbol.lowercased(), default: 0] += 1
      for name in Set(([instrument.name] + instrument.aliases).map { $0.lowercased() }) {
        namesCount[name, default: 0] += 1
      }
      if let exchange = instrument.exchange {
        qualified[(exchange + ":" + instrument.symbol).lowercased(), default: 0] += 1
      }
    }
    var associations: [FinanceAssociation] = []
    for instrument in active {
      var evidence: [String] = []
      if structuredInstrumentIDs.contains(instrument.id) { evidence.append("structured-metadata") }
      if verifiedInstrumentIDs.contains(instrument.id) { evidence.append("verified-source") }
      let names = [instrument.name] + instrument.aliases
      var nameText = text
      if instrument.id == FinanceIdentity.instrumentID(provider: "openfigi", nativeID: "BBG000B9Y5X2") {
        // Reviewed homonyms must not become company evidence through the short Apple alias.
        for phrase in ["apple martin", "apple pie", "apple juice", "apple cider", "apple sauce", "apple butter", "apple orchard", "apple harvest", "apple growers", "apple fruit"] {
          nameText = nameText.replacingOccurrences(of: phrase, with: " ")
        }
      }
      let exactName = (financeContext || businessEvidence) && instrument.name.count >= 4 && namesCount[instrument.name.lowercased()] == 1 && contains(instrument.name, in: nameText)
      let businessAlias = (financeContext || businessEvidence) && instrument.aliases.contains {
        $0.count >= 4 && namesCount[$0.lowercased()] == 1 && contains($0, in: nameText)
      }
      if exactName || businessAlias { evidence.append("name-or-alias") }
      let exchangeTicker = instrument.exchange.map { ($0 + ":" + instrument.symbol).lowercased() }
      let qualifiedMatch = exchangeTicker.map { qualified[$0] == 1 && contains($0, in: text) } == true
      let unambiguousCashtag = symbols[instrument.symbol.lowercased()] == 1 && contains("$" + instrument.symbol, in: text)
      if financeContext && (qualifiedMatch || unambiguousCashtag) { evidence.append("contextual-ticker") }
      guard !evidence.isEmpty else { continue }
      let confidence = evidence.contains("structured-metadata") || evidence.contains("verified-source") ? 1.0
        : evidence.contains("name-or-alias") ? 0.95 : 0.9
      let prominent = names.contains { contains($0, in: headline) } || contains("$" + instrument.symbol, in: headline)
      associations.append(.init(instrumentID: instrument.id, confidence: confidence,
        evidence: evidence, prominence: prominent ? 0 : 1))
    }
    associations.sort { $0.prominence == $1.prominence ? $0.instrumentID < $1.instrumentID : $0.prominence < $1.prominence }
    let sectors = Set(topic.sectorIDs + catalog.filter { instrument in
      associations.contains { $0.instrumentID == instrument.id }
    }.flatMap(\.sectorIDs))
    let materiality: String
    if ["earnings", "revenue"].contains(where: { contains($0, in: text) }) { materiality = "earnings" }
    else if ["filing", "10-k", "10-q"].contains(where: { contains($0, in: text) }) { materiality = "filing" }
    else if ["merger", "acquisition"].contains(where: { contains($0, in: text) }) { materiality = "merger" }
    else if contains("regulation", in: text) { materiality = "regulation" }
    else if ["ceo", "chief executive", "leadership"].contains(where: { contains($0, in: text) }) { materiality = "leadership" }
    else if ["price target", "stock rises", "stock falls"].contains(where: { contains($0, in: text) }) { materiality = "price-chatter" }
    else if ["announces", "launches"].contains(where: { contains($0, in: text) }) { materiality = "announcement" }
    else { materiality = "reporting" }
    return .init(eligible: financeContext || !associations.isEmpty, materiality: materiality,
      associations: associations, sectorIDs: sectors.sorted(), macroTopics: macroTopics.sorted())
  }
}
