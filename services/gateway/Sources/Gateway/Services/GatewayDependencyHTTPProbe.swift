import AsyncHTTPClient
import Foundation

/// Bound both response headers and body consumption. The task group drains cancellation before
/// returning, so a timed-out sample cannot leave a detached HTTP request behind.
enum GatewayDependencyHTTPProbe {
  static func status(
    baseURL: String, httpClient: HTTPClient, timeout: Duration = .seconds(3)
  ) async throws -> UInt {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    return try await withThrowingTaskGroup(of: UInt.self) { group in
      defer { group.cancelAll() }
      group.addTask {
        var request = HTTPClientRequest(url: "\(baseURL)/readyz")
        request.method = .GET
        let response = try await httpClient.execute(request, timeout: .seconds(5))
        _ = try await response.body.collect(upTo: 4 * 1024)
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw ProbeError.timedOut }
        return response.status.code
      }
      group.addTask {
        try await Task.sleep(until: deadline, clock: .continuous)
        throw ProbeError.timedOut
      }
      guard let status = try await group.next() else { throw CancellationError() }
      try Task.checkCancellation()
      return status
    }
  }

  enum ProbeError: Error { case timedOut }
}
