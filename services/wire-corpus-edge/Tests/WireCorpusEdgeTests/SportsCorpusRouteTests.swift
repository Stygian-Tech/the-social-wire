import SportsCore
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import Testing
import WireCore
@testable import WireCorpusEdge

@Suite("Sports Corpus Edge contract")
struct SportsCorpusRouteTests {
  private let secret = String(repeating: "f", count: 32)
  private let serviceID = "sports-development"

  @Test("Sports corpus requires service trust and excludes viewer credentials")
  func requiresServiceTrust() async throws {
    let store = SportsCorpusRouteStore()
    try await application(store).test(.router) { client in
      let target = "/internal/wire/v1/sports?language=en"
      #expect(try await client.execute(uri: target, method: .get).status == .unauthorized)
      var headers = try signed(target)
      headers[.authorization] = "DPoP viewer-credential"
      #expect(try await client.execute(uri: target, method: .get, headers: headers).status == .unauthorized)
    }
    #expect(await store.sportsCalls == 0)
  }

  @Test("optional standings and schedules use signed public context without viewer data")
  func optionalEventContext() async throws {
    let store = SportsCorpusRouteStore()
    try await application(store).test(.router) { client in
      for path in ["standings", "schedules"] {
        let target = "/internal/wire/v1/sports/" + path
        #expect(try await client.execute(uri: target, method: .get).status == .unauthorized)
        let response = try await client.execute(uri: target, method: .get, headers: signed(target))
        #expect(response.status == .ok)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let data = Data(response.body.readableBytesView)
        if path == "standings" {
          let tables = try decoder.decode([SportsStandingSnapshot].self, from: data)
          #expect(tables.first?.rows.first?.points == "12.5")
          #expect(tables.first?.season == "2026")
        } else {
          let schedules = try decoder.decode([SportsScheduleStatus].self, from: data)
          #expect(schedules.first?.status == "empty")
        }
        let privateTarget = target + "?viewerDid=did:example:private"
        #expect(try await client.execute(uri: privateTarget, method: .get, headers: signed(privateTarget)).status == .badRequest)
      }
    }
  }

  @Test("team scope accepts explicit empty and rejects unbounded or malformed IDs")
  func teamScopeQuery() async throws {
    let store = SportsCorpusRouteStore()
    try await application(store).test(.router) { client in
      for query in ["teamIDs=", "teamIDs=sp_a,sp_b"] {
        let target = "/internal/wire/v1/sports/events?global=true&" + query
        let headers = try signed(target)
        #expect(try await client.execute(uri: target, method: .get, headers: headers).status == .ok)
      }
      for query in ["teamIDs=sp_a,", "teamIDs=" + Array(repeating: "sp_a", count: 101).joined(separator: ","), "teamIDs=sp_a&teamIDs=sp_b"] {
        let target = "/internal/wire/v1/sports/events?" + query
        let headers = try signed(target)
        #expect(try await client.execute(uri: target, method: .get, headers: headers).status == .badRequest)
      }
    }
  }

  @Test("signed Sports source rejects obsolete eligibility or associations")
  func rejectsObsoleteSource() async throws {
    for associationOnly in [false, true] {
      let store = SportsCorpusRouteStore(obsolete: true, associationOnly: associationOnly)
      try await application(store).test(.router) { client in
        let target = "/internal/wire/v1/sports?language=en"
        let headers = try signed(target)
        #expect(try await client.execute(uri: target, method: .get, headers: headers).status == .serviceUnavailable)
      }
    }
  }

  @Test("signed Sports response carries canonical catalog mappings and exact-language generation")
  func signedPresentationContract() async throws {
    let store = SportsCorpusRouteStore()
    try await application(store).test(.router) { client in
      let target = "/internal/wire/v1/sports?language=fr-CA"
      let headers = try signed(target)
      let response = try await client.execute(uri: target, method: .get, headers: headers)
      #expect(response.status == .ok)
      #expect(response.headers[HTTPField.Name("X-Wire-Corpus-Contract")!] == "3")
      #expect(response.headers[.cacheControl] == "no-store")
      #expect(response.headers[.accessControlAllowOrigin] == nil)
      let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
      let generation = try decoder.decode(SportsSourceGeneration.self, from: Data(response.body.readableBytesView))
      #expect(generation.language == "fr")
      #expect(generation.entities.first?.id == "fixture-team")
      #expect(generation.entities.first?.memberships?.first?.season == "2026")
      #expect(generation.entities.first?.memberships?.first?.includes(generation.generatedAt) == true)
      #expect(generation.candidates.first?.analysis.associations.first?.entityID == "fixture-team")
      #expect(try await client.execute(uri: target, method: .get, headers: headers).status == .unauthorized)
    }
    #expect(await store.sportsCalls == 1)
    #expect(await store.baselineCalls == 1)
  }

