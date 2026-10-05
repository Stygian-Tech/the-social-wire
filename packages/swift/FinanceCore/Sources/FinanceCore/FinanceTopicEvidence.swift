import Foundation

/// Topic admission uses local, substantive evidence rather than isolated ambiguous nouns.
struct FinanceTopicEvidence {
  let text: String
  let financeContext: Bool
  let businessEvidence: Bool
  let sectorIDs: [String]

  init(title: String, summary: String?) {
    let headline = title.lowercased()
    var lead = String((summary ?? "").lowercased().prefix(600))
    for marker in ["related stories:", "related articles:", "you may also like", "read more:", "subscribe for", "subscribe to our", "subscribe to the", "subscribe now", "this article originally appeared"] {
      if let boundary = lead.range(of: marker) { lead = String(lead[..<boundary.lowerBound]) }
    }
    // Two opening sentences keep incidental body/footer mentions from defining the topic.
    let opening = lead.replacingOccurrences(of: #"[.!?]\s+|\n+"#, with: "\n", options: .regularExpression)
    let sentences = opening.components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(2)
    let segments = [headline] + Array(sentences)
    text = segments.joined(separator: " ")
    func has(_ words: [String], _ segment: String) -> Bool {
      words.contains { Self.contains($0, in: segment) }
    }
    let businessTerms = ["industry", "sector", "company", "business", "sales", "revenue", "earnings",
      "investment", "exports", "imports", "manufacturers",
      "firms", "ceo", "chief executive"]
    let hasBusinessEvidence = segments.contains { has(businessTerms, $0) }
    let strongPhrases = ["stock market", "stock price", "stock prices", "stock exchange", "share price", "share prices",
      "bond yield", "bond yields", "government bonds", "corporate bonds", "equity market", "financial market",
      "financial markets", "stock rises", "stock falls", "price target", "share buyback", "unemployment rate", "sec filing", "securities filing", "financial regulation", "banking regulation",
      "bank regulation", "securities regulation", "interest rate", "interest rates", "central bank", "monetary policy",
      "consumer prices", "economic growth", "economic outlook", "employment report", "jobs report",
      "trade deficit", "trade surplus", "government budget", "fiscal policy", "housing market", "real estate market"]
    let strongTerms = ["earnings", "revenue", "nasdaq", "bitcoin", "cryptocurrency", "dividend", "dividends",
      "ethereum", "cryptocurrencies", "stablecoin", "stablecoins", "gdp", "recession", "merger", "acquisition", "10-k", "10-q"]
    var sectors = Set<String>()
    var financialSegments: [String] = []
    let sportingHeadline = has(["hit tons", "wins toss", "win toss", "innings", "wickets", "batting", "bowling figures"], headline)
      || (has(["cricket"], headline) && has(["wins", "win", "defeated", "match", "tournament"], headline))
    let sportingLead = Array(sentences).contains { has(["innings", "wickets", "batting", "bowling"], $0)
      && has(["runs", "defeated", "match", "cricket", "team"], $0) }
    let financialHeadline = has(strongPhrases, headline) || has(strongTerms, headline)
      || has(["profit", "profits", "funding", "investment", "salary cap", "sponsorship deal", "team valuation"], headline)
    let incidentalSports = (sportingHeadline || sportingLead) && !financialHeadline
    businessEvidence = hasBusinessEvidence && !incidentalSports
    for segment in segments {
      if incidentalSports { continue }
      let matchedSectors = FinanceSector.all.filter { has($0.keywords, segment) }
      let sectorBusiness = !matchedSectors.isEmpty && (has(["industry", "sector", "company", "business", "sales", "revenue", "earnings", "investment", "exports", "imports", "manufacturers", "firms"], segment)
        || has(["industrial production", "oil production", "oil supply", "oil demand", "natural gas production",
          "natural gas supply", "retail sales", "housing prices", "insurance premiums", "bank lending",
          "semiconductor supply", "pharmaceutical supply"], segment))
      if sectorBusiness { sectors.formUnion(matchedSectors.map(\.id)) }
      let operatingBusiness = has(["industry", "sector", "company", "business", "manufacturers", "firms"], segment)
        && has(["prices", "costs", "sales", "production", "supply", "demand", "investment", "exports", "imports"], segment)
      let inflation = has(["inflation"], segment)
        && has(["report", "reporting", "prices", "economic", "economy", "rises", "falls", "slows", "growth"], segment)
      let fiscal = has(["fiscal", "tariff", "tariffs"], segment)
        && has(["budget", "government", "trade", "imports", "exports", "tax", "taxes", "borrowing"], segment)
      if has(strongPhrases, segment) || has(strongTerms, segment) || sectorBusiness || operatingBusiness || inflation || fiscal {
        financialSegments.append(segment)
      }
    }
    financeContext = !financialSegments.isEmpty
    sectorIDs = sectors.sorted()
  }

  static func contains(_ needle: String, in text: String) -> Bool {
    guard !needle.isEmpty else { return false }
    var start = text.startIndex
    while start < text.endIndex, let range = text.range(of: needle.lowercased(), range: start..<text.endIndex) {
      let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
      let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
      if !(before?.isLetter == true || before?.isNumber == true), !(after?.isLetter == true || after?.isNumber == true) { return true }
      start = range.upperBound
    }
    return false
  }
}
