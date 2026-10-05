import Foundation

public struct PodcastListenerState: Codable, Sendable, Equatable {
  public var subscriptions: [String] = []
  public var queue: [String] = []
  public var progress: [String: PodcastProgress] = [:]
  public var playbackSpeed: Double = 1
  public var removeSilences: Bool = false
  public var manualLinks: [PodcastManualLink] = []
  public init() {}
  public func validate() -> Bool {
    playbackSpeed.isFinite && (0.75...2).contains(playbackSpeed) && playbackSpeed * 4 == (playbackSpeed * 4).rounded() && queue.count <= 1000
      && subscriptions.count <= 10000 && manualLinks.count <= 1000 && progress.count <= 10000
      && progress.values.allSatisfy {
        $0.positionSeconds.isFinite && $0.positionSeconds >= 0 && Self.validDate($0.updatedAt)
      }
  }
  public mutating func normalizePlaybackSpeed() {
    playbackSpeed = playbackSpeed.isFinite ? (min(2, max(0.75, playbackSpeed)) * 4).rounded() / 4 : 1
  }
  private static func validDate(_ raw: String) -> Bool {
    let f = ISO8601DateFormatter()
    if f.date(from: raw) != nil { return true }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: raw) != nil
  }
}
