import AsyncHTTPClient
import Foundation
import GatewayCore
import Hummingbird
import Logging
import Testing

@testable import Gateway

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
        collection: "app.thesocialwire.preferences",
        rkey: "",
        ifNoneMatch: nil
      )
    }
    try await client.shutdown()
  }

  @Test("fresh cached records satisfy reads and conditional 304 responses")
  func freshCacheAndConditionalResponse() async throws {
    let dbPath = FileManager.default.temporaryDirectory
      .appendingPathComponent("sw-prefs-\(UUID().uuidString).sqlite")
      .path
    defer { try? FileManager.default.removeItem(atPath: dbPath) }

    let cache = try SQLiteCache(path: dbPath, logger: Logger(label: "prefs.sqlite"))
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    let service = PreferenceSyncService(
      httpClient: client,
      cache: cache,
      plcURL: "http://127.0.0.1:1",
      logger: Logger(label: "prefs.test")
    )
    let auth = AuthContext(
      did: "did:plc:viewer",
      authorizationForwardingValue: "DPoP token",
      dpopProof: "proof"
    )
    let now = Date()
    try await cache.storePdsRepoRecordPayload(
      ownerDid: auth.did,
      scopeKey: "app.example.record:self",
      cid: "bafycached",
      jsonBody: #"{"value":{"enabled":true}}"#,
      cachedAt: now,
      expiresAt: now.addingTimeInterval(CacheStorePdsTTLs.genericWriteHorizon)
    )

    let warm = try await service.genericCachedRecordGET(
      auth: auth,
      collection: "app.example.record",
      rkey: "self",
      ifNoneMatch: nil
    )
    #expect(warm.status == .ok)

    let notModified = try await service.genericCachedRecordGET(
      auth: auth,
      collection: "app.example.record",
      rkey: "self",
      ifNoneMatch: #""bafycached""#
    )
    #expect(notModified.status == .notModified)
    try await client.shutdown()
  }
}
