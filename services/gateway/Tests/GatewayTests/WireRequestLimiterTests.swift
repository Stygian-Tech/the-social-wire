import Foundation
import GatewayCore
import Testing
import SocialWireRedis
@testable import Gateway

@Suite("The Wire request limiter")
struct WireRequestLimiterTests {
  @Test("Anonymous and authenticated budgets are isolated and reset")
  func budgets() async {
    let limiter = WireRequestLimiter()
    let start = Date(timeIntervalSince1970: 1_800)
    for _ in 0..<30 {
      #expect(await limiter.consume(key: "ip:test", audience: .anonymous, now: start))
    }
    #expect(await !limiter.consume(key: "ip:test", audience: .anonymous, now: start))
    #expect(await limiter.consume(key: "did:test", audience: .authenticated, now: start))
    #expect(await limiter.consume(key: "ip:test", audience: .anonymous, now: start.addingTimeInterval(1)))
  }

  @Test("Redis is shared authority when available")
  func redisAuthority() async {
    let redis = WireLimiterRedisFake()
    let first = WireRequestLimiter(redis: redis, environment: "test")
    let second = WireRequestLimiter(redis: redis, environment: "test")
    let now = Date(timeIntervalSince1970: 1_800)
    for _ in 0..<30 {
      #expect(await first.consume(key: "same-ip", audience: .anonymous, now: now))
    }
    #expect(await !second.consume(key: "same-ip", audience: .anonymous, now: now))
  }

  @Test("Gateway timeout exceeds the bounded AppView moderation cold path")
  func proxyTimeoutBudget() {
    #expect(
      WireModerationDPoP.gatewayProxyTimeoutSeconds
        > WireModerationDPoP.appViewColdPathTimeoutSeconds
    )
    #expect(WireModerationDPoP.gatewayProxyTimeoutSeconds == 30)
  }
}

private actor WireLimiterRedisFake: RedisCommandClient {
  private struct Bucket {
    var tokens: Double
    var updatedAt: Int
  }
  private var buckets: [String: Bucket] = [:]

  func get(_ key: String) -> Data? { nil }
  func set(_ key: String, value: Data, expirationMilliseconds: Int) {}
  func setIfAbsent(_ key: String, value: Data, expirationMilliseconds: Int) -> Bool { true }
  func delete(_ keys: [String]) -> Int { 0 }
  func ping() {}
  func shutdown() {}

  func execute(command: String, arguments: [RedisCommandValue]) throws -> RedisCommandValue {
    guard command == "EVAL", arguments.count >= 7, let key = arguments[2].string,
      let now = arguments[3].integerValue,
      let rateString = arguments[4].string, let rate = Double(rateString),
      let capacityValue = arguments[5].integerValue
    else {
      return .null
    }
    let capacity = Double(capacityValue)
    var bucket = buckets[key] ?? Bucket(tokens: capacity, updatedAt: now)
    bucket.tokens = min(capacity, bucket.tokens + Double(max(0, now - bucket.updatedAt)) * rate)
    bucket.updatedAt = now
    guard bucket.tokens >= 1 else {
      buckets[key] = bucket
      return .integer(0)
    }
    bucket.tokens -= 1
    buckets[key] = bucket
    return .integer(1)
  }
}

private extension RedisCommandValue {
  var integerValue: Int? {
    guard case .integer(let value) = self else { return nil }
    return value
  }
}
