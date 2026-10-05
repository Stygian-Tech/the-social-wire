import FinanceCore
import Foundation
import Testing

@Suite("Finance display contracts")
struct FinanceDisplayContractTests {
  private var instrument: FinanceInstrument {
    .init(id: "fin_listing", name: "Example", symbol: "EX", kind: "security", providerID: "BBG_EX")
  }
  @Test("public confidence is bounded integer basis points")
  func confidence() throws {
    let encoded = try JSONEncoder().encode(FinanceMatchedInstrument(instrument: instrument, confidence: 0.95, prominence: 0))
    let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(json["confidenceBps"] as? Int == 9500)
    #expect(json["confidence"] == nil)
    #expect(try JSONDecoder().decode(FinanceMatchedInstrument.self, from: encoded).confidence == 0.95)
    #expect(throws: EncodingError.self) {
      try JSONEncoder().encode(FinanceMatchedInstrument(instrument: instrument, confidence: .infinity, prominence: 0))
    }
  }
  @Test("macro topics remain independent of instrument and sector interests")
  func macroTopics() {
    let analysis = FinanceResolver.analyze(title: "Central bank cuts interest rate as inflation cools", catalog: [])
    #expect(analysis.eligible)
    #expect(analysis.associations.isEmpty)
    #expect(analysis.sectorIDs.isEmpty)
    #expect(analysis.macroTopics == ["inflation", "monetary-policy"])
  }
  @Test("reviewed display mappings require exact current identity and symbol")
  func reviewedMapping() {
    let mapping = FinanceReviewedInstrumentMetadata(instrumentID: "fin_listing", expectedProviderID: "BBG_EX",
      expectedSymbol: "EX", tradingViewSymbol: "NYSE:EX", sectorIDs: ["technology"], evidenceURL: "https://example.com/review",
      verifiedDomains: ["example.com"])
    #expect(FinanceReviewedInstrumentMetadata.apply(to: instrument, entries: [mapping]).tradingViewSymbol == "NYSE:EX")
    let changed = FinanceInstrument(id: "fin_listing", name: "Example", symbol: "NEW", kind: "security", providerID: "BBG_EX")
    #expect(FinanceReviewedInstrumentMetadata.apply(to: changed, entries: [mapping]).tradingViewSymbol == nil)
    let inactive = FinanceInstrument(id: "fin_listing", name: "Example", symbol: "EX", kind: "security",
      providerID: "BBG_EX", mic: "XNYS", shareClassFIGI: "BBG_CLASS", compositeFIGI: "BBG_COMPOSITE",
      tradingViewSymbol: "NYSE:EX", isActive: false)
    #expect(FinanceReviewedInstrumentMetadata.apply(to: inactive, entries: [mapping]).tradingViewSymbol == nil)
    #expect(FinanceReviewedInstrumentMetadata.apply(to: inactive, entries: []).tradingViewSymbol == nil)
    #expect(FinanceReviewedInstrumentMetadata.apply(to: inactive, entries: [mapping]).mic == "XNYS")
    #expect(FinanceReviewedInstrumentMetadata.apply(to: inactive, entries: [mapping]).shareClassFIGI == "BBG_CLASS")
    #expect(FinanceReviewedInstrumentMetadata.apply(to: inactive, entries: [mapping]).compositeFIGI == "BBG_COMPOSITE")
    #expect(FinanceReviewedInstrumentMetadata.verifiedInstrumentIDs(domain: "example.com", account: nil, entries: [mapping]) == ["fin_listing"])
    #expect(FinanceReviewedInstrumentMetadata.verifiedInstrumentIDs(domain: "untrusted.example.com", account: nil, entries: [mapping]).isEmpty)
  }
}
