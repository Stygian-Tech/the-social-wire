import Foundation

struct CircleSharer: Codable, Equatable, Sendable {
  let identity: CirclePublicIdentity
  let relationship: String
  let action: String
  let sourceURI: String
  let timestamp: Date

  enum CodingKeys: String, CodingKey {
    case identity, relationship, action, timestamp
    case sourceURI = "sourceUri"
  }
}
