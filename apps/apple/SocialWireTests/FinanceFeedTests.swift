import Foundation
import Testing
@testable import SocialWire

@Suite("Finance Feed")
struct FinanceFeedTests {
    @Test("asset kinds round-trip while legacy feeds remain visible")
    func assetKindFeeds() throws {
        for (kind, group, icon) in [("stock", "Stocks", "chart.line.uptrend.xyaxis"),
                                   ("etf", "ETFs", "square.stack.3d.up"),
                                   ("crypto", "Crypto", "bitcoinsign.circle"),
                                   ("index", "Indices", "chart.bar.xaxis"),
                                   ("commodity", "Commodities", "shippingbox")] {
            let feed = FinanceNamedFeed(id: "instrument:asset", title: "Asset", kind: "instrument",
                                        instrumentIDs: ["asset"], sectorIDs: [], description: "", assetKind: kind)
            #expect(try JSONDecoder().decode(FinanceNamedFeed.self, from: JSONEncoder().encode(feed)).assetKind == kind)
            #expect(feed.pickerGroup == group)
            #expect(feed.systemImage == icon)
            #expect(feed.isVisible(hideCrypto: false))
            #expect(feed.isVisible(hideCrypto: true) == (kind != "crypto"))
        }
        let legacy = try JSONDecoder().decode(FinanceNamedFeed.self, from: Data(#"{"id":"legacy","title":"Legacy","kind":"instrument","instrumentIDs":["legacy"],"sectorIDs":[],"description":""}"#.utf8))
        #expect(legacy.assetKind == nil)
        #expect(legacy.isVisible(hideCrypto: true))
        #expect(FinanceNamedFeed.all.isVisible(hideCrypto: true))
    }

    @Test("crypto exclusion remains explicit in server query and cache context")
    func cryptoQueryIsolation() {
        let query = SocialWireGatewayClient.financeQuery(language: "en", feed: "asset:crypto", cursor: "opaque", hideCrypto: true)
        #expect(query["hideCrypto"] == "true")
        #expect(query["cursor"] == "opaque")
        #expect(query["feed"] == "asset:crypto")
        #expect(SocialWireGatewayClient.financeQuery(language: "en", feed: "finance", cursor: nil, hideCrypto: false)["hideCrypto"] == "false")
        #expect(SocialWireGatewayClient.financeQuery(language: "en", feed: "finance", cursor: nil, hideCrypto: nil)["hideCrypto"] == nil)
        let visible = FinanceCacheIdentity.key(viewer: "v", language: "en", region: "us", moderation: "m", preferences: "p", generation: "g")
        #expect(visible != FinanceCacheIdentity.key(viewer: "v", language: "en", region: "us", moderation: "m", preferences: "p", generation: "g", hideCrypto: true))
    }

    @Test("exchange labels use provider names without guessing exchange codes")
    func exchangeLabels() throws {
        var instrument = FinanceInstrument(id: "apple", name: "Apple", symbol: "AAPL", kind: "equity", providerID: "figi", exchange: "UW", currency: "USD", aliases: [], sectorIDs: [], tradingViewSymbol: "NASDAQ:AAPL", isActive: true)
        #expect(instrument.exchangeLabel == "Exchange: UW")
        instrument.exchangeName = "Nasdaq"
        #expect(instrument.exchangeLabel == "Nasdaq (UW)")
        let restored = try JSONDecoder().decode(FinanceInstrument.self, from: JSONEncoder().encode(instrument))
        #expect(restored.exchangeName == "Nasdaq")
        #expect(restored.exchange == "UW")
        instrument.exchangeName = "  "
        #expect(instrument.exchangeLabel == "Exchange: UW")
        let noCode = FinanceInstrument(id: "crypto", name: "Coin", symbol: "COIN", kind: "crypto", providerID: "coin", exchange: nil, currency: nil, aliases: [], sectorIDs: [], tradingViewSymbol: nil, isActive: true, exchangeName: "Reviewed Venue")
        #expect(noCode.exchangeLabel == "Reviewed Venue")
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(instrument)) as! [String: Any]
        old.removeValue(forKey: "exchangeName")
        #expect(try JSONDecoder().decode(FinanceInstrument.self, from: JSONSerialization.data(withJSONObject: old)).exchangeLabel == "Exchange: UW")
    }

    @Test("instrument overview uses exact singleton identities and validated associations")
    func overviewIdentity() {
        let instrument = FinanceInstrument(id: "apple", name: "Apple", symbol: "AAPL", kind: "equity", providerID: "figi", exchange: "XNAS", currency: "USD", aliases: [], sectorIDs: [], tradingViewSymbol: "NASDAQ:AAPL", isActive: true)
        let feed = FinanceNamedFeed(id: "instrument:apple", title: "Apple", kind: "instrument", instrumentIDs: ["apple"], sectorIDs: [], description: "")
        #expect(feed.resolvedInstrument(metadata: ["apple": instrument], items: []) == instrument)
        #expect(feed.resolvedInstrument(metadata: ["other": instrument], items: []) == nil)
        let group = FinanceNamedFeed(id: "group:mag7", title: "Mag7", kind: "group", instrumentIDs: ["apple"], sectorIDs: [], description: "")
        #expect(group.resolvedInstrument(metadata: ["apple": instrument], items: []) == nil)
    }

    @Test("earnings coverage is server-classified, exact, confident, safe, and deduplicated")
    func earningsCoverage() throws {
        let instrument = FinanceInstrument(id: "apple", name: "Apple", symbol: "AAPL", kind: "equity", providerID: "figi", exchange: nil, currency: nil, aliases: [], sectorIDs: [], tradingViewSymbol: nil, isActive: true)
        func item(_ id: String, url: String, materiality: String?, confidence: Int = 9500) -> FinanceFeedItem {
            FinanceFeedItem(story: WireFeedItem(itemId: id, canonicalUrl: url, representativeUri: nil, title: "Earnings Call", summary: nil, publishedAt: nil, thumbnailUrl: nil, source: WireFeedSource(name: "News", domain: "example.com"), reasons: [], provenance: []), instruments: [.init(instrument: instrument, confidenceBps: confidence, prominence: 1)], sectorIDs: [], majorGlobal: false, materiality: materiality)
        }
        let good = item("good", url: "https://example.com/report", materiality: "earnings")
        let items = [good, item("duplicate", url: good.story.canonicalUrl, materiality: "filing"),
            item("keyword", url: "https://example.com/keyword", materiality: nil),
            item("low", url: "https://example.com/low", materiality: "filing", confidence: 8999),
            item("unsafe", url: "javascript:alert(1)", materiality: "earnings")]
        #expect(FinanceFeedItem.reportCoverage(in: items, instrumentID: "apple").map(\.id) == ["good"])
        #expect(FinanceFeedItem.reportCoverage(in: items, instrumentID: "other").isEmpty)
        #expect(try JSONDecoder().decode(FinanceFeedItem.self, from: JSONEncoder().encode(good)).materiality == "earnings")
        let old = item("old", url: "https://example.com/old", materiality: nil)
        #expect(try JSONDecoder().decode(FinanceFeedItem.self, from: JSONEncoder().encode(old)).materiality == nil)
    }

    @Test("selection keys distinguish kind and canonical identity")
    func selectionKeys() {
        #expect(FinanceSelectionRecord.key(kind: "instrument", reference: "a").count == 64)
        #expect(FinanceSelectionRecord.key(kind: "instrument", reference: "a") != FinanceSelectionRecord.key(kind: "sector", reference: "a"))
        #expect(FinanceSelectionRecord.key(kind: "instrument", reference: "a") == FinanceSelectionRecord.key(kind: "instrument", reference: "a"))
    }

    @Test("cache identity isolates every serving dimension")
    func cacheIdentity() {
        let baseline = FinanceCacheIdentity.key(viewer: "viewer", language: "en", region: "us", moderation: "m", preferences: "p", generation: "g")
        for index in 0..<6 {
            var values = ["viewer", "en", "us", "m", "p", "g"]
            values[index] += "2"
            #expect(baseline != FinanceCacheIdentity.key(viewer: values[0], language: values[1], region: values[2], moderation: values[3], preferences: values[4], generation: values[5]))
        }
    }

    @Test("named feed caches cannot share a continuation context")
    func namedFeedCacheIsolation() {
        let global = FinanceCacheIdentity.key(viewer: "v", language: "en", region: "us", moderation: "m", preferences: "p", generation: "g")
        let apple = FinanceCacheIdentity.key(viewer: "v", language: "en", region: "us", moderation: "m", preferences: "p", generation: "g", feed: "instrument:apple")
        let microsoft = FinanceCacheIdentity.key(viewer: "v", language: "en", region: "us", moderation: "m", preferences: "p", generation: "g", feed: "instrument:microsoft")
        #expect(global != apple)
        #expect(apple != microsoft)
    }

    @Test("named membership is decoded from the server catalog")
    func namedFeedCatalog() throws {
        let json = Data(#"{"id":"group:mag7","title":"Mag7","kind":"group","instrumentIDs":["apple","microsoft"],"sectorIDs":[],"description":"Reviewed Group"}"#.utf8)
        let feed = try JSONDecoder().decode(FinanceNamedFeed.self, from: json)
        #expect(feed.id == "group:mag7")
        #expect(feed.instrumentIDs == ["apple", "microsoft"])
        #expect(feed.sectorIDs.isEmpty)
        #expect(try JSONDecoder().decode(FinanceNamedFeed.self, from: JSONEncoder().encode(feed)) == feed)
    }

    @Test("feed search accepts tickers, names and industry descriptions")
    func namedFeedSearch() {
        let feed = FinanceNamedFeed(id: "instrument:apple", title: "Apple (AAPL)", kind: "instrument",
                                    instrumentIDs: ["apple"], sectorIDs: [], description: "Technology Company")
        #expect(feed.matchesSearch("  $aapl  "))
        #expect(feed.matchesSearch("apple"))
        #expect(feed.matchesSearch("technology"))
        #expect(feed.matchesSearch(""))
        #expect(!feed.matchesSearch("pharma"))
    }

    @Test("cashtags require explicit insertion and retain editable text within limits")
    func cashtags() {
        #expect(FinancePersonalization.insertingCashtag("AAPL", into: "Thoughts") == "Thoughts $AAPL")
        #expect(FinancePersonalization.insertingCashtag("AAPL", into: "Already $aapl") == "Already $aapl")
        #expect(FinancePersonalization.insertingCashtag("AAPL", into: String(repeating: "x", count: 299)).count == 299)
        #expect(FinancePersonalization.insertingCashtag("<script>", into: "Text") == "Text")
        #expect(FinancePersonalization.insertingCashtag("AAPL", into: "$AAPLX") == "$AAPLX $AAPL")
    }

    @Test("old preferences default compatibly and Finance settings round trip")
    func preferences() throws {
        var prefs = try JSONDecoder().decode(ReaderFeedPreferences.self, from: Data("{}".utf8))
        #expect(prefs.showFinance)
        #expect(!prefs.hideFinancePerformance)
        #expect(!prefs.hideFinanceCrypto)
        prefs.showFinance = false
        prefs.hideFinancePerformance = true
        prefs.hideFinanceCrypto = true
        let restored = try JSONDecoder().decode(ReaderFeedPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(restored == prefs)
        #expect(NewsPrimaryFeed.defaultFeeds.count == 4)
        #expect(NewsTab.available(wire: true, circle: true).contains(.finance) == false)
    }
    @Test("loaded preferences reorder matches while retaining a global fifth story")
    func personalization() {
        let instrument = FinanceInstrument(id: "equity", name: "Company", symbol: "ABC", kind: "equity", providerID: "figi", exchange: "XNAS", currency: "USD", aliases: [], sectorIDs: ["tech"], tradingViewSymbol: nil, isActive: true)
        let items = (0..<10).map { index in
            FinanceFeedItem(story: WireFeedItem(itemId: "story-\(index)", canonicalUrl: "https://example.com/\(index)", representativeUri: nil, title: "Story", summary: nil, publishedAt: nil, thumbnailUrl: nil, source: WireFeedSource(name: "News", domain: "example.com"), reasons: [], provenance: []), instruments: index == 3 ? [FinanceInstrumentMatch(instrument: instrument, confidenceBps: 10000, prominence: 1)] : [], sectorIDs: [], majorGlobal: index == 9)
        }
        let selection = FinanceSelectionRecord(kind: "instrument", reference: "equity", createdAt: "now", updatedAt: "now")
        let ordered = FinancePersonalization.reorder(items, selections: [selection])
        #expect(ordered.first?.id == "story-3")
        #expect(ordered[4].majorGlobal)
        #expect(Set(ordered.map(\.id)).count == 10)
    }

    @Test("suggestions retain only three confident associations in article prominence order")
    func suggestions() {
        let instrument = FinanceInstrument(id: "a", name: "A", symbol: "A", kind: "equity", providerID: "a", exchange: nil, currency: nil, aliases: [], sectorIDs: [], tradingViewSymbol: nil, isActive: true)
        let story = WireFeedItem(itemId: "story", canonicalUrl: "https://example.com", representativeUri: nil, title: "Story", summary: nil, publishedAt: nil, thumbnailUrl: nil, source: WireFeedSource(name: "News", domain: "example.com"), reasons: [], provenance: [])
        let matches = (0..<5).map { index in
            FinanceInstrumentMatch(instrument: FinanceInstrument(id: "\(index)", name: instrument.name, symbol: instrument.symbol, kind: instrument.kind, providerID: instrument.providerID, exchange: nil, currency: nil, aliases: [], sectorIDs: [], tradingViewSymbol: nil, isActive: true), confidenceBps: index == 0 ? 4000 : 9500, prominence: Double(index))
        }
        let item = FinanceFeedItem(story: story, instruments: Array(matches.reversed()), sectorIDs: [], majorGlobal: false)
        #expect(item.suggestions.map(\.id) == ["1", "2", "3"])
    }

}
