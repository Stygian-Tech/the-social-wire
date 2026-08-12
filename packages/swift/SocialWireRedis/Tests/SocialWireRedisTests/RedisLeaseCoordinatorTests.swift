import Testing
@testable import SocialWireRedis

@Suite("Redis leases")
struct RedisLeaseCoordinatorTests {
  @Test
  func ownershipPreventsUnsafeRelease() async throws {
    let commands = InMemoryRedisCommandClient()
    let coordinator = RedisLeaseCoordinator(
      commands: commands,
      namespace: RedisKeyNamespace(environment: "test")
    )
    let first = try #require(await coordinator.acquire(domain: "sidebar", resource: "viewer", ttl: 10))
    #expect(try await coordinator.acquire(domain: "sidebar", resource: "viewer", ttl: 10) == nil)
    #expect(!(try await coordinator.release(RedisLease(
      key: first.key,
      owner: "another-owner",
      ttlMilliseconds: first.ttlMilliseconds
    ))))
    #expect(try await coordinator.renew(first))
    #expect(try await coordinator.release(first))
  }
}
