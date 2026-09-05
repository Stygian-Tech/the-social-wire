import Foundation
import SocialWireRedis
import Testing

@testable import AppView

@Suite("Your Circle disposable Redis cache")
struct RedisCircleDisposableCacheTests {
  private let now = Date(timeIntervalSince1970: 2_000_000_000)

  @Test("graph keys isolate environments and viewers, respect exclusions, and bound hard TTL")
  func graphIsolationAndTTL() async throws {
    let commands = CircleRedisTestCommands()
    let at = now
    let cache = RedisCircleDisposableCache(commands: commands, environment: "prod", now: { at })
    let otherEnvironment = RedisCircleDisposableCache(
      commands: commands, environment: "dev", now: { at })
    let snapshot = snapshot(viewer: "did:plc:a", generatedAt: at.addingTimeInterval(-60))
    try await cache.store(snapshot, excludedDIDs: ["did:plc:blocked"])
    #expect(
      try await cache.load(viewerDID: "did:plc:a", excludedDIDs: ["did:plc:blocked"]) == snapshot)
    #expect(try await cache.load(viewerDID: "did:plc:b", excludedDIDs: ["did:plc:blocked"]) == nil)
    #expect(try await cache.load(viewerDID: "did:plc:a", excludedDIDs: []) == nil)
    #expect(
      try await otherEnvironment.load(viewerDID: "did:plc:a", excludedDIDs: ["did:plc:blocked"])
        == nil)
    #expect(await commands.expirations() == [86_340_000])
    #expect(await commands.keys().allSatisfy { !$0.contains("did:") })
    let expired = RedisCircleDisposableCache(
      commands: commands, environment: "prod", now: { at.addingTimeInterval(86_340) }
    )
    // The fake deliberately keeps expired Redis bytes: envelope expiry must also reject them.
    #expect(
      try await expired.load(viewerDID: "did:plc:a", excludedDIDs: ["did:plc:blocked"]) == nil)
  }

  @Test("editions bind to every scope and expire without retaining generation rows")
  func editionScopeAndExpiry() async {
    let commands = CircleRedisTestCommands()
    let at = now
    let cache = RedisCircleDisposableCache(commands: commands, environment: "prod", now: { at })
    let id = UUID()
    await cache.storeEdition(
      viewerDID: "did:plc:a", snapshotID: id, generationID: "one", language: "en",
      hiddenStoryIDs: [], expiresAt: at.addingTimeInterval(30), payload: Data("edition".utf8)
    )
    #expect(
      await cache.cachedEdition(
        viewerDID: "did:plc:a", snapshotID: id, generationID: "one", language: "en",
        hiddenStoryIDs: [], now: at) == Data("edition".utf8))
    #expect(
      await cache.cachedEdition(
        viewerDID: "did:plc:b", snapshotID: id, generationID: "one", language: "en",
        hiddenStoryIDs: [], now: at) == nil)
    #expect(
      await cache.cachedEdition(
        viewerDID: "did:plc:a", snapshotID: UUID(), generationID: "one", language: "en",
        hiddenStoryIDs: [], now: at) == nil)
    #expect(
      await cache.cachedEdition(
        viewerDID: "did:plc:a", snapshotID: id, generationID: "two", language: "en",
        hiddenStoryIDs: [], now: at) == nil)
    #expect(
      await cache.cachedEdition(
        viewerDID: "did:plc:a", snapshotID: id, generationID: "one", language: "fr",
        hiddenStoryIDs: [], now: at) == nil)
    #expect(
      await cache.cachedEdition(
        viewerDID: "did:plc:a", snapshotID: id, generationID: "one", language: "en",
        hiddenStoryIDs: [], now: at.addingTimeInterval(30)) == nil)
    for generation in 0..<10 {
      await cache.storeEdition(
        viewerDID: "did:plc:a", snapshotID: id, generationID: "\(generation)", language: "en",
        hiddenStoryIDs: [], expiresAt: at.addingTimeInterval(3_600), payload: Data())
    }
    #expect(await commands.keys().count == 1)
    #expect(await commands.expirations() == [600_000])
  }

  @Test("failed hide invalidation and late writes cannot resurrect an old hide set")
  func hideInvalidationFailure() async throws {
    let commands = CircleRedisTestCommands()
    let at = now
    let cache = RedisCircleDisposableCache(commands: commands, environment: "prod", now: { at })
    let id = UUID()
    await cache.storeEdition(
      viewerDID: "did:plc:a", snapshotID: id, generationID: "one", language: "en",
      hiddenStoryIDs: [], expiresAt: at.addingTimeInterval(60), payload: Data("old".utf8))
    await commands.setUnavailable(true)
    await cache.invalidateEditions(viewerDID: "did:plc:a")
    await commands.setUnavailable(false)
    #expect(
      await cache.cachedEdition(
        viewerDID: "did:plc:a", snapshotID: id, generationID: "one", language: "en",
        hiddenStoryIDs: ["hidden"], now: at) == nil)
    await cache.storeEdition(
      viewerDID: "did:plc:a", snapshotID: id, generationID: "one", language: "en",
      hiddenStoryIDs: [], expiresAt: at.addingTimeInterval(60), payload: Data("late".utf8))
    #expect(
      await cache.cachedEdition(
        viewerDID: "did:plc:a", snapshotID: id, generationID: "one", language: "en",
        hiddenStoryIDs: ["hidden"], now: at) == nil)
    await cache.invalidateEditions(viewerDID: "did:plc:a")
    #expect(await commands.keys().isEmpty)
  }

  @Test("cache outage allows reconstruction and writes, while privacy purge remains retryable")
  func outageAndPurge() async throws {
    let commands = CircleRedisTestCommands()
    let at = now
    let cache = RedisCircleDisposableCache(commands: commands, environment: "prod", now: { at })
    try await cache.store(snapshot(viewer: "did:plc:a", generatedAt: at), excludedDIDs: [])
    try await cache.store(snapshot(viewer: "did:plc:b", generatedAt: at), excludedDIDs: [])
    await commands.setUnavailable(true)
    #expect(try await cache.load(viewerDID: "did:plc:a", excludedDIDs: []) == nil)
    try await cache.store(snapshot(viewer: "did:plc:a", generatedAt: at), excludedDIDs: [])
    await #expect(throws: (any Error).self) { try await cache.purge(viewerDID: "did:plc:a") }
    // A new cache instance models another service replica after Redis recovers.
    await commands.setUnavailable(false)
    let recovered = RedisCircleDisposableCache(commands: commands, environment: "prod", now: { at })
    try await recovered.purge(viewerDID: "did:plc:a")
    #expect(try await recovered.load(viewerDID: "did:plc:a", excludedDIDs: []) == nil)
    #expect(try await recovered.load(viewerDID: "did:plc:b", excludedDIDs: []) != nil)
  }

  private func snapshot(viewer: String, generatedAt: Date) -> CircleGraphSnapshot {
    CircleGraphSnapshot(
      snapshotID: UUID(), viewerDID: viewer, directMembers: [], oneHopMembers: [],
      directCandidateCount: 0, oneHopCandidateCount: 0, oneHopExpansionComplete: true,
      generatedAt: generatedAt)
  }
}
