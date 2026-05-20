import AsyncHTTPClient
import Foundation
import Hummingbird
import Logging
import Testing

@testable import App

@Suite("ATProtoPdsResolution")
struct ATProtoPdsResolutionTests {
  @Test("normalizePdsBase strips trailing slashes")
  func normalizePdsBase() {
    #expect(ATProtoPdsResolution.normalizePdsBase("https://pds.example/") == "https://pds.example")
    #expect(ATProtoPdsResolution.normalizePdsBase("  https://pds.example  ") == "https://pds.example")
  }

  @Test("parsePdsEndpointFromPlcDoc reads #atproto_pds service")
  func parsePdsFromPlcDoc() {
    let doc: [String: Any] = [
      "service": [
        [
          "id": "#atproto_pds",
          "type": "AtprotoPersonalDataServer",
          "serviceEndpoint": "https://bsky.social/",
        ],
      ],
    ]
    #expect(ATProtoPdsResolution.parsePdsEndpointFromPlcDoc(doc) == "https://bsky.social")
  }

  @Test("relayHostOmitsListRecordsReverse detects Bridgy hosts")
  func bridgyRelayHost() {
    #expect(ATProtoPdsResolution.relayHostOmitsListRecordsReverse(pdsBase: "https://atproto.brid.gy") == true)
    #expect(ATProtoPdsResolution.relayHostOmitsListRecordsReverse(pdsBase: "https://user.brid.gy") == true)
    #expect(ATProtoPdsResolution.relayHostOmitsListRecordsReverse(pdsBase: "https://bsky.social") == false)
  }

  @Test("resolveRepoDid returns DID unchanged")
  func resolveRepoDidPassthrough() async throws {
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    let did = "did:plc:abc123"
    let resolved = try await ATProtoPdsResolution.resolveRepoDid(
      handleOrDid: did,
      httpClient: client
    )
    #expect(resolved == did)
    try await client.shutdown()
  }
}

@Suite("PreferenceSyncService validation")
struct PreferenceSyncServiceTests {
  @Test("genericCachedRecordGET rejects empty collection")
  func rejectsEmptyCollection() async throws {
    let dbPath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-prefs-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let cache = try SQLiteCache(path: dbPath, logger: Logger(label: "prefs.sqlite"))
    let client = HTTPClient(eventLoopGroupProvider: .singleton)

    let service = PreferenceSyncService(
      httpClient: client,
      cache: cache,
      plcURL: "https://plc.directory",
      logger: Logger(label: "prefs.test")
    )

    let auth = AuthContext(
      did: "did:plc:viewer",
      authorizationForwardingValue: "DPoP token",
      dpopProof: "proof"
    )

    await #expect(throws: HTTPError.self) {
      _ = try await service.genericCachedRecordGET(
        auth: auth,
        collection: "  ",
        rkey: "self",
        ifNoneMatch: nil
      )
    }
    try await client.shutdown()
  }

  @Test("genericCachedRecordGET rejects empty rkey")
  func rejectsEmptyRkey() async throws {
    let dbPath =
      FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-prefs-\(UUID().uuidString).sqlite")
        .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let cache = try SQLiteCache(path: dbPath, logger: Logger(label: "prefs.sqlite"))
    let client = HTTPClient(eventLoopGroupProvider: .singleton)

    let service = PreferenceSyncService(
      httpClient: client,
      cache: cache,
      plcURL: "https://plc.directory",
      logger: Logger(label: "prefs.test")
    )

    let auth = AuthContext(
      did: "did:plc:viewer",
      authorizationForwardingValue: "DPoP token",
      dpopProof: "proof"
    )

    await #expect(throws: HTTPError.self) {
      _ = try await service.genericCachedRecordGET(
        auth: auth,
        collection: "com.thesocialwire.preferences",
        rkey: "",
        ifNoneMatch: nil
      )
    }
    try await client.shutdown()
  }
}
