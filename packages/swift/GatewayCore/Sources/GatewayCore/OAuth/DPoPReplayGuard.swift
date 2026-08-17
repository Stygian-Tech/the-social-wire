import Foundation

actor DPoPReplayGuard {
  enum ReplayError: Error {
    case replayed
    case capacityExceeded
  }

  private let retention: TimeInterval
  private let maximumEntries: Int
  private var expirations: [String: Date] = [:]

  init(retention: TimeInterval = 120, maximumEntries: Int = 20_000) {
    self.retention = retention
    self.maximumEntries = maximumEntries
  }

  func consume(
    thumbprint: String,
    jti: String,
    validUntil: Date? = nil,
    now: Date = Date()
  ) throws {
    expirations = expirations.filter { $0.value >= now }
    let key = "\(thumbprint):\(jti)"
    guard expirations[key] == nil else { throw ReplayError.replayed }
    guard expirations.count < maximumEntries else { throw ReplayError.capacityExceeded }

    let retentionExpiration = now.addingTimeInterval(retention)
    expirations[key] = max(retentionExpiration, validUntil ?? retentionExpiration)
  }
}
