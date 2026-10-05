import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import WireCore
@testable import FinanceCore

private let apple = FinanceInstrument(id: "apple", name: "Apple Inc", symbol: "AAPL", kind: "equity",
  providerID: "figi-apple", exchange: "US", aliases: ["Apple"], sectorIDs: ["technology"])
private let cat = FinanceInstrument(id: "cat", name: "Caterpillar", symbol: "CAT", kind: "equity", providerID: "figi-cat")

@Test func ambiguousWordsDoNotResolve() {
  let analysis = FinanceResolver.analyze(title: "AI and CAT are ordinary words", catalog: [apple, cat])
  #expect(analysis.associations.isEmpty)
  #expect(!analysis.eligible)
}
@Test func resolvesNamesAndContextualCashtags() {
  let analysis = FinanceResolver.analyze(title: "Apple announces earnings, $CAT shares rise", catalog: [apple, cat])
  #expect(analysis.eligible)
  #expect(analysis.materiality == "earnings")
  #expect(Set(analysis.associations.map(\.instrumentID)) == ["apple", "cat"])
  #expect(analysis.sectorIDs == ["technology"])
}
@Test func collisionsNeedNamesOrMetadata() {
  let collision = FinanceInstrument(id: "other", name: "Other Listing", symbol: "CAT", kind: "equity", providerID: "other")
  #expect(FinanceResolver.analyze(title: "$CAT stock earnings", catalog: [cat, collision]).associations.isEmpty)
  #expect(FinanceResolver.analyze(title: "$CAT stock earnings", structuredInstrumentIDs: ["cat"],
    catalog: [cat, collision]).associations.map(\.instrumentID) == ["cat"])
}
@Test func macroReportingNeedsNoInstrument() {
  let analysis = FinanceResolver.analyze(title: "Central bank raises interest rate as inflation grows", catalog: [])
  #expect(analysis.eligible)
  #expect(analysis.associations.isEmpty)
}
private func candidate(_ id: String, score: Double, instrument: Bool = false, global: Bool = false) -> FinanceRankCandidate {
  .init(item: .init(itemID: id, canonicalURL: "https://news.example/" + id, representativeURI: nil,
    title: id, summary: nil, publishedAt: nil, thumbnailURL: nil,
    source: .init(name: "News", domain: "news.example"), reasons: [], provenance: []),
    analysis: .init(eligible: true, materiality: "reporting", associations: instrument
      ? [.init(instrumentID: "apple", confidence: 1, evidence: ["name"], prominence: 0)] : [],
      sectorIDs: instrument ? ["technology"] : []), baseScore: score, majorGlobal: global)
}
@Test func personalizationGlobalSlotsAndDuplicates() {
  let candidates = [candidate("global", score: 1, global: true)]
    + (1...7).map { candidate("matched-\($0)", score: 10, instrument: true) }
    + [candidate("matched-1", score: 1)]
  let ranked = FinanceRanker.rank(candidates: candidates, instrumentIDs: ["apple"], sectorIDs: ["technology"])
  #expect(ranked.count == 8)
  #expect(ranked[4].item.itemID == "global")
  let pair = [candidate("neutral", score: 13), candidate("selected", score: 10, instrument: true)]
  #expect(FinanceRanker.rank(candidates: pair).first?.item.itemID == "neutral")
  #expect(FinanceRanker.rank(candidates: pair, instrumentIDs: ["apple"], sectorIDs: ["technology"]).first?.item.itemID == "selected")
}
@Test func cursorBindsContextAndExpiry() throws {
  let codec = try FinanceCursorCodec(secret: String(repeating: "a", count: 32))
  let now = Date(timeIntervalSince1970: 1000)
  let cursor = FinanceCursor(generationID: "g", language: "en", preferenceFingerprint: "p", viewerScope: "did:x", nextOrdinal: 5, expiresAt: now.addingTimeInterval(100))
  let encoded = try codec.encode(cursor)
  #expect(try codec.decode(encoded, language: "en", preferenceFingerprint: "p", viewerScope: "did:x", now: now) == cursor)
  #expect(throws: FinanceCursorError.invalidContext) { try codec.decode(encoded, language: "fr", preferenceFingerprint: "p", viewerScope: "did:x", now: now) }
  #expect(throws: FinanceCursorError.invalidContext) { try codec.decode(encoded, language: "en", preferenceFingerprint: "q", viewerScope: "did:x", now: now) }
  #expect(throws: FinanceCursorError.invalidContext) { try codec.decode(encoded, language: "en", preferenceFingerprint: "p", viewerScope: "did:y", now: now) }
  #expect(throws: FinanceCursorError.expired) { try codec.decode(encoded, language: "en", preferenceFingerprint: "p", viewerScope: "did:x", now: now.addingTimeInterval(100)) }
  #expect(throws: FinanceCursorError.invalidSignature) { try codec.decode(encoded + "A", language: "en", preferenceFingerprint: "p", viewerScope: "did:x", now: now) }
}
@Test func identitiesAndFingerprintsAreStable() {
  #expect(FinanceIdentity.instrumentID(provider: "figi", nativeID: "a") != FinanceIdentity.instrumentID(provider: "figi", nativeID: "b"))
  #expect(FinanceIdentity.preferenceFingerprint(instrumentIDs: ["b", "a", "a"], sectorIDs: ["tech"])
    == FinanceIdentity.preferenceFingerprint(instrumentIDs: ["a", "b"], sectorIDs: ["tech"]))
  #expect(FinanceIdentity.selectionRecordKey(kind: "instrument", id: "a").count == 64)
}
@Test func catalogSymbolChangePreservesIdentityAndDropsUnverifiedWidget() throws {
  let old = FinanceInstrument(id: "same", name: "Old", symbol: "OLD", kind: "equity", providerID: "figi", tradingViewSymbol: "EX:OLD")
  let new = FinanceInstrument(id: "same", name: "New", symbol: "NEW", kind: "equity", providerID: "figi")
  let snapshot = try FinanceCatalogRefresh.candidate(previous: .init(version: "v", generatedAt: Date(), instruments: [old]), securities: [new], crypto: [], reviewed: [])
  #expect(snapshot.instruments.first?.id == "same")
  #expect(snapshot.instruments.first?.aliases == ["OLD"])
  #expect(snapshot.instruments.first?.tradingViewSymbol == nil)
  #expect(throws: FinanceProviderError.invalidResponse) { try FinanceCatalogRefresh.candidate(previous: snapshot, securities: [new, new], crypto: [], reviewed: []) }
}

