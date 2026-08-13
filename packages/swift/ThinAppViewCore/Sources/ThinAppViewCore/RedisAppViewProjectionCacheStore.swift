import Foundation
import Logging
import SocialWireRedis

public actor RedisAppViewProjectionCacheStore: AppViewProjectionCacheStore {
  private struct UnreadCacheValue: Codable, Sendable {
    let publicationId: String
    let count: Int
  }

  private let commands: any RedisCommandClient
  private let cache: RedisCacheClient
  private let leases: RedisLeaseCoordinator
  private let namespace: RedisKeyNamespace
  private let logger: Logger
  private let telemetry: RedisTelemetrySink?
  private let sidebarPolicy: RedisCachePolicy
  private let unreadPolicy: RedisCachePolicy
  private let firstPagePolicy: RedisCachePolicy
  private var lastRefreshLeaseWarningAt = Date.distantPast
  private static let refreshLeaseWarningCooldown: TimeInterval = 60

  public init(
    commands: any RedisCommandClient,
    environment: String,
    logger: Logger,
    telemetry: RedisTelemetrySink? = nil,
    sidebarPolicy: RedisCachePolicy = RedisCachePolicy(
      freshDuration: AppViewProjectionCacheTTL.sidebarSeconds,
      hardDuration: AppViewProjectionCacheTTL.sidebarHardSeconds
    ),
    unreadPolicy: RedisCachePolicy = RedisCachePolicy(
      freshDuration: AppViewProjectionCacheTTL.unreadCountsSeconds,
      hardDuration: AppViewProjectionCacheTTL.unreadCountsHardSeconds
    ),
    firstPagePolicy: RedisCachePolicy = RedisCachePolicy(
      freshDuration: AppViewProjectionCacheTTL.firstPageSeconds,
      hardDuration: AppViewProjectionCacheTTL.firstPageHardSeconds
    )
  ) {
    self.commands = commands
    self.cache = RedisCacheClient(commands: commands, telemetry: telemetry)
    self.namespace = RedisKeyNamespace(environment: environment)
    self.leases = RedisLeaseCoordinator(
      commands: commands,
      namespace: RedisKeyNamespace(environment: environment),
      telemetry: telemetry
    )
    self.logger = logger
    self.telemetry = telemetry
    self.sidebarPolicy = sidebarPolicy
    self.unreadPolicy = unreadPolicy
    self.firstPagePolicy = firstPagePolicy
  }

  public func sidebarProjectionCacheEntry(
    viewerDid: String
  ) async throws -> AppViewProjectionCacheEntry<String>? {
    guard case .fresh(let entry) = try await sidebarProjectionCacheLookup(viewerDid: viewerDid) else {
      return nil
    }
    return entry
  }

  public func sidebarProjectionCacheEntryIncludingExpired(
    viewerDid: String
  ) async throws -> AppViewProjectionCacheEntry<String>? {
    switch try await sidebarProjectionCacheLookup(viewerDid: viewerDid) {
    case .fresh(let entry), .stale(let entry): entry
    case .miss: nil
    }
  }

  public func sidebarProjectionCacheLookup(
    viewerDid: String,
    now: Date = Date()
  ) async throws -> AppViewProjectionCacheLookup<String> {
    try await lookup(String.self, key: sidebarKey(viewerDid), now: now)
  }

  public func storeSidebarProjectionJSON(
    viewerDid: String,
    jsonBody: String,
    expiresAt: Date
  ) async throws {
    _ = expiresAt
    try await cache.store(jsonBody, key: sidebarKey(viewerDid), policy: sidebarPolicy)
  }

  public func invalidateSidebarProjection(viewerDid: String) async throws {
    try await cache.delete([sidebarKey(viewerDid)])
  }

  public func unreadCountsCacheEntry(
    viewerDid: String
  ) async throws -> AppViewProjectionCacheEntry<[String: Int]>? {
    switch try await unreadCountsCacheLookup(viewerDid: viewerDid) {
    case .fresh(let entry), .stale(let entry): entry
    case .miss: nil
    }
  }

  public func unreadCountsCacheLookup(
    viewerDid: String,
    now: Date = Date()
  ) async throws -> AppViewProjectionCacheLookup<[String: Int]> {
    let keys = try await scanKeys(matching: namespace.pattern(domain: "unread", fixedIdentifiers: [viewerDid]))
    return try await unreadCountsLookup(keys: keys, now: now)
  }

  public func unreadCountsCacheLookup(
    viewerDid: String,
    publicationIds: [String],
    now: Date = Date()
  ) async throws -> AppViewProjectionCacheLookup<[String: Int]> {
    let keys = Set(publicationIds).map {
      unreadKey(viewerDid: viewerDid, publicationId: $0)
    }
    return try await unreadCountsLookup(keys: keys, now: now)
  }

  private func unreadCountsLookup(
    keys: [String],
    now: Date
  ) async throws -> AppViewProjectionCacheLookup<[String: Int]> {
    guard !keys.isEmpty else { return .miss }

    var counts: [String: Int] = [:]
    var cachedAt = Date.distantFuture
    var freshUntil = Date.distantFuture
    var hardExpiresAt = Date.distantFuture
    var containsStale = false
    for key in keys {
      switch try await cache.lookup(UnreadCacheValue.self, key: key, cacheType: "unread", now: now) {
      case .fresh(let envelope):
        counts[envelope.value.publicationId] = envelope.value.count
        cachedAt = min(cachedAt, envelope.cachedAt)
        freshUntil = min(freshUntil, envelope.freshUntil)
        hardExpiresAt = min(hardExpiresAt, envelope.hardExpiresAt)
      case .stale(let envelope):
        containsStale = true
        counts[envelope.value.publicationId] = envelope.value.count
        cachedAt = min(cachedAt, envelope.cachedAt)
        freshUntil = min(freshUntil, envelope.freshUntil)
        hardExpiresAt = min(hardExpiresAt, envelope.hardExpiresAt)
      case .miss:
        continue
      }
    }
    guard !counts.isEmpty else { return .miss }
    let entry = AppViewProjectionCacheEntry(
      value: counts,
      cachedAt: cachedAt,
      freshUntil: freshUntil,
      hardExpiresAt: hardExpiresAt
    )
    return containsStale ? .stale(entry) : .fresh(entry)
  }

  public func storeUnreadCounts(
    viewerDid: String,
    counts: [String: Int],
    expiresAt: Date
  ) async throws {
    _ = expiresAt
    try await withThrowingTaskGroup(of: Void.self) { group in
      for (publicationId, count) in counts {
        group.addTask {
          try await self.cache.store(
            UnreadCacheValue(publicationId: publicationId, count: count),
            key: self.unreadKey(viewerDid: viewerDid, publicationId: publicationId),
            policy: self.unreadPolicy
          )
        }
      }
      try await group.waitForAll()
    }
  }

  public func invalidateUnreadCounts(viewerDid: String, publicationId: String?) async throws {
    if let publicationId {
      try await cache.delete([unreadKey(viewerDid: viewerDid, publicationId: publicationId)])
      return
    }
    try await deleteKeys(matching: namespace.pattern(domain: "unread", fixedIdentifiers: [viewerDid]))
  }

  public func firstPageCacheEntry(
    viewerDid: String,
    publicationId: String
  ) async throws -> AppViewProjectionCacheEntry<String>? {
    switch try await firstPageCacheLookup(viewerDid: viewerDid, publicationId: publicationId) {
    case .fresh(let entry), .stale(let entry): entry
    case .miss: nil
    }
  }

  public func firstPageCacheLookup(
    viewerDid: String,
    publicationId: String,
    now: Date = Date()
  ) async throws -> AppViewProjectionCacheLookup<String> {
    try await lookup(String.self, key: firstPageKey(viewerDid: viewerDid, publicationId: publicationId), now: now)
  }

  public func storeFirstPageJSON(
    viewerDid: String,
    publicationId: String,
    jsonBody: String,
    expiresAt: Date
  ) async throws {
    _ = expiresAt
    try await cache.store(
      jsonBody,
      key: firstPageKey(viewerDid: viewerDid, publicationId: publicationId),
      policy: firstPagePolicy
    )
  }

  public func invalidateFirstPage(viewerDid: String, publicationId: String?) async throws {
    if let publicationId {
      try await cache.delete([firstPageKey(viewerDid: viewerDid, publicationId: publicationId)])
      return
    }
    try await deleteKeys(matching: namespace.pattern(domain: "firstpage"))
  }

  public func invalidateFirstPageForAllViewers(publicationId: String) async throws {
    try await deleteKeys(matching: namespace.pattern(domain: "firstpage", fixedIdentifiers: [publicationId]))
  }

  public func invalidateAllProjectionCaches() async throws {
    for domain in ["sidebar", "unread", "firstpage"] {
      try await deleteKeys(matching: namespace.pattern(domain: domain))
    }
  }

  public func acquireRefreshLease(
    domain: String,
    resource: String,
    ttl: TimeInterval
  ) async -> AppViewProjectionRefreshLease? {
    do {
      guard let lease = try await leases.acquire(domain: domain, resource: resource, ttl: ttl) else {
        return nil
      }
      return AppViewProjectionRefreshLease(
        key: lease.key,
        owner: lease.owner,
        ttlMilliseconds: lease.ttlMilliseconds
      )
    } catch {
      let now = Date()
      if now.timeIntervalSince(lastRefreshLeaseWarningAt) >= Self.refreshLeaseWarningCooldown {
        lastRefreshLeaseWarningAt = now
        logger.warning("Redis refresh lease unavailable; allowing fail-open rebuild", metadata: [
          "operation": .string(domain),
          "error_category": .string("command_failed"),
        ])
      }
      return AppViewProjectionRefreshLease(
        key: "",
        owner: UUID().uuidString.lowercased(),
        ttlMilliseconds: max(1, Int(ttl * 1_000))
      )
    }
  }

  public func releaseRefreshLease(_ lease: AppViewProjectionRefreshLease) async {
    guard !lease.key.isEmpty else { return }
    _ = try? await leases.release(
      RedisLease(
        key: lease.key,
        owner: lease.owner,
        ttlMilliseconds: lease.ttlMilliseconds
      )
    )
  }

  public func renewRefreshLease(_ lease: AppViewProjectionRefreshLease) async -> Bool {
    guard !lease.key.isEmpty else { return true }
    return (try? await leases.renew(
      RedisLease(
        key: lease.key,
        owner: lease.owner,
        ttlMilliseconds: lease.ttlMilliseconds
      )
    )) ?? false
  }

  public func deleteExpiredProjectionCaches(before: Date, batchSize: Int) async throws -> Int {
    _ = before
    _ = batchSize
    return 0
  }

  private func lookup<Value: Codable & Sendable>(
    _ type: Value.Type,
    key: String,
    now: Date,
    cacheType: String? = nil
  ) async throws -> AppViewProjectionCacheLookup<Value> {
    do {
      switch try await cache.lookup(
        type,
        key: key,
        cacheType: cacheType ?? cacheTypeForKey(key),
        now: now
      ) {
      case .fresh(let envelope):
        return .fresh(entry(envelope))
      case .stale(let envelope):
        return .stale(entry(envelope))
      case .miss:
        return .miss
      }
    } catch {
      telemetry?(.init(
        kind: .cacheLookup,
        operation: cacheType ?? cacheTypeForKey(key),
        outcome: "fallback"
      ))
      logger.warning("Redis projection cache lookup failed", metadata: [
        "error_category": .string("command_failed")
      ])
      return .miss
    }
  }

  private func cacheTypeForKey(_ key: String) -> String {
    if key.contains(":sidebar:") { return "sidebar" }
    if key.contains(":unread:") { return "unread" }
    if key.contains(":firstpage:") { return "first_page" }
    return "projection"
  }

  private func entry<Value: Codable & Sendable>(
    _ envelope: RedisCacheEnvelope<Value>
  ) -> AppViewProjectionCacheEntry<Value> {
    AppViewProjectionCacheEntry(
      value: envelope.value,
      cachedAt: envelope.cachedAt,
      freshUntil: envelope.freshUntil,
      hardExpiresAt: envelope.hardExpiresAt
    )
  }

  private func sidebarKey(_ viewerDid: String) -> String {
    namespace.key(domain: "sidebar", identifiers: [viewerDid])
  }

  private func unreadKey(viewerDid: String, publicationId: String) -> String {
    namespace.key(domain: "unread", identifiers: [viewerDid, publicationId])
  }

  private func firstPageKey(viewerDid: String, publicationId: String) -> String {
    namespace.key(domain: "firstpage", identifiers: [publicationId, viewerDid])
  }

  private func deleteKeys(matching pattern: String) async throws {
    let keys = try await scanKeys(matching: pattern)
    for batchStart in stride(from: 0, to: keys.count, by: 250) {
      let end = min(batchStart + 250, keys.count)
      try await cache.delete(Array(keys[batchStart..<end]))
    }
  }

  private func scanKeys(matching pattern: String) async throws -> [String] {
    var cursor = "0"
    var keys: [String] = []
    repeat {
      let response = try await commands.execute(
        command: "SCAN",
        arguments: [
          .data(Data(cursor.utf8)),
          .data(Data("MATCH".utf8)),
          .data(Data(pattern.utf8)),
          .data(Data("COUNT".utf8)),
          .integer(250),
        ]
      )
      guard case .array(let parts) = response,
            parts.count == 2,
            let nextCursor = parts[0].string,
            case .array(let keyValues) = parts[1]
      else { return keys }
      cursor = nextCursor
      keys.append(contentsOf: keyValues.compactMap(\.string))
    } while cursor != "0"
    return keys
  }
}
