import Foundation
import Logging
import SocialWireRedis
import Testing

@testable import WireWorkerCore

@Suite("Redis publication cache scripts")
struct RedisWirePublicationCacheIntegrationTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["WIRE_PUBLICATION_TEST_REDIS_URL"] != nil))
  func invalidationAndExpiration() async throws {
    let url = try #require(ProcessInfo.processInfo.environment["WIRE_PUBLICATION_TEST_REDIS_URL"])
    let client = try RediStackRedisClient(configuration: .init(url: url), logger: Logger(label: "publication-cache-test"))
    do {
      try await exercise(client)
      try await client.shutdown()
    } catch {
      try? await client.shutdown()
      throw error
    }
  }

  private func exercise(_ client: RediStackRedisClient) async throws {
    let namespace = RedisKeyNamespace(environment: "test-\(UUID().uuidString)")
    let cache = RedisWirePublicationCache(commands: client, namespace: namespace)
    let uri = "at://did:plc:author/site.standard.publication/main"
    let otherURI = "at://did:plc:author/site.standard.publication/second"
    let now = Date()
    let metadata = WirePublicationMetadata(publicationURI: uri, repoDID: "did:plc:author",
      siteURL: "https://publisher.example", name: "Publisher")
    let miss = try await cache.lookup(uri, asOf: now)
    #expect(miss.value == nil)
    try await cache.fill(uri, token: miss.token,
      value: .init(metadata: metadata, expiresAt: now.addingTimeInterval(10)), asOf: now)
    #expect(try await cache.lookup(uri, asOf: now).value?.metadata == metadata)
    #expect(try await cache.lookup(uri, asOf: now.addingTimeInterval(10)).value == nil)
    try await cache.invalidate(uri)
    try await cache.fill(uri, token: miss.token,
      value: .init(metadata: metadata, expiresAt: now.addingTimeInterval(10)), asOf: now)
    #expect(try await cache.lookup(uri, asOf: now).value == nil)
    let negative = try await cache.lookup(otherURI, asOf: now)
    try await cache.fill(otherURI, token: negative.token,
      value: .init(metadata: nil, expiresAt: now.addingTimeInterval(10)), asOf: now)
    #expect(try await cache.lookup(otherURI, asOf: now).value != nil)
    try await cache.invalidateAccount("did:plc:author")
    #expect(try await cache.lookup(otherURI, asOf: now).value == nil)
    let after = try await cache.lookup(otherURI, asOf: now)
    #expect(after.token != negative.token)
    // A superseded epoch cannot make a former fill valid.
    try await cache.fill(otherURI, token: negative.token,
      value: .init(metadata: nil, expiresAt: now.addingTimeInterval(10)), asOf: now)
    #expect(try await cache.lookup(otherURI, asOf: now).value == nil)
    try await cache.fill(otherURI, token: after.token,
      value: .init(metadata: nil, expiresAt: now.addingTimeInterval(10)), asOf: now)
    #expect(try await cache.lookup(otherURI, asOf: now).value != nil)
    // Evicting an epoch independently of a value must also discard that value.
    _ = try await client.delete([namespace.key(domain: "wire-publication-epoch", identifiers: ["did:plc:author"])])
    let evicted = try await cache.lookup(otherURI, asOf: now)
    #expect(evicted.value == nil)
    #expect(evicted.token != after.token)
  }
}
