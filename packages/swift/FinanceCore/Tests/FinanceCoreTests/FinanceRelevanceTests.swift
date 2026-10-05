import Testing
@testable import FinanceCore

struct FinanceRelevanceTests {
  private let apple = FinanceInstrument(id: "apple", name: "Apple Inc", symbol: "AAPL", kind: "equity",
    providerID: "figi-apple", aliases: ["Apple"], sectorIDs: ["technology"])
  private let toyota = FinanceInstrument(id: "toyota", name: "Toyota Motor", symbol: "7203", kind: "equity",
    providerID: "figi-toyota", aliases: ["Toyota"], sectorIDs: ["consumer"])
  private let caterpillar = FinanceInstrument(id: "caterpillar", name: "Caterpillar", symbol: "CAT", kind: "equity",
    providerID: "figi-caterpillar", sectorIDs: ["industrials"])

  @Test("ambiguous finance words do not admit cooking, entertainment, or personal advice")
  func ambiguousWordsNeedFinancialMeaning() {
    let titles = [
      "How to make chicken stock for your next soup",
      "Chef shares a chicken stock recipe",
      "The best farmers market for fresh vegetables",
      "James Bond returns in a new film",
      "Nail filing techniques for a smoother manicure",
      "Political leadership announces new social media campaign",
      "How to conserve energy during a morning workout",
      "Choosing cooking oil for your next dinner",
      "Social media production tips for your holiday videos",
      "Meet your energy demands during a morning workout",
      "Apple pie supply is abundant at the picnic",
      "Apple pie demand grows among hungry children",
      "Caterpillar food supply depends on its woodland habitat",
      "Apple pie fans announce their favorite family recipe"
    ]
    for title in titles {
      let result = FinanceResolver.analyze(title: title, catalog: [apple, toyota, caterpillar])
      #expect(!result.eligible, "Unexpected finance admission: \(title)")
      #expect(result.associations.isEmpty, "Unexpected instrument match: \(title)")
    }
  }

  @Test("economic reporting remains eligible without matching a catalog instrument")
  func substantiveFinancialReporting() {
    let titles = [
      "Stock market rises after central bank decision",
      "Stock prices rise as investors assess the economic outlook",
      "Company shares rise after quarterly earnings beat forecasts",
      "Government bond yields climb before the interest rate decision",
      "SEC filing reveals quarterly operating losses",
      "Financial regulation tightens capital requirements for lenders",
      "Inflation slows as consumer prices stabilize",
      "Trade deficit widens as exports decline",
      "Fiscal budget increases government borrowing",
      "Housing market prices fall as mortgage demand weakens",
      "Oil production cuts tighten global supply",
      "Healthcare company revenue grows as demand increases",
      "Food industry wholesale prices rise as supply costs increase"
    ]
    for title in titles {
      let result = FinanceResolver.analyze(title: title, catalog: [])
      #expect(result.eligible, "Missing financial reporting: \(title)")
      #expect(result.associations.isEmpty)
      #expect(result.resolverVersion == FinanceResolver.version)
    }
  }

  @Test("named company events retain their associations and materiality")
  func namedCompanyReporting() {
    let earnings = FinanceResolver.analyze(title: "Apple reports quarterly earnings", catalog: [apple, toyota])
    #expect(earnings.eligible)
    #expect(earnings.associations.map(\.instrumentID) == ["apple"])
    #expect(earnings.materiality == "earnings")

    let leadership = FinanceResolver.analyze(title: "Toyota appoints a new CEO", catalog: [apple, toyota])
    #expect(leadership.eligible)
    #expect(leadership.associations.map(\.instrumentID) == ["toyota"])
    #expect(leadership.materiality == "leadership")

    let sales = FinanceResolver.analyze(title: "Toyota increases automotive sales", catalog: [apple, toyota])
    #expect(sales.eligible)
    #expect(sales.associations.map(\.instrumentID) == ["toyota"])
  }

  @Test("verified and structured instrument evidence retain instrument reporting")
  func trustedInstrumentEvidence() {
    let structured = FinanceResolver.analyze(title: "Quarterly update published",
      structuredInstrumentIDs: ["apple"], catalog: [apple, toyota])
    #expect(structured.eligible)
    #expect(structured.associations.first?.instrumentID == "apple")
    #expect(structured.associations.first?.evidence == ["structured-metadata"])
    #expect(structured.associations.first?.confidence == 1)

    let verified = FinanceResolver.analyze(title: "Quarterly update published",
      verifiedInstrumentIDs: ["toyota"], catalog: [apple, toyota])
    #expect(verified.eligible)
    #expect(verified.associations.first?.instrumentID == "toyota")
    #expect(verified.associations.first?.evidence == ["verified-source"])
    #expect(verified.associations.first?.confidence == 1)

    let unknown = FinanceResolver.analyze(title: "Quarterly update published",
      structuredInstrumentIDs: ["unknown"], verifiedInstrumentIDs: ["unknown"], catalog: [apple, toyota])
    #expect(!unknown.eligible)
    #expect(unknown.associations.isEmpty)
  }

  @Test("incidental finance links and distant boilerplate do not change the article topic")
  func incidentalFinancialMentions() {
    let footer = FinanceResolver.analyze(title: "A simple chicken soup recipe",
      summary: "Simmer the vegetables gently and serve with bread. Related stories: stock market news and earnings updates.",
      catalog: [apple, toyota])
    #expect(!footer.eligible)
    #expect(footer.associations.isEmpty)

    let longSummary = String(repeating: "Stir the vegetables gently and season the soup before serving. ", count: 80)
      + "Subscribe for the latest stock market news and Apple earnings updates."
    let distant = FinanceResolver.analyze(title: "A simple chicken soup recipe",
      summary: longSummary, catalog: [apple, toyota])
    #expect(!distant.eligible)
    #expect(distant.associations.isEmpty)
  }

  @Test("an informative opening summary can establish a financial topic")
  func summaryExplainsTheHeadline() {
    let result = FinanceResolver.analyze(title: "What changed this morning",
      summary: "The central bank raised interest rates as inflation climbed and government bond yields rose.", catalog: [])
    #expect(result.eligible)
    #expect(result.associations.isEmpty)
    #expect(result.macroTopics?.isEmpty == false)
  }

  @Test("subscriber reporting is financial evidence rather than a subscription footer")
  func subscriberRevenueSummary() {
    let result = FinanceResolver.analyze(title: "What changed this morning",
      summary: "Subscriber revenue grows as the company expands.", catalog: [])
    #expect(result.eligible)
    #expect(result.materiality == "earnings")
    #expect(result.associations.isEmpty)
  }

  @Test("abbreviations do not consume the opening-summary sentence budget")
  func abbreviationsInOpeningSummary() {
    for summary in [
      "The U.S. stock market rose as investors assessed the central bank decision.",
      "The U.K. government budget increased borrowing after weak economic growth.",
      "Acme Inc. reported quarterly earnings above forecasts."
    ] {
      let result = FinanceResolver.analyze(title: "What changed this morning", summary: summary, catalog: [])
      #expect(result.eligible, "Financial opening summary lost to abbreviation: \(summary)")
    }
  }
}
