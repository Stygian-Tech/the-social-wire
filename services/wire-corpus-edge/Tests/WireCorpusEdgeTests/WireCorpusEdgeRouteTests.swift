import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import Testing
import WireCore
@testable import WireCorpusEdge

@Suite("The Wire Corpus Edge routes")
struct WireCorpusEdgeRouteTests {
  private let secret = String(repeating: "e", count: 32)
  private let serviceID = "development-appview"

  @Test("unsigned calls fail before touching the corpus store")
  func unsigned() async throws {
    let store = TestWireCorpusStore()
    let app = application(store: store)
    try await app.test(.router) { client in
      let response = try await client.execute(
        uri: "/internal/wire/v1/catalog",
        method: .get
      )
      #expect(response.status == .unauthorized)
    }
    #expect(await store.catalogCalls == 0)
  }

  @Test("signed responses are presentation-only and cannot be replayed")
  func signedAndReplay() async throws {
    let store = TestWireCorpusStore()
    let app = application(store: store)
    let target = "/internal/wire/v1/catalog"
    let headers = try requestHeaders(target: target)
    try await app.test(.router) { client in
      let first = try await client.execute(uri: target, method: .get, headers: headers)
      #expect(first.status == .ok)
      #expect(first.headers[.cacheControl] == "no-store")
      #expect(first.headers[HTTPField.Name("X-Wire-Corpus-Contract")!] == "2")
      #expect(first.headers[.accessControlAllowOrigin] == nil)

      let replay = try await client.execute(uri: target, method: .get, headers: headers)
      #expect(replay.status == .unauthorized)
    }
    #expect(await store.catalogCalls == 1)
  }

  @Test("viewer credentials are rejected even with valid service trust")
  func viewerCredentialsRejected() async throws {
    let store = TestWireCorpusStore()
    let target = "/internal/wire/v1/catalog"
    var headers = try requestHeaders(target: target)
    headers[.authorization] = "DPoP viewer-token"
    let requestHeaders = headers
    try await application(store: store).test(.router) { client in
      let response = try await client.execute(uri: target, method: .get, headers: requestHeaders)
      #expect(response.status == .unauthorized)
    }
    #expect(await store.catalogCalls == 0)
  }

  @Test("duplicate query keys fail closed after signature verification")
  func duplicateQueryRejected() async throws {
    let store = TestWireCorpusStore()
    let target = "/internal/wire/v1/feed?language=en&limit=5&limit=50"
    let headers = try requestHeaders(target: target)
    try await application(store: store).test(.router) { client in
      let response = try await client.execute(uri: target, method: .get, headers: headers)
      #expect(response.status == .badRequest)
    }
    #expect(await store.feedCalls == 0)
  }

  @Test("signed edition route returns the bounded internal edition")
  func edition() async throws {
    let store = TestWireCorpusStore()
    let target = "/internal/wire/v1/edition?language=en&region=outside-us"
    let headers = try requestHeaders(target: target)
    try await application(store: store).test(.router) { client in
      let response = try await client.execute(uri: target, method: .get, headers: headers)
      #expect(response.status == .ok)
      #expect(response.headers[HTTPField.Name("X-Wire-Corpus-Contract")!] == "2")
      #expect(response.body.readableBytes > 0)
    }
    #expect(await store.editionCalls == 1)
    #expect(await store.lastEditionRegion == .outsideUnitedStates)
  }

  private func application(store: TestWireCorpusStore) -> Application<RouterResponder<WireCorpusEdgeRequestContext>> {
    let config = WireCorpusEdgeConfig(
      databaseURL: "postgresql://unused",
      sharedSecret: secret,
      allowedServiceID: serviceID,
      maximumConnections: 2
    )
    return Application(
      router: WireCorpusEdgeRouterBuilder.router(
        store: store,
        config: config,
        logger: Logger(label: "wire-corpus-edge.tests")
      ),
      configuration: .init(address: .hostname("127.0.0.1", port: 0))
    )
  }

  private func requestHeaders(target: String) throws -> HTTPFields {
    let trust = try WireCorpusServiceTrust.signedHeaders(
      secret: secret,
      serviceID: serviceID,
      method: "GET",
      target: target
    )
    var headers = HTTPFields()
    headers[HTTPField.Name(WireCorpusServiceTrust.serviceHeaderName)!] = trust.serviceID
    headers[HTTPField.Name(WireCorpusServiceTrust.timestampHeaderName)!] = trust.timestamp
    headers[HTTPField.Name(WireCorpusServiceTrust.nonceHeaderName)!] = trust.nonce
    headers[HTTPField.Name(WireCorpusServiceTrust.signatureHeaderName)!] = trust.signature
    return headers
  }
}

private actor TestWireCorpusStore: WireCorpusStoring {
  private(set) var feedCalls = 0
  private(set) var editionCalls = 0
  private(set) var lastEditionRegion: WireViewerRegion?
  private(set) var catalogCalls = 0

  func ping() async throws {}
  func requireFreshBaseline(now: Date) async throws {}

  func feed(
    language: String,
    generationID: UUID?,
    startOrdinal: Int,
    limit: Int,
    now: Date
  ) async throws -> WireCorpusPage {
    feedCalls += 1
    return WireCorpusPage(
      generationID: UUID().uuidString.lowercased(),
      generatedAt: now,
      language: language,
      source: .ranked,
      degraded: false,
      rows: [],
      exhausted: true
    )
  }

  func edition(
    language: String,
    region: WireViewerRegion?,
    now: Date
  ) async throws -> WireEdition {
    editionCalls += 1
    lastEditionRegion = region
    return WireEditionAssembler.assemble(
      generationID: UUID().uuidString.lowercased(),
      generatedAt: now,
      language: language,
      source: .ranked,
      degraded: false,
      rankedItems: []
    )
  }

  func item(id: String, now: Date) async throws -> WireCorpusItem? { nil }

  func catalog(now: Date) async throws -> WireCorpusCatalog {
    catalogCalls += 1
    return WireCorpusCatalog(
      available: true,
      supportedLanguages: ["en"],
      latestGenerationID: UUID().uuidString.lowercased(),
      generatedAt: now
    )
  }
}
