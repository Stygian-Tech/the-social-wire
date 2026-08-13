import Foundation

public struct RedisCachePolicy: Sendable, Equatable {
  public let freshDuration: TimeInterval
  public let hardDuration: TimeInterval
  public let maximumJitterFraction: Double

  public init(
    freshDuration: TimeInterval,
    hardDuration: TimeInterval,
    maximumJitterFraction: Double = 0.1
  ) {
    precondition(freshDuration > 0)
    precondition(hardDuration >= freshDuration)
    precondition((0...0.1).contains(maximumJitterFraction))
    self.freshDuration = freshDuration
    self.hardDuration = hardDuration
    self.maximumJitterFraction = maximumJitterFraction
  }
}
