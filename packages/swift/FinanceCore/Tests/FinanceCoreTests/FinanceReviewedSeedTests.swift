import Testing
@testable import FinanceCore

struct FinanceReviewedSeedTests {
  @Test("reviewed seed company names resolve without cashtags only in business context")
  func seedNames() {
    let rows: [(String,String,String,String,String)] = [
      ("BBG000B9Y5X2","APPLE INC","AAPL","Apple reports strong earnings","technology"),
      ("BBG000BCM9N1","TOYOTA MOTOR CORP","7203","Toyota reports increased automotive sales","consumer"),
      ("BBG000BS1N49","HSBC HOLDINGS PLC","HSBA","HSBC increases revenue after bank merger","financials")]
    for (figi,name,symbol,headline,sector) in rows {
      let raw = FinanceInstrument(id: FinanceIdentity.instrumentID(provider: "openfigi", nativeID: figi),
        name: name,symbol: symbol,kind: "Common Stock",providerID: figi)
      let reviewed = FinanceReviewedInstrumentMetadata.apply(to: raw)
      #expect(reviewed.sectorIDs == [sector])
      #expect(reviewed.tradingViewSymbol == nil)
      let analysis = FinanceResolver.analyze(title: headline,catalog: [reviewed])
      #expect(analysis.eligible)
      #expect(analysis.associations.first?.instrumentID == raw.id)
      #expect(analysis.associations.first?.confidence == 0.95)
    }
    let apple = FinanceReviewedInstrumentMetadata.apply(to: .init(id: FinanceIdentity.instrumentID(provider: "openfigi",nativeID: "BBG000B9Y5X2"),name: "APPLE INC",symbol: "AAPL",kind: "Common Stock",providerID: "BBG000B9Y5X2"))
    let leadership = FinanceResolver.analyze(title: "Apple names a new CEO", catalog: [apple])
    #expect(leadership.eligible)
    #expect(leadership.materiality == "leadership")
    #expect(leadership.associations.first?.instrumentID == apple.id)
    #expect(!FinanceResolver.analyze(title: "Apple pie announces its arrival", catalog: [apple]).eligible)
    #expect(!FinanceResolver.analyze(title: "Apple pie launches a new flavor for the picnic",catalog: [apple]).eligible)
  }
  @Test("reviewed aliases never apply to another listing, changed symbol or mismatched provider")
  func identityGuards() {
    let id = FinanceIdentity.instrumentID(provider: "openfigi",nativeID: "BBG000B9Y5X2")
    for raw in [
      FinanceInstrument(id: "different-listing",name: "APPLE INC",symbol: "AAPL",kind: "Common Stock",providerID: "BBG000B9Y5X2"),
      FinanceInstrument(id: id,name: "APPLE INC",symbol: "NEW",kind: "Common Stock",providerID: "BBG000B9Y5X2"),
      FinanceInstrument(id: id,name: "APPLE INC",symbol: "AAPL",kind: "Common Stock",providerID: "other-figi")
    ] {
      let reviewed = FinanceReviewedInstrumentMetadata.apply(to: raw)
      #expect(reviewed.aliases.isEmpty)
      #expect(reviewed.sectorIDs.isEmpty)
      #expect(reviewed.id == raw.id)
    }
  }
}
