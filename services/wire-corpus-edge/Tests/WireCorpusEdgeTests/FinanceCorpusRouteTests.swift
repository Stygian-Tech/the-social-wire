import FinanceCore
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import Testing
import WireCore
@testable import WireCorpusEdge

@Suite("Finance Corpus Edge contract")
struct FinanceCorpusRouteTests {
  private let secret = String(repeating: "f", count: 32)
  private let serviceID = "finance-development"

  @Test("Finance corpus requires service trust and excludes viewer credentials")
  func requiresServiceTrust() async throws {
    let store = FinanceCorpusRouteStore()
    try await application(store).test(.router) { client in
      let target = "/internal/wire/v1/finance?language=en"
      #expect(try await client.execute(uri: target, method: .get).status == .unauthorized)
      var headers = try signed(target)
      headers[.authorization] = "DPoP viewer-credential"
      #expect(try await client.execute(uri: target, method: .get, headers: headers).status == .unauthorized)
    }
    #expect(await store.financeCalls == 0)
  }

  @Test("signed Finance response carries canonical catalog mappings and exact-language generation")
  func signedPresentationContract() async throws {
    let store = FinanceCorpusRouteStore()
    try await application(store).test(.router) { client in
      let target = "/internal/wire/v1/finance?language=fr-CA"
      let headers = try signed(target)
      let response = try await client.execute(uri: target, method: .get, headers: headers)
      #expect(response.status == .ok)
      #expect(response.headers[HTTPField.Name("X-Wire-Corpus-Contract")!] == "3")
      #expect(response.headers[.cacheControl] == "no-store")
      #expect(response.headers[.accessControlAllowOrigin] == nil)
      let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
      let generation = try decoder.decode(FinanceSourceGeneration.self, from: Data(response.body.readableBytesView))
      #expect(generation.language == "fr")
      #expect(generation.instruments.first?.id == "fixture-equity")
      #expect(generation.instruments.first?.tradingViewSymbol == "NASDAQ:FIX")
      #expect(generation.candidates.first?.analysis.associations.first?.instrumentID == "fixture-equity")
      #expect(try await client.execute(uri: target, method: .get, headers: headers).status == .unauthorized)
    }
    #expect(await store.financeCalls == 1)
    #expect(await store.baselineCalls == 1)
  }

  @Test("Finance transport rejects duplicate language and viewer context query parameters")
  func rejectsUnapprovedContext() async throws {
    let store = FinanceCorpusRouteStore()
    try await application(store).test(.router) { client in
      for target in ["/internal/wire/v1/finance?language=en&language=fr", "/internal/wire/v1/finance?language=en&viewerDid=did:example:viewer", "/internal/wire/v1/finance?language=en&preferences=private"] {
        let headers = try signed(target)
        let response = try await client.execute(uri: target, method: .get, headers: headers)
        #expect(response.status == .badRequest)
      }
    }
    #expect(await store.financeCalls == 0)
  }

  @Test("stale baseline prevents Finance candidate disclosure")
  func baselineFailClosed() async throws {
    let store = FinanceCorpusRouteStore(baselineAvailable: false)
    try await application(store).test(.router) { client in
      let target = "/internal/wire/v1/finance?language=en"
      let headers = try signed(target)
      let response = try await client.execute(uri: target, method: .get, headers: headers)
      #expect(response.status == .serviceUnavailable)
    }
    #expect(await store.financeCalls == 0)
    #expect(await store.baselineCalls == 1)
  }

  private func application(_ store: FinanceCorpusRouteStore) -> Application<RouterResponder<WireCorpusEdgeRequestContext>> {
    let config = WireCorpusEdgeConfig(databaseURL: "postgresql://unused", sharedSecret: secret, allowedServiceID: serviceID, maximumConnections: 2)
    return Application(router: WireCorpusEdgeRouterBuilder.router(store: store, config: config, logger: Logger(label: "finance-corpus.test")), configuration: .init(address: .hostname("127.0.0.1", port: 0)))
  }

  private func signed(_ target: String) throws -> HTTPFields {
    let trust = try WireCorpusServiceTrust.signedHeaders(secret: secret, serviceID: serviceID, method: "GET", target: target)
    var fields = HTTPFields()
    fields[HTTPField.Name(WireCorpusServiceTrust.serviceHeaderName)!] = trust.serviceID
    fields[HTTPField.Name(WireCorpusServiceTrust.timestampHeaderName)!] = trust.timestamp
    fields[HTTPField.Name(WireCorpusServiceTrust.nonceHeaderName)!] = trust.nonce
    fields[HTTPField.Name(WireCorpusServiceTrust.signatureHeaderName)!] = trust.signature
    return fields
  }
}

private actor FinanceCorpusRouteStore: WireCorpusStoring {
  private let baselineAvailable: Bool
  private(set) var financeCalls = 0
  private(set) var baselineCalls = 0
  init(baselineAvailable: Bool = true) { self.baselineAvailable = baselineAvailable }
  func ping() async throws {}
  func requireFreshBaseline(now: Date) async throws {
    baselineCalls += 1
    guard baselineAvailable else { throw WireCorpusEdgeStoreError.unavailable }
  }
  func finance(language: String, now: Date) async throws -> FinanceSourceGeneration {
    financeCalls += 1
    let instrument = FinanceInstrument(id: "fixture-equity", name: "Fixture", symbol: "FIX", kind: "equity", providerID: "figi:fixture", tradingViewSymbol: "NASDAQ:FIX")
    let item = WireFeedItem(itemID: "fixture-story", canonicalURL: "https://example.com/finance", representativeURI: nil,
      title: "Fixture Reports Earnings", summary: nil, publishedAt: now, thumbnailURL: nil,
      source: WireItemSource(name: "Example", domain: "example.com"), reasons: [], provenance: [])
    let candidate = FinanceRankCandidate(item: item,
      analysis: FinanceArticleAnalysis(eligible: true, materiality: "earnings",
        associations: [FinanceAssociation(instrumentID: instrument.id, confidence: 0.95, evidence: ["name-or-alias"], prominence: 0)], sectorIDs: []), baseScore: 100)
    return FinanceSourceGeneration(generationId: UUID().uuidString.lowercased(), generatedAt: now,
      expiresAt: now.addingTimeInterval(48 * 3600), language: language, candidates: [candidate], instruments: [instrument])
  }
  func feed(language: String, generationID: UUID?, startOrdinal: Int, limit: Int, fallbackLimit: Int?, now: Date) async throws -> WireCorpusPage { throw WireCorpusEdgeStoreError.unavailable }
  func edition(language: String, region: WireViewerRegion?, fallbackLimit: Int?, now: Date) async throws -> WireCorpusEdition { throw WireCorpusEdgeStoreError.unavailable }
  func item(id: String, now: Date) async throws -> WireCorpusItem? { nil }
  func catalog(now: Date) async throws -> WireCorpusCatalog { throw WireCorpusEdgeStoreError.unavailable }
  func circleCandidates(actorHashes: [String], language: String, since: Date, limit: Int, now: Date) async throws -> WireCorpusCandidateResponse { throw WireCorpusEdgeStoreError.unavailable }
}
