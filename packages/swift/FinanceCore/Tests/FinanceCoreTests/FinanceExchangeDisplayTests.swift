import Foundation
import Testing
@testable import FinanceCore

@Suite("Finance exchange presentation")
struct FinanceExchangeDisplayTests {
  private func instrument(_ exchange: String?, providerID: String = "listing", composite: String? = "composite") -> FinanceInstrument {
    .init(id: "stable-id", name: "Example", symbol: "EX", kind: "Common Stock", providerID: providerID,
      exchange: exchange, compositeFIGI: composite)
  }

  @Test func distinguishesVenuesCompositesAndUnknownCodes() {
    #expect(instrument("UW").exchangeLabel == "Nasdaq Global Select Market (UW)")
    #expect(instrument("LN").exchangeLabel == "London Stock Exchange (LN)")
    #expect(instrument("US").exchangeLabel == "United States Composite (US)")
    #expect(instrument("RO").exchangeLabel == "Romania Composite (RO)")
    #expect(instrument("JP").exchangeLabel == "Japan Composite (JP)")
    #expect(instrument("LN", providerID: "composite").exchangeLabel == "United Kingdom Composite (LN)")
    #expect(instrument("XYZ").exchangeLabel == "Exchange: XYZ")
    #expect(instrument(nil).exchangeLabel == nil)
    #expect(instrument("LN").tradingViewSymbol == nil)
  }

  @Test func oldSnapshotsReceiveCurrentReviewedLabelsAndPreserveIdentity() throws {
    let original = instrument("UN")
    let encoded = try JSONEncoder().encode(original)
    var oldSnapshot = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(oldSnapshot["exchangeName"] as? String == "New York Stock Exchange")
    oldSnapshot.removeValue(forKey: "exchangeName")
    let restored = try JSONDecoder().decode(FinanceInstrument.self, from: JSONSerialization.data(withJSONObject: oldSnapshot))
    #expect(restored == original)
    #expect(restored.exchangeLabel == "New York Stock Exchange (UN)")
    let feeds = FinanceNamedFeeds.catalog(instruments: [restored]).filter { $0.kind == "instrument" }
    #expect(feeds.first?.id == "instrument:stable-id")
    #expect(feeds.first?.title == "$EX · Example · New York Stock Exchange (UN)")
  }

  @Test func serializedLabelsCannotOverrideReviewedIdentity() throws {
    let encoded = try JSONEncoder().encode(instrument("US"))
    var snapshot = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    snapshot["exchangeName"] = "Nasdaq"
    let restored = try JSONDecoder().decode(FinanceInstrument.self, from: JSONSerialization.data(withJSONObject: snapshot))
    #expect(restored.exchangeName == "United States Composite")
  }
}
