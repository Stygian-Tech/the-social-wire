import Foundation

struct WirePublicationCacheValue: Codable, Sendable {
  let metadata: WirePublicationMetadata?
  let expiresAt: Date
}

struct WirePublicationCacheLookup: Sendable {
  let token: String
  let value: WirePublicationCacheValue?
}

protocol WirePublicationCaching: Sendable {
  func lookup(_ uri: String, asOf: Date) async throws -> WirePublicationCacheLookup
  func fill(_ uri: String, token: String, value: WirePublicationCacheValue, asOf: Date) async throws
  func invalidateAccount(_ repoDID: String) async throws
  func invalidate(_ uri: String) async throws
}
