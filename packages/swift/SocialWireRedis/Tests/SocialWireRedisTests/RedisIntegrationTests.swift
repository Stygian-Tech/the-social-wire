import Foundation
import Logging
import Testing
@testable import SocialWireRedis

@Suite("Redis integration")
struct RedisIntegrationTests {
  @Test
  func cacheLeasesInvalidationRankingAndFlush() async throws {
    guard let url = ProcessInfo.processInfo.environment["REDIS_INTEGRATION_URL"] else { return }
    let configuration = try RedisConfiguration(url: url)
    let first = try RediStackRedisClient(configuration: configuration, logger: Logger(label: "redis.integration.first"))
    let second = try RediStackRedisClient(configuration: configuration, logger: Logger(label: "redis.integration.second"))
    defer {
      Task {
        try? await first.shutdown()
        try? await second.shutdown()
      }
    }
    _ = try await first.execute(command: "FLUSHDB", arguments: [])

    let cache = RedisCacheClient(commands: first)
    try await cache.store(
      "value",
      key: "integration:cache",
      policy: RedisCachePolicy(freshDuration: 0.02, hardDuration: 0.08, maximumJitterFraction: 0)
    )
    guard case .fresh(let fresh) = try await cache.lookup(String.self, key: "integration:cache") else {
      Issue.record("expected a fresh cache hit")
      return
    }
    #expect(fresh.value == "value")
    try await Task.sleep(for: .milliseconds(35))
    guard case .stale = try await cache.lookup(String.self, key: "integration:cache") else {
      Issue.record("expected a stale cache hit")
      return
    }
    try await Task.sleep(for: .milliseconds(80))
    guard case .miss = try await cache.lookup(String.self, key: "integration:cache") else {
      Issue.record("expected native millisecond expiry")
      return
    }

    let namespace = RedisKeyNamespace(environment: "integration")
    let firstLeases = RedisLeaseCoordinator(commands: first, namespace: namespace)
    let secondLeases = RedisLeaseCoordinator(commands: second, namespace: namespace)
    let owner = try #require(try await firstLeases.acquire(domain: "test", resource: "same", ttl: 1))
    #expect(try await secondLeases.acquire(domain: "test", resource: "same", ttl: 1) == nil)
    let successorKey = owner.key
    _ = try await first.set(successorKey, value: Data("successor".utf8), expirationMilliseconds: 1_000)
    #expect(try await firstLeases.release(owner) == false)
    #expect(String(data: try #require(try await first.get(successorKey)), encoding: .utf8) == "successor")

    try await first.set("integration:scan:one", value: Data("1".utf8), expirationMilliseconds: 10_000)
    try await first.set("integration:scan:two", value: Data("2".utf8), expirationMilliseconds: 10_000)
    let scan = try await first.execute(
      command: "SCAN",
      arguments: [.data(Data("0".utf8)), .data(Data("MATCH".utf8)), .data(Data("integration:scan:*".utf8))]
    )
    guard case .array(let parts) = scan, parts.count == 2, case .array(let keys) = parts[1] else {
      Issue.record("expected SCAN response")
      return
    }
    _ = try await first.delete(keys.compactMap(\.string))
    #expect(try await first.get("integration:scan:one") == nil)

    let ranking = RedisRankingStore(commands: first, namespace: namespace)
    try await ranking.upsert(
      [
        try RedisRankingCandidate(contentId: "at://a", score: 2),
        try RedisRankingCandidate(contentId: "at://b", score: 3),
      ],
      scope: .global(feed: "wire"),
      window: .oneHour
    )
    #expect(try await ranking.top(limit: 2, scope: .global(feed: "wire"), window: .oneHour).map(\.contentId) == ["at://b", "at://a"])

    _ = try await first.execute(command: "FLUSHDB", arguments: [])
    #expect(try await ranking.top(limit: 2, scope: .global(feed: "wire"), window: .oneHour).isEmpty)
  }
}
