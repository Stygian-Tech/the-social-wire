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
}
