enum WireWorkerRole: String, CaseIterable, Sendable {
  case combined
  case rank
  case drain

  var runsGeneration: Bool { self != .drain }
  var runsDrain: Bool { self != .rank }
}
