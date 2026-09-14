import Foundation
import Logging

/// Starts before the HTTP request, including connection and response-header waits.
final class AppViewProxyRequestTrace: @unchecked Sendable {
  private let lock = NSLock()
  private let started = ContinuousClock.now
  private let path: String
  private let requestID: String
  private let logger: Logger
  private var headersMilliseconds: Int?
  private var firstByteMilliseconds: Int?
  private var status: Int?
  private var bytes = 0
  private var finished = false

  init(path: String, requestID: String, logger: Logger) {
    self.path = path
    self.requestID = requestID
    self.logger = logger
  }

  func receivedHeaders(status: Int) {
    lock.withLock {
      headersMilliseconds = elapsedMilliseconds
      self.status = status
    }
  }

  func receivedBytes(_ count: Int) {
    lock.withLock {
      bytes += count
      if count > 0 && firstByteMilliseconds == nil {
        firstByteMilliseconds = elapsedMilliseconds
      }
    }
  }

  func finish(failure: AppViewProxyFailure? = nil) {
    let observation: (metadata: Logger.Metadata, failed: Bool)? = lock.withLock {
      guard !finished else { return nil }
      finished = true
      let milliseconds = elapsedMilliseconds
      let failed = failure != nil || (status ?? 0) >= 500
      guard failed || milliseconds >= 500 else { return nil }
      var metadata: Logger.Metadata = [
        "path": .string(path),
        "request_id": .string(requestID),
        "total_ms": .stringConvertible(milliseconds),
        "response_bytes": .stringConvertible(bytes),
        "outcome": .string(failure?.rawValue ?? "response"),
      ]
      if let headersMilliseconds {
        metadata["headers_ms"] = .stringConvertible(headersMilliseconds)
      }
      if let firstByteMilliseconds {
        metadata["first_byte_ms"] = .stringConvertible(firstByteMilliseconds)
      }
      if let status { metadata["status"] = .stringConvertible(status) }
      return (metadata, failed)
    }
    guard let observation else { return }
    if observation.failed {
      logger.warning("AppView upstream request failed", metadata: observation.metadata)
    } else {
      logger.info("AppView upstream request completed slowly", metadata: observation.metadata)
    }
  }

  private var elapsedMilliseconds: Int {
    let duration = started.duration(to: .now).components
    return Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
  }
}
