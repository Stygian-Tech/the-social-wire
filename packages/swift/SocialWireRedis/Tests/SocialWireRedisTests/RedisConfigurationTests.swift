import Foundation
import Testing
@testable import SocialWireRedis

@Suite("Redis configuration")
struct RedisConfigurationTests {
  @Test
  func parsesRedisAndRedissURLs() throws {
    let plain = try RedisConfiguration(url: "redis://user:password@example.com:6380/2")
    #expect(plain.scheme == .redis)
    #expect(plain.host == "example.com")
    #expect(plain.port == 6380)
    #expect(plain.username == "user")
    #expect(plain.password == "password")
    #expect(plain.database == 2)
    #expect(!plain.usesTLS)

    let tls = try RedisConfiguration(url: "rediss://cache.example.com")
    #expect(tls.usesTLS)
    #expect(tls.port == 6379)
  }

  @Test
  func rejectsUnsupportedOrMalformedURLs() {
    #expect(throws: RedisConfigurationError.invalidURL) {
      _ = try RedisConfiguration(url: "http://example.com")
    }
    #expect(throws: RedisConfigurationError.invalidDatabase) {
      _ = try RedisConfiguration(url: "redis://example.com/not-a-database")
    }
  }
}
