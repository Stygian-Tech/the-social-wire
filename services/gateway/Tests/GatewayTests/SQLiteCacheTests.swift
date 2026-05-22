import Foundation
import Logging
import Testing

@testable import Gateway

@Suite("SQLiteCache")
struct SQLiteCacheTests {
  private func makeCache() throws -> SQLiteCache {
    var logger = Logger(label: "test.sqlite")
    logger.logLevel = .warning
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("sw-test-\(UUID().uuidString).sqlite")
      .path
    return try SQLiteCache(path: path, logger: logger)
  }

  @Test("stores and retrieves canonical PDS record cache payloads")
  func pdsRecordCacheStoresJSON() async throws {
    let cache = try makeCache()
    try await cache.storePdsRepoRecordPayload(
      ownerDid: "did:plc:alice",
      scopeKey: "com.example.collection:rkey123",
      cid: "bafyx",
      jsonBody: #"{"cid":"bafyx","value":{"x":1}}"#,
      cachedAt: Date(),
      expiresAt: Date().addingTimeInterval(60)
    )

    let warmed = try await cache.cachedPdsRepoRecord(ownerDid: "did:plc:alice", scopeKey: "com.example.collection:rkey123")
    try #require(warmed != nil)
    #expect(warmed!.cid == "bafyx")
    #expect(warmed!.jsonBody.contains("\"x\":1"))
  }
}
