struct CirclePublicIdentity: Codable, Equatable, Sendable {
  let did: String
  let handle: String
  let displayName: String?
  let avatarURL: String?

  enum CodingKeys: String, CodingKey {
    case did, handle, displayName
    case avatarURL = "avatarUrl"
  }
}
