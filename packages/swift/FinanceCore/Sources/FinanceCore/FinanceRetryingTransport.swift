import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct FinanceRetryingTransport: FinanceHTTPTransport {
  private let base: any FinanceHTTPTransport
  public init(base: any FinanceHTTPTransport = FinanceURLSessionTransport()) { self.base = base }
  public func data(for request: URLRequest) async throws -> (Data, Int) {
    for attempt in 0..<3 {
      do {
        let result = try await base.data(for: request)
        if attempt == 2 || result.1 < 500 { return result }
      } catch {
        if attempt == 2 || error is CancellationError { throw error }
      }
      try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
    }
    throw FinanceProviderError.invalidResponse
  }
}
