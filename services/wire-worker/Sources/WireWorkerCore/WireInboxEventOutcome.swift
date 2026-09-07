enum WireInboxEventOutcome: Equatable, Sendable {
  case applied
  case terminal
  case retry
  case leaseLost

  var permitsContinuation: Bool { self == .applied || self == .terminal }
}
