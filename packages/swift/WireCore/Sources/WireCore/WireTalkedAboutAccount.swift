public struct WireTalkedAboutAccount: Codable, Equatable, Sendable {
  public let did: String
  public let handle: String?
  public let displayName: String?
  public let avatarURL: String?
  public let description: String?

  public init(
    did: String,
    handle: String?,
    displayName: String?,
    avatarURL: String?,
    description: String? = nil
  ) {
    self.did = did
    self.handle = handle
    self.displayName = displayName
    self.avatarURL = avatarURL
    self.description = description
  }

  private enum CodingKeys: String, CodingKey {
    case did
    case handle
    case displayName
    case avatarURL = "avatarUrl"
    case description
  }
}
