import Foundation
import Testing
@testable import SocialWireRedis

@Suite("Redis cache client")
struct RedisCacheClientTests {
  @Test
  func distinguishesFreshStaleAndHardExpiredValues() async throws {
    let commands = InMemoryRedisCommandClient()
    let cache = RedisCacheClient(commands: commands)
    let key = "sw:test:v1:value:key"
    let now = Date(timeIntervalSince1970: 1_000)
    try await cache.store(
      ["count": 0],
      key: key,
      policy: RedisCachePolicy(freshDuration: 10, hardDuration: 30, maximumJitterFraction: 0),
      now: now
    )

    guard case .fresh(let fresh) = try await cache.lookup([String: Int].self, key: key, now: now) else {
      Issue.record("Expected a fresh cache hit")
      return
    }
    #expect(fresh.value["count"] == 0)

    guard case .stale = try await cache.lookup(
      [String: Int].self,
      key: key,
      now: now.addingTimeInterval(11)
    ) else {
      Issue.record("Expected a stale cache hit")
      return
    }

    guard case .miss = try await cache.lookup(
      [String: Int].self,
      key: key,
      now: now.addingTimeInterval(31)
    ) else {
      Issue.record("Expected a hard-expired miss")
      return
    }
  }

  @Test
  func malformedAndSchemaMismatchAreDeletedMisses() async throws {
    let commands = InMemoryRedisCommandClient()
    let cache = RedisCacheClient(commands: commands)
    try await commands.set("malformed", value: Data("not-json".utf8), expirationMilliseconds: 1_000)
    guard case .miss = try await cache.lookup(String.self, key: "malformed") else {
      Issue.record("Expected malformed data to be a miss")
      return
    }
    #expect(try await commands.get("malformed") == nil)

    let incompatible = Data(#"{"schemaVersion":999,"cachedAt":1000,"freshUntil":2000,"hardExpiresAt":3000,"value":"old"}"#.utf8)
    try await commands.set("incompatible", value: incompatible, expirationMilliseconds: 1_000)
    guard case .miss = try await cache.lookup(
      String.self,
      key: "incompatible",
      now: Date(timeIntervalSince1970: 1)
    ) else {
      Issue.record("Expected an unsupported schema to be a miss")
      return
    }
    #expect(try await commands.get("incompatible") == nil)
  }
}
