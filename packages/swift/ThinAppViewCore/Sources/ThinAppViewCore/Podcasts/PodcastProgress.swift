import Foundation

public struct PodcastProgress: Codable, Sendable, Equatable {
  public var positionSeconds: Double
  public var updatedAt: String
  public var completed: Bool
  public init(positionSeconds: Double, updatedAt: String, completed: Bool = false) {
    self.positionSeconds = positionSeconds
    self.updatedAt = updatedAt
    self.completed = completed
  }
}
