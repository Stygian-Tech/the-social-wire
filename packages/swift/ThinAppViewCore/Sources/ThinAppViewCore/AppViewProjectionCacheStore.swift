import Foundation

public enum AppViewProjectionCacheTTL {
  // Sidebar membership is invalidated on mutations and refreshed in the
  // background by bootstrap. Keep it available across an active session so
  // aggregate feeds do not fall off a five-minute latency cliff.
  public static let sidebarSeconds: TimeInterval = 60 * 60
  public static let unreadCountsSeconds: TimeInterval = 2 * 60
  public static let firstPageSeconds: TimeInterval = 5 * 60
  public static let sidebarHardSeconds: TimeInterval = 6 * 60 * 60
  public static let unreadCountsHardSeconds: TimeInterval = 15 * 60
  public static let firstPageHardSeconds: TimeInterval = 30 * 60
}

public enum AppViewProjectionCacheViewerKeys {
  public static let sharedFirstPage = "__shared_first_page__"
}

public enum AppViewProjectionCacheSource: String, Codable, Sendable, Equatable {
  case projectionCache = "projection_cache"
}

/// A cached projection together with the timestamps needed to report its real age.
public struct AppViewProjectionCacheEntry<Value: Sendable>: Sendable {
  public let value: Value
  public let cachedAt: Date
  public let freshUntil: Date
  public let hardExpiresAt: Date
  public let source: AppViewProjectionCacheSource

  public var expiresAt: Date { freshUntil }

  public init(
    value: Value,
    cachedAt: Date,
    expiresAt: Date,
    hardExpiresAt: Date = .distantFuture,
    source: AppViewProjectionCacheSource = .projectionCache
  ) {
    self.value = value
    self.cachedAt = cachedAt
    self.freshUntil = expiresAt
    self.hardExpiresAt = hardExpiresAt
    self.source = source
  }

  public init(
    value: Value,
    cachedAt: Date,
    freshUntil: Date,
    hardExpiresAt: Date,
    source: AppViewProjectionCacheSource = .projectionCache
  ) {
    self.value = value
    self.cachedAt = cachedAt
    self.freshUntil = freshUntil
    self.hardExpiresAt = hardExpiresAt
    self.source = source
  }
}

public enum AppViewProjectionCacheLookup<Value: Sendable>: Sendable {
  case fresh(AppViewProjectionCacheEntry<Value>)
  case stale(AppViewProjectionCacheEntry<Value>)
  case miss
}

public struct AppViewProjectionRefreshLease: Sendable, Equatable {
  public let key: String
  public let owner: String
  public let ttlMilliseconds: Int

  public init(key: String, owner: String, ttlMilliseconds: Int) {
    self.key = key
    self.owner = owner
    self.ttlMilliseconds = ttlMilliseconds
  }
}

public protocol AppViewProjectionCacheStore: Actor {
  func sidebarProjectionCacheEntry(
    viewerDid: String
  ) async throws -> AppViewProjectionCacheEntry<String>?
  func sidebarProjectionCacheEntryIncludingExpired(
    viewerDid: String
  ) async throws -> AppViewProjectionCacheEntry<String>?
  func storeSidebarProjectionJSON(
    viewerDid: String,
    jsonBody: String,
    expiresAt: Date
  ) async throws
  func invalidateSidebarProjection(viewerDid: String) async throws

  func unreadCountsCacheEntry(
    viewerDid: String
  ) async throws -> AppViewProjectionCacheEntry<[String: Int]>?
  func unreadCountsCacheLookup(
    viewerDid: String,
    publicationIds: [String],
    now: Date
  ) async throws -> AppViewProjectionCacheLookup<[String: Int]>
  func storeUnreadCounts(
    viewerDid: String,
    counts: [String: Int],
    expiresAt: Date
  ) async throws
  func invalidateUnreadCounts(viewerDid: String, publicationId: String?) async throws

  func firstPageCacheEntry(
    viewerDid: String,
    publicationId: String
  ) async throws -> AppViewProjectionCacheEntry<String>?
  func storeFirstPageJSON(
    viewerDid: String,
    publicationId: String,
    jsonBody: String,
    expiresAt: Date
  ) async throws
  func invalidateFirstPage(viewerDid: String, publicationId: String?) async throws
  func invalidateFirstPageForAllViewers(publicationId: String) async throws

  /// Account lifecycle changes can invalidate every projection that references the repository.
  func invalidateAllProjectionCaches() async throws

  func acquireRefreshLease(
    domain: String,
    resource: String,
    ttl: TimeInterval
  ) async -> AppViewProjectionRefreshLease?
  func renewRefreshLease(_ lease: AppViewProjectionRefreshLease) async -> Bool
  func releaseRefreshLease(_ lease: AppViewProjectionRefreshLease) async

  func deleteExpiredProjectionCaches(before: Date, batchSize: Int) async throws -> Int
}

