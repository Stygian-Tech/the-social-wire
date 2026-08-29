import Foundation

struct WireLinkMetadata: Equatable, Sendable {
  enum Source: String, Sendable {
    case openGraph = "open_graph"
    case embeddedCard = "embedded_card"
  }

  let canonicalURL: String
  let title: String?
  let description: String?
  let imageURL: String?
  let siteName: String?
  let authorName: String?
  let publishedAt: Date?
  let iconURL: String?
  let etag: String?
  let lastModified: String?
  let source: Source
  let languageCode: String?
  let hasProductOfferSchema: Bool

  init(
    canonicalURL: String,
    title: String?,
    description: String?,
    imageURL: String?,
    siteName: String?,
    authorName: String?,
    publishedAt: Date?,
    iconURL: String?,
    etag: String?,
    lastModified: String?,
    source: Source,
    languageCode: String? = nil,
    hasProductOfferSchema: Bool = false
  ) {
    self.canonicalURL = canonicalURL
    self.title = title
    self.description = description
    self.imageURL = imageURL
    self.siteName = siteName
    self.authorName = authorName
    self.publishedAt = publishedAt
    self.iconURL = iconURL
    self.etag = etag
    self.lastModified = lastModified
    self.source = source
    self.languageCode = languageCode
    self.hasProductOfferSchema = hasProductOfferSchema
  }
}
