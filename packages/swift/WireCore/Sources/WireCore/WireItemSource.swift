public struct WireItemSource: Codable, Equatable, Sendable {
  public let name: String
  public let domain: String
  public let publication: String?
  public let author: String?

  public init(name: String, domain: String, publication: String? = nil, author: String? = nil) {
    self.name = name
    self.domain = domain
    self.publication = publication
    self.author = author
  }
}
