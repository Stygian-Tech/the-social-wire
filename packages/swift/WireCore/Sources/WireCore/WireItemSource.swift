public struct WireItemSource: Codable, Equatable, Sendable {
  public let name: String
  public let domain: String
  public let publication: String?
  public let author: String?
  public let publicationKey: String?
  public let homepageURL: String?
  public let iconURL: String?

  public init(
    name: String,
    domain: String,
    publication: String? = nil,
    author: String? = nil,
    publicationKey: String? = nil,
    homepageURL: String? = nil,
    iconURL: String? = nil
  ) {
    self.name = name
    self.domain = domain
    self.publication = publication
    self.author = author
    self.publicationKey = publicationKey
    self.homepageURL = homepageURL
    self.iconURL = iconURL
  }

  private enum CodingKeys: String, CodingKey {
    case name
    case domain
    case publication
    case author
    case publicationKey
    case homepageURL = "homepageUrl"
    case iconURL = "iconUrl"
  }
}