private actor StubTransport: FinanceHTTPTransport {
  let body: Data
  let status: Int
  var requests: [URLRequest] = []
  init(_ body: String, status: Int = 200) { self.body = Data(body.utf8); self.status = status }
  func data(for request: URLRequest) async throws -> (Data, Int) {
    requests.append(request); return (body, status)
  }
  func lastRequest() -> URLRequest? { requests.last }
}
@Test func openFIGIUsesV3AndNativeIdentity() async throws {
  let transport = StubTransport("{\"data\":[{\"figi\":\"BBG0001\",\"name\":\"Example Inc\",\"ticker\":\"EX\",\"exchCode\":\"US\",\"securityType2\":\"Common Stock\"}]}")
  let adapter = OpenFIGIAdapter(transport: transport)
  let results = try await adapter.search(query: "Example")
  #expect(results.count == 1)
  #expect(results.first?.id == FinanceIdentity.instrumentID(provider: "openfigi", nativeID: "BBG0001"))
  #expect(results.first?.tradingViewSymbol == nil)
  #expect(await transport.lastRequest()?.url?.path == "/v3/search")
}
@Test func cryptoSymbolCollisionsRemainDistinct() async throws {
  let transport = StubTransport("[{\"id\":\"asset-one\",\"symbol\":\"coin\",\"name\":\"One\"},{\"id\":\"asset-two\",\"symbol\":\"coin\",\"name\":\"Two\"}]")
  let results = try await CoinGeckoAdapter(transport: transport).instruments()
  #expect(results.count == 2)
  #expect(results[0].id != results[1].id)
  #expect(results[0].symbol == results[1].symbol)
}
@Test func providerFailureDoesNotReturnEmptyCatalog() async {
  let adapter = CoinGeckoAdapter(transport: StubTransport("{}", status: 429))
  await #expect(throws: FinanceProviderError.httpStatus(429)) { try await adapter.instruments() }
}

