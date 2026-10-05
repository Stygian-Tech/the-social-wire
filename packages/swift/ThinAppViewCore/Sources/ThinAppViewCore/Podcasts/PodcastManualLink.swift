import Foundation

public struct PodcastManualLink: Codable, Sendable, Equatable {
  public var rssShowId: String
  public var protocolShowId: String
  public init(rssShowId: String, protocolShowId: String) {
    self.rssShowId = rssShowId
    self.protocolShowId = protocolShowId
  }
}
