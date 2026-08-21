protocol WireInboxDrainSleeping: Sendable {
  func sleep(milliseconds: Int) async throws
}

struct SystemWireInboxDrainSleeper: WireInboxDrainSleeping {
  func sleep(milliseconds: Int) async throws {
    try await Task.sleep(for: .milliseconds(milliseconds))
  }
}
