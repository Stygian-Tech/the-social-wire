import Foundation

/// Internal ranking evidence. Callers must pass qualifying, public Circle activity only.
public struct CircleParticipantSignal: Equatable, Sendable {
  public let participantKey: String
  public let relationship: CircleRelationship
  public let occurredAt: Date

  public init(
    participantKey: String,
    relationship: CircleRelationship,
    occurredAt: Date
  ) {
    self.participantKey = participantKey
    self.relationship = relationship
    self.occurredAt = occurredAt
  }
}
