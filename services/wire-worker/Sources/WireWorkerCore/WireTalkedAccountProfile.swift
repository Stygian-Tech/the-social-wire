import Foundation

struct WireTalkedAccountProfile: Equatable, Sendable {
  let did: String
  let handle: String
  let displayName: String?
  let avatarURL: String?
  let description: String?
}