  @Test("Sports transport rejects duplicate language and viewer context query parameters")
  func rejectsUnapprovedContext() async throws {
    let store = SportsCorpusRouteStore()
    try await application(store).test(.router) { client in
      for target in ["/internal/wire/v1/sports?language=en&language=fr", "/internal/wire/v1/sports?language=en&viewerDid=did:example:viewer", "/internal/wire/v1/sports?language=en&preferences=private"] {
        let headers = try signed(target)
        let response = try await client.execute(uri: target, method: .get, headers: headers)
        #expect(response.status == .badRequest)
      }
    }
    #expect(await store.sportsCalls == 0)
  }

  @Test("stale baseline prevents Sports candidate disclosure")
  func baselineFailClosed() async throws {
    let store = SportsCorpusRouteStore(baselineAvailable: false)
    try await application(store).test(.router) { client in
      let target = "/internal/wire/v1/sports?language=en"
      let headers = try signed(target)
      let response = try await client.execute(uri: target, method: .get, headers: headers)
      #expect(response.status == .serviceUnavailable)
    }
    #expect(await store.sportsCalls == 0)
    #expect(await store.baselineCalls == 1)
  }

  private func application(_ store: SportsCorpusRouteStore) -> Application<RouterResponder<WireCorpusEdgeRequestContext>> {
    let config = WireCorpusEdgeConfig(databaseURL: "postgresql://unused", sharedSecret: secret, allowedServiceID: serviceID, maximumConnections: 2)
    return Application(router: WireCorpusEdgeRouterBuilder.router(store: store, config: config, logger: Logger(label: "sports-corpus.test")), configuration: .init(address: .hostname("127.0.0.1", port: 0)))
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

private actor SportsCorpusRouteStore: WireCorpusStoring {
  private let baselineAvailable: Bool
  private(set) var sportsCalls = 0
  private(set) var baselineCalls = 0
  private let obsolete: Bool
  private let associationOnly: Bool
  init(baselineAvailable: Bool = true, obsolete: Bool = false, associationOnly: Bool = false) {
    self.baselineAvailable = baselineAvailable; self.obsolete = obsolete; self.associationOnly = associationOnly
  }
  func ping() async throws {}
  func requireFreshBaseline(now: Date) async throws {
    baselineCalls += 1
    guard baselineAvailable else { throw WireCorpusEdgeStoreError.unavailable }
  }
  func sportsStandings(now: Date, preferredIDs: [String]) async throws -> [SportsStandingSnapshot] {
    [.init(competitionID: "fixture-competition", season: "2026", status: "available", updatedAt: now,
      rows: [.init(id: "fixture-team", name: "Fixture", rank: 1, points: "12.5")])]
  }
  func sportsSchedules(now: Date) async throws -> [SportsScheduleStatus] {
    [.init(competitionID: "fixture-competition", status: "empty", updatedAt: now)]
  }
  func sports(language: String, now: Date) async throws -> SportsSourceGeneration {
    sportsCalls += 1
    let instrument = SportsEntity(id: "fixture-team", name: "Fixture", kind: "team", memberships: [SportsMembership(entityID: "fixture-competition", validFrom: now.addingTimeInterval(-3600), validUntil: now.addingTimeInterval(3600), season: "2026")])
    let item = WireFeedItem(itemID: "fixture-story", canonicalURL: "https://example.com/sports", representativeURI: nil,
      title: "Fixture Wins Championship", summary: nil, publishedAt: now, thumbnailURL: nil,
      source: WireItemSource(name: "Example", domain: "example.com"), reasons: [], provenance: [])
    let candidate = SportsRankCandidate(item: item,
      analysis: SportsArticleAnalysis(eligible: true, materiality: "championship",
        associations: [SportsAssociation(entityID: instrument.id, confidence: 0.95, evidence: ["name-or-alias"], prominence: 0, resolverVersion: obsolete ? "sports-resolver-v1" : SportsResolver.version)], sportIDs: [], competitionIDs: [], resolverVersion: obsolete && !associationOnly ? "sports-resolver-v1" : SportsResolver.version), baseScore: 100)
    return SportsSourceGeneration(generationId: UUID().uuidString.lowercased(), generatedAt: now,
      expiresAt: now.addingTimeInterval(48 * 3600), language: language, candidates: [candidate], entities: [instrument])
  }
  func feed(language: String, generationID: UUID?, startOrdinal: Int, limit: Int, fallbackLimit: Int?, now: Date) async throws -> WireCorpusPage { throw WireCorpusEdgeStoreError.unavailable }
  func edition(language: String, region: WireViewerRegion?, fallbackLimit: Int?, now: Date) async throws -> WireCorpusEdition { throw WireCorpusEdgeStoreError.unavailable }
  func item(id: String, now: Date) async throws -> WireCorpusItem? { nil }
  func catalog(now: Date) async throws -> WireCorpusCatalog { throw WireCorpusEdgeStoreError.unavailable }
  func circleCandidates(actorHashes: [String], language: String, since: Date, limit: Int, now: Date) async throws -> WireCorpusCandidateResponse { throw WireCorpusEdgeStoreError.unavailable }
}
