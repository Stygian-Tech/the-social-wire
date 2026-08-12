import Foundation

public protocol PDSResolutionCache: Actor {
  func lookup(did: String, now: Date) async throws -> PDSResolutionCacheLookup
  func storeResolved(did: String, endpoint: String, now: Date) async throws
  func storeUnresolved(did: String, now: Date) async throws
  func acquireLease(did: String, ttl: TimeInterval) async throws -> RedisLease?
  func releaseLease(_ lease: RedisLease) async
}

public extension PDSResolutionCache {
  func lookup(did: String) async throws -> PDSResolutionCacheLookup {
    try await lookup(did: did, now: Date())
  }
}
