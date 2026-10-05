import Foundation

public struct PodcastPerson: Codable, Sendable, Equatable {
  public var name: String
  public var role: String?
  public var imageUrl: String?
  public var url: String?
  public init(name: String, role: String? = nil, imageUrl: String? = nil, url: String? = nil) {
    self.name = name
    self.role = role
    self.imageUrl = imageUrl
    self.url = url
  }
}
