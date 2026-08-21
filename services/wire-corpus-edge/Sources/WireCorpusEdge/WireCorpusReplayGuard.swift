import Foundation
import WireCore

actor WireCorpusReplayGuard {
  private let capacity: Int
  private var accepted: [String: Date] = [:]

  init(capacity: Int = 10_000) {
    self.capacity = max(1, capacity)
  }

  func consume(nonce: String, now: Date) -> Bool {
    let cutoff = now.addingTimeInterval(-WireCorpusServiceTrust.maximumClockSkew)
    accepted = accepted.filter { $0.value >= cutoff }
    guard accepted[nonce] == nil, accepted.count < capacity else { return false }
    accepted[nonce] = now
    return true
  }
}
