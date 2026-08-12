import Testing
@testable import SocialWireRedis

@Suite("Redis ranking store")
struct RedisRankingStoreTests {
  @Test
  func returnsDescendingScoresWithDeterministicTies() async throws {
    let commands = InMemoryRedisCommandClient()
    let store = RedisRankingStore(
      commands: commands,
      namespace: RedisKeyNamespace(environment: "test")
    )
    try await store.upsert(
      [
        try RedisRankingCandidate(contentId: "at://a", score: 3),
        try RedisRankingCandidate(contentId: "at://b", score: 5),
        try RedisRankingCandidate(contentId: "at://c", score: 5),
      ],
      scope: .global(feed: "wire"),
      window: .oneHour
    )

    let top = try await store.top(limit: 3, scope: .global(feed: "wire"), window: .oneHour)
    #expect(top.map(\.contentId) == ["at://c", "at://b", "at://a"])
    #expect(throws: RedisRankingError.nonFiniteScore) {
      _ = try RedisRankingCandidate(contentId: "bad", score: .infinity)
    }

    try await store.remove(contentIds: ["at://a"], scope: .global(feed: "wire"), window: .oneHour)
    try await store.trim(keeping: 1, scope: .global(feed: "wire"), window: .oneHour)
    #expect(try await store.top(limit: 3, scope: .global(feed: "wire"), window: .oneHour).map(\.contentId) == ["at://c"])
    #expect(await commands.hasExpiry)
  }
}
