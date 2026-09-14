import Foundation

struct WireLinkMetadataTarget: Equatable, Sendable {
  let canonicalKey: String
  let canonicalURL: String
  let etag: String?
  let lastModified: String?
  let leaseExpiresAt: Date?

  init(
    canonicalKey: String, canonicalURL: String, etag: String?, lastModified: String?,
    leaseExpiresAt: Date? = nil
  ) {
    self.canonicalKey = canonicalKey
    self.canonicalURL = canonicalURL
    self.etag = etag
    self.lastModified = lastModified
    self.leaseExpiresAt = leaseExpiresAt
  }
}
