import Foundation
import Testing
@testable import SocialWireRedis

@Suite("The Wire Redis acceleration")
struct RedisWireAccelerationStoreTests {
  private struct Page: Codable, Equatable, Sendable { let generation: String }

  @Test("caches post mappings, immutable generation pages, and catalog values")
  func cacheSurfaces() async throws {
    let commands = InMemoryRedisCommandClient()
    let store = RedisWireAccelerationStore(
      commands: commands,
      namespace: RedisKeyNamespace(environment: "test")
    )
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    try await store.storePostMapping(postURI: "at://did:example/post/1", canonicalKey: "story", now: now)
    #expect(try await store.postMapping(postURI: "at://did:example/post/1", now: now) == "story")
    try await store.storeGenerationPage(
      Page(generation: "g1"), generationID: "g1", language: "en", ordinal: 0, now: now
    )
    #expect(try await store.generationPage(
      Page.self, generationID: "g1", language: "en", ordinal: 0, now: now
    ) == Page(generation: "g1"))
    try await store.storeFeedCatalog(Page(generation: "g1"), now: now)
    #expect(try await store.feedCatalog(Page.self, now: now) == Page(generation: "g1"))
  }

  @Test("reuses global rolling ranking windows and a distributed lease")
  func candidatesAndLease() async throws {
    let commands = InMemoryRedisCommandClient()
    let store = RedisWireAccelerationStore(
      commands: commands,
      namespace: RedisKeyNamespace(environment: "test")
    )
    try await store.upsertCandidates(
      [try RedisRankingCandidate(contentId: "story", score: 1)],
      window: .oneHour
    )
    #expect(try await store.topCandidates(limit: 1, window: .oneHour).map(\.contentId) == ["story"])
    let lease = try await store.acquireRankingLease()
    #expect(lease != nil)
    if let lease { #expect(try await store.releaseRankingLease(lease)) }
  }
}