public extension AppViewProjectionCacheStore {
  func acquireRefreshLease(
    domain: String,
    resource: String,
    ttl: TimeInterval
  ) async -> AppViewProjectionRefreshLease? {
    AppViewProjectionRefreshLease(
      key: "local:\(domain)",
      owner: UUID().uuidString.lowercased(),
      ttlMilliseconds: max(1, Int(ttl * 1_000))
    )
  }

  func releaseRefreshLease(_ lease: AppViewProjectionRefreshLease) async {
    _ = lease
  }

  func renewRefreshLease(_ lease: AppViewProjectionRefreshLease) async -> Bool {
    _ = lease
    return true
  }

  func sidebarProjectionCacheLookup(
    viewerDid: String,
    now: Date = Date()
  ) async throws -> AppViewProjectionCacheLookup<String> {
    if let fresh = try await sidebarProjectionCacheEntry(viewerDid: viewerDid) {
      return .fresh(fresh)
    }
    if let stale = try await sidebarProjectionCacheEntryIncludingExpired(viewerDid: viewerDid),
       now < stale.hardExpiresAt
    {
      return .stale(stale)
    }
    return .miss
  }

  func unreadCountsCacheLookup(
    viewerDid: String,
    now: Date = Date()
  ) async throws -> AppViewProjectionCacheLookup<[String: Int]> {
    guard let entry = try await unreadCountsCacheEntry(viewerDid: viewerDid) else { return .miss }
    if now < entry.freshUntil { return .fresh(entry) }
    if now < entry.hardExpiresAt { return .stale(entry) }
    return .miss
  }

  func unreadCountsCacheLookup(
    viewerDid: String,
    publicationIds: [String],
    now: Date = Date()
  ) async throws -> AppViewProjectionCacheLookup<[String: Int]> {
    let requested = Set(publicationIds)
    switch try await unreadCountsCacheLookup(viewerDid: viewerDid, now: now) {
    case .fresh(let entry):
      return .fresh(AppViewProjectionCacheEntry(
        value: entry.value.filter { requested.contains($0.key) },
        cachedAt: entry.cachedAt,
        freshUntil: entry.freshUntil,
        hardExpiresAt: entry.hardExpiresAt,
        source: entry.source
      ))
    case .stale(let entry):
      return .stale(AppViewProjectionCacheEntry(
        value: entry.value.filter { requested.contains($0.key) },
        cachedAt: entry.cachedAt,
        freshUntil: entry.freshUntil,
        hardExpiresAt: entry.hardExpiresAt,
        source: entry.source
      ))
    case .miss:
      return .miss
    }
  }

  func firstPageCacheLookup(
    viewerDid: String,
    publicationId: String,
    now: Date = Date()
  ) async throws -> AppViewProjectionCacheLookup<String> {
    guard let entry = try await firstPageCacheEntry(
      viewerDid: viewerDid,
      publicationId: publicationId
    ) else { return .miss }
    if now < entry.freshUntil { return .fresh(entry) }
    if now < entry.hardExpiresAt { return .stale(entry) }
    return .miss
  }

  func sidebarProjectionCacheEntryIncludingExpired(
    viewerDid: String
  ) async throws -> AppViewProjectionCacheEntry<String>? {
    try await sidebarProjectionCacheEntry(viewerDid: viewerDid)
  }

  func cachedSidebarProjectionJSON(viewerDid: String) async throws -> String? {
    try await sidebarProjectionCacheEntry(viewerDid: viewerDid)?.value
  }

  func cachedUnreadCounts(viewerDid: String) async throws -> [String: Int]? {
    try await unreadCountsCacheEntry(viewerDid: viewerDid)?.value
  }

  func cachedFirstPageJSON(viewerDid: String, publicationId: String) async throws -> String? {
    try await firstPageCacheEntry(viewerDid: viewerDid, publicationId: publicationId)?.value
  }
}

public enum AppViewProjectionCacheScopeKeys {
  public static func publicationSiteKeys(
    publicationAtUri: String?,
    publicationScopeAtUris: [String],
    publicationSiteUrls: [String]
  ) -> [String] {
    var keys = Set<String>()
    if let publicationAtUri {
      keys.formUnion(RenderFieldExtractor.publicationFilterEquivalenceKeys(publicationAtUri: publicationAtUri))
    }
    for uri in publicationScopeAtUris {
      if let key = RenderFieldExtractor.canonicalPublicationAtUriKey(uri) {
        keys.insert(key)
      }
    }
    for url in publicationSiteUrls {
      if let normalized = RssFeedIdentity.normalizeFeedUrl(url) {
        keys.insert(normalized)
      }
      if let normalized = RenderFieldExtractor.normalizePublicationSiteUrl(url) {
        keys.insert(normalized)
      }
    }
    return Array(keys).sorted()
  }
}
