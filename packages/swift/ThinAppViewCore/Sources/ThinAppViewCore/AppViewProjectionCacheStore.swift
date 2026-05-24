import Foundation

public enum AppViewProjectionCacheTTL {
  public static let sidebarSeconds: TimeInterval = 5 * 60
  public static let unreadCountsSeconds: TimeInterval = 2 * 60
  public static let firstPageSeconds: TimeInterval = 60
}

public protocol AppViewProjectionCacheStore: Actor {
  func cachedSidebarProjectionJSON(viewerDid: String) async throws -> String?
  func storeSidebarProjectionJSON(
    viewerDid: String,
    jsonBody: String,
    expiresAt: Date
  ) async throws
  func invalidateSidebarProjection(viewerDid: String) async throws

  func cachedUnreadCounts(viewerDid: String) async throws -> [String: Int]?
  func storeUnreadCounts(
    viewerDid: String,
    counts: [String: Int],
    expiresAt: Date
  ) async throws
  func invalidateUnreadCounts(viewerDid: String, publicationId: String?) async throws

  func cachedFirstPageJSON(viewerDid: String, publicationId: String) async throws -> String?
  func storeFirstPageJSON(
    viewerDid: String,
    publicationId: String,
    jsonBody: String,
    expiresAt: Date
  ) async throws
  func invalidateFirstPage(viewerDid: String, publicationId: String?) async throws
  func invalidateFirstPageForAllViewers(publicationId: String) async throws

  func deleteExpiredProjectionCaches(before: Date) async throws -> Int
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
      if let normalized = RenderFieldExtractor.normalizePublicationSiteUrl(url) {
        keys.insert(normalized)
      }
    }
    return Array(keys).sorted()
  }
}
