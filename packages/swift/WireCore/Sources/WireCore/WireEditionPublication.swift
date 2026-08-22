public struct WireEditionPublication: Codable, Equatable, Sendable {
  public let key: String
  public let id: String?
  public let name: String
  public let domain: String
  public let homepageURL: String?
  public let iconURL: String?

  public init(
    key: String,
    id: String?,
    name: String,
    domain: String,
    homepageURL: String?,
    iconURL: String?
  ) {
    self.key = key
    self.id = id
    self.name = name
    self.domain = domain
    self.homepageURL = homepageURL
    self.iconURL = iconURL
  }

  private enum CodingKeys: String, CodingKey {
    case key
    case id
    case name
    case domain
    case homepageURL = "homepageUrl"
    case iconURL = "iconUrl"
  }
}
