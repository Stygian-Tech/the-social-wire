import Foundation
import Testing
@testable import FinanceCore

@Suite("Finance asset feeds and crypto exclusions")
struct FinanceAssetFeedsTests {
  @Test func assetGroupsUseCanonicalMatchesAndPreserveIdentity() throws {
    let etf = FinanceReviewedInstrumentMetadata.apply(to: .init(id: FinanceIdentity.instrumentID(provider: "openfigi", nativeID: "BBG000BDTBL9"), name: "SPDR S&P 500 ETF TRUST", symbol: "SPY", kind: "Mutual Fund", providerID: "BBG000BDTBL9"))
    #expect(etf.kind == "etf")
    let catalog = [etf] + FinanceReviewedCatalog.instruments
    let feeds = FinanceNamedFeeds.catalog(instruments: catalog)
    for kind in ["etf", "crypto", "index"] {
      let feed = try #require(feeds.first { $0.id == "asset:" + kind })
      #expect(feed.assetKind == kind)
      #expect(feed.instrumentIDs.allSatisfy { id in catalog.contains { $0.id == id && FinanceAssetKind.classify($0) == kind } })
      let unrelated = FinanceResolver.analyze(title: "Central bank announces interest rate cut", catalog: catalog)
      #expect(!feed.matches(unrelated, title: "Central bank announces interest rate cut", summary: nil))
    }
    let crypto = try #require(feeds.first { $0.id == "asset:crypto" })
    let bitcoin = FinanceResolver.analyze(title: "Bitcoin price rises after institutional investment", catalog: catalog)
    let ethereum = FinanceResolver.analyze(title: "Ethereum price rises after institutional investment", catalog: catalog)
    #expect(crypto.matches(ethereum, title: "Ethereum price rises after institutional investment", summary: nil))
    #expect(crypto.matches(bitcoin, title: "Bitcoin price rises after institutional investment", summary: nil))
    #expect(FinanceAssetKind.isCryptoStory(title: "Bitcoin price rises after institutional investment", summary: nil, analysis: bitcoin, catalog: catalog))
  }
  @Test func providerGatingAndRefreshDeduplicationRemainIndependent() throws {
    let coins = FinanceReviewedAssets.referenceInstruments.filter { $0.kind == "crypto" }
    let snapshot = try FinanceCatalogRefresh.candidate(previous: nil, securities: [], crypto: coins)
    #expect(Set(snapshot.instruments.map(\.id)).count == snapshot.instruments.count)
    let permitted = FinanceCatalogProviderPolicy(environment: [:]).filter(snapshot.instruments)
    #expect(!permitted.contains { $0.kind == "crypto" })
    #expect(!FinanceNamedFeeds.catalog(instruments: permitted).contains { $0.id == "asset:crypto" })
  }
  @Test func genericCryptoExclusionDoesNotRequireProviderOrRewriteStories() {
    let title = "Bitcoin ETF inflows rise while Microsoft earnings improve"
    let analysis = FinanceResolver.analyze(title: title, catalog: [])
    #expect(FinanceAssetKind.isCryptoStory(title: title, summary: nil, analysis: analysis, catalog: []))
    let bank = FinanceResolver.analyze(title: "Bank earnings improve", catalog: [])
    #expect(!FinanceAssetKind.isCryptoStory(title: "Bank earnings improve", summary: "Read more: Bitcoin investment tips", analysis: bank, catalog: []))
  }
  @Test func assetKindIsOptionalForExistingFeedDecoders() throws {
    let data = Data(#"{"id":"finance","title":"Finance","kind":"all","instrumentIDs":[],"sectorIDs":[],"description":"News"}"#.utf8)
    #expect(try JSONDecoder().decode(FinanceFeedDefinition.self, from: data).assetKind == nil)
  }
}
