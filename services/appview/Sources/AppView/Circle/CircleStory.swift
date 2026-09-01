import Foundation
import WireCore

struct CircleStory: Codable, Equatable, Sendable {
  let storyID: String
  let canonicalURL: String
  let representativeURI: String?
  let title: String
  let summary: String?
  let publishedAt: Date?
  let thumbnailURL: String?
  let source: WireItemSource
  let reasons: [String]
  let discussionCount: Int
  let sharerCount: Int
  let sharers: [CircleSharer]

  enum CodingKeys: String, CodingKey {
    case title, summary, publishedAt, source, reasons, discussionCount, sharerCount, sharers
    case storyID = "storyId"
    case canonicalURL = "canonicalUrl"
    case representativeURI = "representativeUri"
    case thumbnailURL = "thumbnailUrl"
  }
}