@Test func materialReportingOutranksRoutineChatter() {
  let base = candidate("event", score: 10)
  let event = FinanceRankCandidate(item: base.item,
    analysis: .init(eligible: true, materiality: "earnings", associations: [], sectorIDs: []), baseScore: 10)
  let other = candidate("chatter", score: 20)
  let chatter = FinanceRankCandidate(item: other.item,
    analysis: .init(eligible: true, materiality: "price-chatter", associations: [], sectorIDs: []), baseScore: 20)
  #expect(FinanceRanker.rank(candidates: [chatter, event]).first?.item.itemID == "event")
}

@Test func conservativeCoverageGroupingRetainsLaterUpdates() {
  func story(_ id: String, date: Date) -> FinanceRankCandidate {
    let base = candidate(id, score: 10, instrument: true)
    let item = WireFeedItem(itemID: id, canonicalURL: base.item.canonicalURL, representativeURI: nil,
      title: "Apple reports quarterly earnings", summary: nil, publishedAt: date, thumbnailURL: nil,
      source: base.item.source, reasons: [], provenance: [])
    return .init(item: item, analysis: base.analysis, baseScore: 10)
  }
  let now = Date(timeIntervalSince1970: 10000)
  let results = FinanceRanker.rank(candidates: [story("a", date: now), story("b", date: now),
    story("c", date: now.addingTimeInterval(7 * 3600))])
  #expect(results.map { $0.item.itemID } == ["a", "c"])
}

@Test func genericAnnouncementsAreNotFinanceAndListingsNeedDisambiguation() {
  #expect(!FinanceResolver.analyze(title: "Museum announces new exhibit", catalog: [apple]).eligible)
  let other = FinanceInstrument(id: "apple-uk", name: "Apple Inc", symbol: "AAPL", kind: "equity",
    providerID: "figi-uk", exchange: "LN", aliases: ["Apple"])
  #expect(FinanceResolver.analyze(title: "Apple announces earnings", catalog: [apple, other]).associations.isEmpty)
  let resolved = FinanceResolver.analyze(title: "US:AAPL reports earnings", catalog: [apple, other])
  #expect(resolved.associations.map(\.instrumentID) == ["apple"])
}

@Test func rateLimitsNeverTriggerImmediateRetries() async throws {
  let transport = StubTransport("{}", status: 429)
  let retrying = FinanceRetryingTransport(base: transport)
  let response = try await retrying.data(for: URLRequest(url: URL(string: "https://api.openfigi.com/v3/mapping")!))
  #expect(response.1 == 429)
  #expect(await transport.requests.count == 1)
  await #expect(throws: FinanceProviderError.invalidRequest) {
    try await OpenFIGIAdapter(transport: transport).mapFIGIs(["1", "2", "3", "4", "5", "6"])
  }
}

@Test func namedRankingRetainsMaterialityAndDedupWithoutGlobalReservation() {
  let baseline = candidate("earnings", score: 9)
  let earnings = FinanceRankCandidate(item: baseline.item,
    analysis: .init(eligible: true, materiality: "earnings", associations: [], sectorIDs: []), baseScore: 9)
  let matched = (1...6).map { candidate("matched-\($0)", score: 10, instrument: true) }
  let global = candidate("global", score: 1, global: true)
  let ranked = FinanceRanker.rank(candidates: matched + [earnings, global, matched[0]], reserveGlobal: false)
  #expect(ranked.first?.item.itemID == "earnings")
  #expect(ranked.count == 8)
  #expect(ranked.last?.item.itemID == "global")
  #expect(ranked[4].item.itemID != "global")
}
