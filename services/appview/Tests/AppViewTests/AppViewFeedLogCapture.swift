import Foundation
import Logging

final class AppViewFeedLogCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [Logger.Metadata] = []

  var records: [Logger.Metadata] { lock.withLock { entries } }
  func logger() -> Logger {
    Logger(label: "appview-feed.test") { _ in Handler(capture: self) }
  }

  private struct Handler: LogHandler {
    let capture: AppViewFeedLogCapture
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
      get { metadata[key] }
      set { metadata[key] = newValue }
    }
    func log(event: LogEvent) {
      capture.lock.withLock {
        capture.entries.append(metadata.merging(event.metadata ?? [:]) { _, new in new })
      }
    }
  }
}
