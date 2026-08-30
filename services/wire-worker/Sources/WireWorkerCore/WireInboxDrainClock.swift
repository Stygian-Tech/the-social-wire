import Foundation

protocol WireInboxDrainClock: Sendable {
  func now() async -> Date
}

struct SystemWireInboxDrainClock: WireInboxDrainClock {
  func now() -> Date { Date() }
}
