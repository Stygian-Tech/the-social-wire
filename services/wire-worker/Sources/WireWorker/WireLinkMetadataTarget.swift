import Foundation

struct WireLinkMetadataTarget: Equatable, Sendable {
  let canonicalKey: String
  let canonicalURL: String
  let etag: String?
  let lastModified: String?
}
