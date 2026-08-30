import Foundation

struct CircleGraphMember: Codable, Equatable, Sendable {
  let actorDID: String
  let depth: CircleGraphDepth
  let pathCount: Int
  let recentActivityAt: Date?
}
