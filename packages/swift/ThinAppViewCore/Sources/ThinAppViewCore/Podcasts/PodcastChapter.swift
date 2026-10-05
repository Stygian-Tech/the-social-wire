import Foundation

public struct PodcastChapter: Codable, Sendable, Equatable {
  public var startSeconds: Double
  public var title: String
  public var artworkUrl: String?
  public var url: String?
  public init(startSeconds: Double, title: String, artworkUrl: String? = nil, url: String? = nil) {
    self.startSeconds = startSeconds
    self.title = title
    self.artworkUrl = artworkUrl
    self.url = url
  }
}
