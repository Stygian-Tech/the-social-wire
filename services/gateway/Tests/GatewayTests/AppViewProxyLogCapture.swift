import Foundation
import Logging

final class AppViewProxyLogCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [Logger.Metadata] = []
  private var requests = 0

  var records: [Logger.Metadata] { lock.withLock { entries } }
  var requestCount: Int { lock.withLock { requests } }
  func recordRequest() { lock.withLock { requests += 1 } }
  func logger() -> Logger {
    Logger(label: "appview-proxy.test") { _ in Handler(capture: self) }
  }

  private struct Handler: LogHandler {
    let capture: AppViewProxyLogCapture
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
