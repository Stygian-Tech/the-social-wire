import Foundation

struct WireInboxBacklogHealth: Equatable, Sendable {
  let actionableEventCount: Int64
  let oldestActionableAgeSeconds: TimeInterval?

  init(actionableEventCount: Int64, oldestActionableAgeSeconds: TimeInterval?) {
    self.actionableEventCount = max(0, actionableEventCount)
    self.oldestActionableAgeSeconds = oldestActionableAgeSeconds.map { max(0, $0) }
  }
}
