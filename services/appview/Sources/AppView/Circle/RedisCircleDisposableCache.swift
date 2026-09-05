import Foundation
import SocialWireRedis

/// Two bounded, expiring keys per viewer; PostgreSQL owns persistent hides.
actor RedisCircleDisposableCache: CircleDisposableCaching {
  private struct SnapshotEntry: Codable, Sendable {
    let exclusions: Set<String>
    let snapshot: CircleGraphSnapshot
  }

  private struct EditionEntry: Codable, Sendable {
    let snapshotID: UUID
    let generationID: String
    let language: String
    let hiddenStoryIDs: Set<String>
    let payload: Data
  }

  private let cache: RedisCacheClient
  private let namespace: RedisKeyNamespace
  private let now: @Sendable () -> Date

  init(
    commands: any RedisCommandClient,
    environment: String,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    cache = RedisCacheClient(commands: commands)
    namespace = RedisKeyNamespace(environment: environment)
    self.now = now
  }

  func load(viewerDID: String, excludedDIDs: Set<String>) async throws -> CircleGraphSnapshot? {
    guard
      let entry = await lookup(
        SnapshotEntry.self, domain: "circle-graph", viewer: viewerDID, at: now()),
      entry.exclusions == excludedDIDs, entry.snapshot.viewerDID == viewerDID
    else { return nil }
    return entry.snapshot
  }

  func store(_ snapshot: CircleGraphSnapshot, excludedDIDs: Set<String>) async throws {
    let at = now()
    let remaining = snapshot.generatedAt.addingTimeInterval(CircleGraphSnapshotService.staleMaximum)
      .timeIntervalSince(at)
    guard remaining > 0 else { return }
    try? await cache.store(
      SnapshotEntry(exclusions: excludedDIDs, snapshot: snapshot),
      key: key("circle-graph", snapshot.viewerDID),
      policy: RedisCachePolicy(
        freshDuration: min(CircleGraphSnapshotService.freshTarget, remaining),
        hardDuration: remaining, maximumJitterFraction: 0
      ), now: at
    )
  }

  func cachedEdition(
    viewerDID: String, snapshotID: UUID, generationID: String, language: String,
    hiddenStoryIDs: Set<String>, now: Date
  ) async -> Data? {
    guard
      let entry = await lookup(
        EditionEntry.self, domain: "circle-edition", viewer: viewerDID, at: now),
      entry.snapshotID == snapshotID, entry.generationID == generationID,
      entry.language == language, entry.hiddenStoryIDs == hiddenStoryIDs
    else { return nil }
    return entry.payload
  }

  func storeEdition(
    viewerDID: String, snapshotID: UUID, generationID: String, language: String,
    hiddenStoryIDs: Set<String>, expiresAt: Date, payload: Data
  ) async {
    let at = now()
    let remaining = min(expiresAt.timeIntervalSince(at), 10 * 60)
    guard remaining > 0 else { return }
    try? await cache.store(
      EditionEntry(
        snapshotID: snapshotID, generationID: generationID, language: language,
        hiddenStoryIDs: hiddenStoryIDs, payload: payload
      ), key: key("circle-edition", viewerDID),
      policy: RedisCachePolicy(
        freshDuration: remaining, hardDuration: remaining, maximumJitterFraction: 0
      ), now: at
    )
  }

  func invalidateEditions(viewerDID: String) async {
    // Even a failed invalidation cannot serve an old hide set: reads bind to
    // the durable set captured for this request, as do in-flight cache writes.
    try? await cache.delete([key("circle-edition", viewerDID)])
  }

  func purge(viewerDID: String) async throws {
    // A privacy purge must report an unavailable cache so deletion can be retried.
    try await cache.delete([key("circle-graph", viewerDID), key("circle-edition", viewerDID)])
  }

  private func key(_ domain: String, _ viewer: String) -> String {
    namespace.key(domain: domain, identifiers: [viewer])
  }

  private func lookup<Value: Codable & Sendable>(
    _ type: Value.Type, domain: String, viewer: String, at: Date
  ) async -> Value? {
    guard
      let result = try? await cache.lookup(
        type, key: key(domain, viewer), cacheType: domain, now: at)
    else { return nil }
    switch result {
    case .fresh(let envelope), .stale(let envelope): return envelope.value
    case .miss: return nil
    }
  }
}
