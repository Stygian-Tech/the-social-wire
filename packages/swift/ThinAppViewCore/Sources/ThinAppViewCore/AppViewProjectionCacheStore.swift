import Foundation

public enum AppViewProjectionCacheTTL {
  public static let sidebarSeconds: TimeInterval = 5 * 60
  public static let unreadCountsSeconds: TimeInterval = 2 * 60
  public static let firstPageSeconds: TimeInterval = 5 * 60
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
  public let expiresAt: Date
  public let source: AppViewProjectionCacheSource

  public init(
    value: Value,
    cachedAt: Date,
    expiresAt: Date,
    source: AppViewProjectionCacheSource = .projectionCache
  ) {
    self.value = value
    self.cachedAt = cachedAt
    self.expiresAt = expiresAt
    self.source = source
  }
}

public protocol AppViewProjectionCacheStore: Actor {
  func sidebarProjectionCacheEntry(
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

  func deleteExpiredProjectionCaches(before: Date, batchSize: Int) async throws -> Int
}

public extension AppViewProjectionCacheStore {
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
