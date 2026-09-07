enum WireInboxEventOutcome: Equatable, Sendable {
  case applied
  case deferred
  case terminal
  case retry
  case leaseLost

  var permitsContinuation: Bool { self == .applied || self == .deferred || self == .terminal }
}
