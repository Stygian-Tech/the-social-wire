import Testing
@testable import FinanceCore

@Suite("Named Finance feeds")
struct FinanceNamedFeedsTests {
  private var instruments: [FinanceInstrument] {
    FinanceReviewedInstrumentMetadata.entries.map {
      FinanceReviewedInstrumentMetadata.apply(to: .init(id: $0.instrumentID, name: $0.aliases.first ?? $0.expectedSymbol,
        symbol: $0.expectedSymbol, kind: "Common Stock", providerID: $0.expectedProviderID, exchange: "US"))
    }
  }
  @Test func reviewedCoverageIsBroadAndDeterministic() {
    let entries = FinanceReviewedInstrumentMetadata.entries
    #expect(entries.count >= 100)
    #expect(Set(entries.map(\.instrumentID)).count == entries.count)
    #expect(Set(entries.flatMap(\.sectorIDs)) == Set(FinanceSector.all.map(\.id)))
    #expect(entries.allSatisfy { !$0.evidenceURL.isEmpty && $0.tradingViewSymbol == nil })
    let feeds = FinanceNamedFeeds.catalog(instruments: instruments)
    #expect(Set(feeds.map(\.id)).count == feeds.count)
    #expect(feeds.filter { $0.kind == "instrument" }.count == instruments.count)
    #expect(FinanceNamedFeeds.revision(instruments: instruments).utf8.count == 64)
    #expect(FinanceNamedFeeds.revision(instruments: instruments) == FinanceNamedFeeds.revision(instruments: instruments.reversed()))
  }
  @Test func pickerContainsOnlySupportedStockAndFundKinds() {
    let allowed = ["Common Stock", "Depositary Receipt", "REIT", "ETF", "Mutual Fund", "equity"]
    let denied = ["Municipal Bond", "Corporate Bond", "Bond", "security", "unknown", "Option", "Future", "crypto", "index", "commodity"]
    func instrument(_ kind: String) -> FinanceInstrument {
      .init(id: "kind:" + kind, name: "Identity Fixture", symbol: "FIX", kind: kind, providerID: "provider:" + kind)
    }
    let all = (allowed + denied).map(instrument)
    let selectable = FinanceNamedFeeds.catalog(instruments: all).filter { $0.kind == "instrument" }
    #expect(Set(selectable.flatMap(\.instrumentIDs)) == Set(allowed.map { instrument($0).id }))
    #expect(all.count == allowed.count + denied.count)
    #expect(FinanceNamedFeeds.catalog(instruments: instruments).filter { $0.kind == "instrument" }.count == 107)
  }
  @Test func applePersonAndFruitNamesNeverBecomeCompanyAssociations() throws {
    let apple = try #require(instruments.first { $0.symbol == "AAPL" })
    let cases: [(String, String?)] = [
      ("Apple Martin makes her catwalk debut at Chloé’s SS27 show", "It was bound to happen sooner or later. The fashion industry has had its eye on Apple Martin ever since she appeared on the Marty Supreme red carpet alongside her mother, Gwyneth Paltrow, last December."),
      ("Food manufacturers report higher Apple pie revenue", nil),
      ("Apple growers report increased revenue after the harvest", nil)
    ]
    for (title, summary) in cases {
      let analysis = FinanceResolver.analyze(title: title, summary: summary, catalog: instruments)
      #expect(!analysis.associations.contains { $0.instrumentID == apple.id })
      for id in ["instrument:" + apple.id, "group:mag7", "group:faang"] {
        let feed = try #require(FinanceNamedFeeds.catalog(instruments: instruments).first { $0.id == id })
        #expect(!feed.matches(analysis, title: title, summary: summary))
      }
    }
    for title in ["Apple earnings increase on iPhone sales", "Apple Silicon investment boosts revenue", "Apple reports higher quarterly revenue"] {
      #expect(FinanceResolver.analyze(title: title, catalog: instruments).associations.contains { $0.instrumentID == apple.id })
    }
  }
  @Test func symbolCollisionsRetainSeparateListingFeeds() throws {
    let a = FinanceInstrument(id: "listing-us", name: "Example Corp", symbol: "EX", kind: "Common Stock", providerID: "first", exchange: "US")
    let b = FinanceInstrument(id: "listing-ln", name: "Example Corp", symbol: "EX", kind: "Common Stock", providerID: "second", exchange: "LN")
    let feeds = FinanceNamedFeeds.catalog(instruments: [a,b]).filter { $0.kind == "instrument" }
    #expect(feeds.count == 2)
    #expect(Set(feeds.map(\.title)).count == 2)
    let ambiguous = FinanceResolver.analyze(title: "Example Corp earnings rise with $EX", catalog: [a,b])
    #expect(feeds.allSatisfy { !$0.matches(ambiguous, title: "Example Corp earnings rise with $EX", summary: nil) })
  }
  @Test func exactMembershipAndOverlap() throws {
    let feeds = FinanceNamedFeeds.catalog(instruments: instruments)
    let apple = try #require(instruments.first { $0.symbol == "AAPL" })
    let analysis = FinanceResolver.analyze(title: "Apple earnings exceed forecasts", catalog: instruments)
    for id in ["finance", "instrument:" + apple.id, "industry:technology", "group:faang", "group:mag7"] {
      #expect(try #require(feeds.first { $0.id == id }).matches(analysis, title: "Apple earnings exceed forecasts", summary: nil))
    }
    #expect(!feeds.first { $0.id == "industry:pharma" }!.matches(analysis, title: "Apple earnings exceed forecasts", summary: nil))
    #expect(!feeds.first { $0.id == "industry:energy" }!.matches(analysis, title: "Apple earnings exceed forecasts", summary: nil))
  }
  @Test func pharmaIsNarrowAndCompanyAware() throws {
    let pharma = try #require(FinanceNamedFeeds.catalog(instruments: instruments).first { $0.id == "industry:pharma" })
    for title in ["Pfizer revenue rises", "Eli Lilly earnings exceed forecasts", "Pharmaceutical companies report higher sales"] {
      let analysis = FinanceResolver.analyze(title: title, catalog: instruments)
      #expect(pharma.matches(analysis, title: title, summary: nil))
    }
    for title in ["Healthcare companies report higher revenue", "Hospital industry increases investment", "Healthcare insurance premiums rise"] {
      let analysis = FinanceResolver.analyze(title: title, catalog: instruments)
      #expect(!pharma.matches(analysis, title: title, summary: nil))
    }
  }
  @Test func miningMembershipIncludesActualMinersOnly() throws {
    let mining = try #require(FinanceNamedFeeds.catalog(instruments: instruments).first { $0.id == "industry:mining" })
    let actual = instruments.filter { ["BHP", "RIO", "FCX", "NEM"].contains($0.symbol) }
    #expect(Set(mining.instrumentIDs) == Set(actual.map(\.id)))
    for company in actual {
      let headline = company.name + " reports higher earnings"
      #expect(mining.matches(FinanceResolver.analyze(title: headline, catalog: instruments), title: headline, summary: nil))
    }
    #expect(!mining.instrumentIDs.contains(try #require(instruments.first { $0.symbol == "LIN" }).id))
  }
  @Test func incidentalSummaryIndustriesDoNotDefineNamedFeeds() throws {
    let feeds = FinanceNamedFeeds.catalog(instruments: instruments)
    let pharma = try #require(feeds.first { $0.id == "industry:pharma" })
    let title = "Tariffs on Canadian power could raise costs, emissions and grid risks"
    let summary = "Milk and alcohol, paper and steel, semiconductors and pharmaceuticals—an array of products are currently subject to tariffs in the ongoing trade dispute between the United States and Canada."
    let analysis = FinanceResolver.analyze(title: title, summary: summary, catalog: instruments)
    #expect(analysis.eligible)
    #expect(!pharma.matches(analysis, title: title, summary: summary))
    #expect(!feeds.first { $0.id == "industry:semiconductors" }!.matches(analysis, title: title, summary: summary))
    let biotechTitle = "I Peace Selected as a TOP 10 Awardee"
    let biotechSummary = "I Peace Inc., a biotech company pioneering induced pluripotent stem cell technologies, announced its award."
    #expect(!pharma.matches(FinanceResolver.analyze(title: biotechTitle, summary: biotechSummary, catalog: instruments), title: biotechTitle, summary: biotechSummary))
    let focusedTitle = "Margins recover after a difficult year"
    let focusedSummary = "Pharmaceutical companies report rising revenue as drug sales recover."
    #expect(pharma.matches(FinanceResolver.analyze(title: focusedTitle, summary: focusedSummary, catalog: instruments), title: focusedTitle, summary: focusedSummary))
  }
  @Test func bankAndOilCricketTeamsAreNotFinancialReporting() throws {
    let title = "SBP Win; Taha, Faiq Hit Tons; SNGPL, Kingsmen On Top"
    let summary = "State Bank of Pakistan (SBP) defeated Oil and Gas Development Company Limited (O..."
    let analysis = FinanceResolver.analyze(title: title, summary: summary, catalog: instruments)
    #expect(!analysis.eligible)
    #expect(!FinanceResolver.analyze(title: "Apple company cricket team wins match", summary: "Apple defeated another team after a six-wicket innings.", catalog: instruments).eligible)
    let feeds = FinanceNamedFeeds.catalog(instruments: instruments)
    #expect(!feeds.first { $0.id == "industry:banks" }!.matches(analysis, title: title, summary: summary))
    #expect(!feeds.first { $0.id == "industry:oil-gas" }!.matches(analysis, title: title, summary: summary))
    #expect(FinanceResolver.analyze(title: "Cricket industry reports record revenue", summary: "Teams played several matches.", catalog: instruments).eligible)
  }
  @Test func inactiveAndMissingMembershipNeverSubstituted() throws {
    let incomplete = instruments.filter { $0.symbol != "MSFT" }
    #expect(!FinanceNamedFeeds.catalog(instruments: incomplete).contains { $0.id == "group:mag7" })
    #expect(FinanceNamedFeeds.catalog(instruments: incomplete).contains { $0.id == "group:faang" })
    let apple = try #require(instruments.first { $0.symbol == "AAPL" })
    let inactive = FinanceInstrument(id: apple.id, name: apple.name, symbol: apple.symbol, kind: apple.kind, providerID: apple.providerID, isActive: false)
    #expect(!FinanceNamedFeeds.catalog(instruments: [inactive]).contains { $0.kind == "instrument" })
    #expect(FinanceNamedFeeds.revision(instruments: incomplete) != FinanceNamedFeeds.revision(instruments: instruments))
  }
  @Test func weakOrObsoleteEvidenceRejected() throws {
    let feed = try #require(FinanceNamedFeeds.catalog(instruments: instruments).first { $0.kind == "instrument" })
    for confidence in [0.89, Double.nan, Double.infinity] {
      let analysis = FinanceArticleAnalysis(eligible: true, materiality: "reporting", associations: [.init(instrumentID: feed.instrumentIDs[0], confidence: confidence, evidence: ["name-or-alias"], prominence: 0)], sectorIDs: [])
      #expect(!feed.matches(analysis, title: "Company revenue rises", summary: nil))
    }
    let old = FinanceArticleAnalysis(eligible: true, materiality: "reporting", associations: [.init(instrumentID: feed.instrumentIDs[0], confidence: 1, evidence: [], prominence: 0, resolverVersion: "old")], sectorIDs: [], resolverVersion: "old")
    #expect(!feed.matches(old, title: "Company revenue rises", summary: nil))
  }
  @Test func industriesRejectHomonyms() throws {
    let feeds = FinanceNamedFeeds.catalog(instruments: instruments)
    for (id, title) in [("oil-gas", "Cooking oil manufacturers report higher revenue"), ("oil-gas", "Olive oil companies increase investment"), ("mining", "Bitcoin mining companies report record revenue"), ("energy", "Cooking oil manufacturers report higher revenue"), ("materials", "Bitcoin mining companies report record revenue")] {
      let feed = try #require(feeds.first { $0.id == "industry:" + id })
      #expect(!feed.matches(FinanceResolver.analyze(title: title, catalog: instruments), title: title, summary: nil))
    }
    for (id, title) in [("oil-gas", "Crude oil producers report higher revenue"), ("mining", "Copper mining companies report higher revenue"), ("energy", "Crude oil producers report higher revenue"), ("materials", "Copper mining companies report higher revenue")] {
      let feed = try #require(feeds.first { $0.id == "industry:" + id })
      #expect(feed.matches(FinanceResolver.analyze(title: title, catalog: instruments), title: title, summary: nil))
    }
  }
  @Test func cursorsBindNamedFeedAndViewer() throws {
    let codec = try FinanceCursorCodec(secret: String(repeating: "x", count: 32))
    let cursor = try codec.encode(.init(feed: "group:mag7", generationID: "generation", language: "en", preferenceFingerprint: "revision", viewerScope: "viewer", nextOrdinal: 1, expiresAt: .distantFuture))
    #expect(try codec.decode(cursor, language: "en", preferenceFingerprint: "revision", viewerScope: "viewer", feed: "group:mag7").feed == "group:mag7")
    #expect(throws: FinanceCursorError.invalidContext) { try codec.decode(cursor, language: "en", preferenceFingerprint: "revision", viewerScope: "viewer", feed: "group:faang") }
    #expect(throws: FinanceCursorError.invalidContext) { try codec.decode(cursor, language: "en", preferenceFingerprint: "revision", viewerScope: "other", feed: "group:mag7") }
  }
}
