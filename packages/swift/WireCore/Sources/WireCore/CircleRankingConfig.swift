import Foundation

public struct CircleRankingConfig: Equatable, Sendable {
  public let weights: CircleRankingWeights
  public var participantBreadthTarget: Int
  public var recencyHalfLife: TimeInterval
  public var maximumSignalAge: TimeInterval

  public init(
    participantBreadthTarget: Int = 8,
    recencyHalfLife: TimeInterval = 12 * 60 * 60,
    maximumSignalAge: TimeInterval = 7 * 24 * 60 * 60
  ) {
    self.weights = .standard
    self.participantBreadthTarget = participantBreadthTarget
    self.recencyHalfLife = recencyHalfLife
    self.maximumSignalAge = maximumSignalAge
  }

  public func validate() throws {
    guard participantBreadthTarget > 0 else {
      throw CircleRankingConfigError.invalidParticipantBreadthTarget
    }
    guard recencyHalfLife.isFinite, recencyHalfLife > 0 else {
      throw CircleRankingConfigError.invalidRecencyHalfLife
    }
    guard maximumSignalAge.isFinite, maximumSignalAge > 0 else {
      throw CircleRankingConfigError.invalidMaximumSignalAge
    }
  }
}
