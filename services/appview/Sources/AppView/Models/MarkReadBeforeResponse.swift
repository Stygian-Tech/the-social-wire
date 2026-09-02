import Hummingbird

struct MarkReadBeforeResponse: Codable, Sendable, ResponseEncodable {
  let marked: Int
  let entryIds: [String]
  let readAt: String
  let unreadCounts: [String: Int]
}
