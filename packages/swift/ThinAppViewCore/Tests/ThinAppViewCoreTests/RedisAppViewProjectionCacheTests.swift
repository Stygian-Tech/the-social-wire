import Foundation
import Logging
import SocialWireRedis
import Testing
@testable import ThinAppViewCore

@Suite("Redis AppView projection cache")
struct RedisAppViewProjectionCacheTests {
  @Test("explicit unread zero remains distinct from an unknown key")
  func explicitZeroAndScopedInvalidation() async throws {
    let commands = ProjectionRedisCommands()
    let store = RedisAppViewProjectionCacheStore(
      commands: commands,
      environment: "test",
      logger: Logger(label: "redis-projection.test")
    )

    try await store.storeUnreadCounts(
      viewerDid: "did:plc:viewer",
      counts: ["at://publication/zero": 0, "at://publication/unread": 3],
      expiresAt: Date().addingTimeInterval(60)
    )

    guard case .fresh(let known) = try await store.unreadCountsCacheLookup(viewerDid: "did:plc:viewer") else {
      Issue.record("expected known unread values")
      return
    }
    #expect(known.value["at://publication/zero"] == 0)
    #expect(known.value["at://publication/unknown"] == nil)

    guard case .fresh(let scoped) = try await store.unreadCountsCacheLookup(
      viewerDid: "did:plc:viewer",
      publicationIds: ["at://publication/zero", "at://publication/unknown"],
      now: Date()
    ) else {
      Issue.record("expected the directly addressed zero value")
      return
    }
    #expect(scoped.value == ["at://publication/zero": 0])
    #expect(await commands.scanCount == 1)

    try await store.invalidateUnreadCounts(
      viewerDid: "did:plc:viewer",
      publicationId: "at://publication/unread"
    )
    guard case .fresh(let remaining) = try await store.unreadCountsCacheLookup(viewerDid: "did:plc:viewer") else {
      Issue.record("expected the zero entry to remain")
      return
    }
    #expect(remaining.value == ["at://publication/zero": 0])

    try await store.invalidateUnreadCounts(viewerDid: "did:plc:viewer", publicationId: nil)
    #expect(try await store.cachedUnreadCounts(viewerDid: "did:plc:viewer") == nil)
  }

  @Test("broad invalidation uses scan and unlink")
  func broadInvalidation() async throws {
    let commands = ProjectionRedisCommands()
    let store = RedisAppViewProjectionCacheStore(
      commands: commands,
      environment: "test",
      logger: Logger(label: "redis-projection.test")
    )
    try await store.storeSidebarProjectionJSON(
      viewerDid: "did:plc:viewer",
      jsonBody: "{}",
      expiresAt: Date().addingTimeInterval(60)
    )
    try await store.storeFirstPageJSON(
      viewerDid: AppViewProjectionCacheViewerKeys.sharedFirstPage,
      publicationId: "at://publication/main",
      jsonBody: "{}",
      expiresAt: Date().addingTimeInterval(60)
    )

    try await store.invalidateAllProjectionCaches()
    #expect(try await store.cachedSidebarProjectionJSON(viewerDid: "did:plc:viewer") == nil)
    #expect(try await store.cachedFirstPageJSON(
      viewerDid: AppViewProjectionCacheViewerKeys.sharedFirstPage,
      publicationId: "at://publication/main"
    ) == nil)
    #expect(await commands.scanCount > 0)
    #expect(await commands.unlinkCount > 0)
  }

  @Test("refresh leases contend and Redis failures remain fail-open")
  func leaseContentionAndFailure() async throws {
    let commands = ProjectionRedisCommands()
    let store = RedisAppViewProjectionCacheStore(
      commands: commands,
      environment: "test",
      logger: Logger(label: "redis-projection.test")
    )
    let first = try #require(await store.acquireRefreshLease(
      domain: "rss",
      resource: "https://example.com/feed.xml",
      ttl: 120
    ))
    #expect(await store.acquireRefreshLease(
      domain: "rss",
      resource: "https://example.com/feed.xml",
      ttl: 120
    ) == nil)
    await store.releaseRefreshLease(first)

    let unavailable = RedisAppViewProjectionCacheStore(
      commands: UnavailableProjectionRedisCommands(),
      environment: "test",
      logger: Logger(label: "redis-projection.unavailable")
    )
    let failOpen = try #require(await unavailable.acquireRefreshLease(
      domain: "rss",
      resource: "https://example.com/feed.xml",
      ttl: 120
    ))
    #expect(failOpen.key.isEmpty)
    #expect(await unavailable.renewRefreshLease(failOpen))
  }
}

private actor ProjectionRedisCommands: RedisCommandClient {
  private var values: [String: Data] = [:]
  private(set) var scanCount = 0
  private(set) var unlinkCount = 0

  func get(_ key: String) -> Data? { values[key] }

  func set(_ key: String, value: Data, expirationMilliseconds: Int) {
    _ = expirationMilliseconds
    values[key] = value
  }

  func setIfAbsent(_ key: String, value: Data, expirationMilliseconds: Int) -> Bool {
    _ = expirationMilliseconds
    guard values[key] == nil else { return false }
    values[key] = value
    return true
  }

  func delete(_ keys: [String]) -> Int {
    unlinkCount += 1
    return keys.reduce(into: 0) { count, key in
      if values.removeValue(forKey: key) != nil { count += 1 }
    }
  }

  func execute(command: String, arguments: [RedisCommandValue]) -> RedisCommandValue {
    guard command == "SCAN" else { return .null }
    scanCount += 1
    let pattern = arguments.count >= 3 ? arguments[2].string ?? "*" : "*"
    let prefix = pattern.hasSuffix("*") ? String(pattern.dropLast()) : pattern
    let keys = values.keys.filter { $0.hasPrefix(prefix) }.sorted()
    return .array([
      .data(Data("0".utf8)),
      .array(keys.map { .data(Data($0.utf8)) }),
    ])
  }

  func ping() {}
  func shutdown() {}
}

private actor UnavailableProjectionRedisCommands: RedisCommandClient {
  struct Unavailable: Error {}

  func get(_ key: String) throws -> Data? { throw Unavailable() }
  func set(_ key: String, value: Data, expirationMilliseconds: Int) throws { throw Unavailable() }
  func setIfAbsent(_ key: String, value: Data, expirationMilliseconds: Int) throws -> Bool {
    throw Unavailable()
  }
  func delete(_ keys: [String]) throws -> Int { throw Unavailable() }
  func execute(command: String, arguments: [RedisCommandValue]) throws -> RedisCommandValue {
    throw Unavailable()
  }
  func ping() throws { throw Unavailable() }
  func shutdown() {}
}
