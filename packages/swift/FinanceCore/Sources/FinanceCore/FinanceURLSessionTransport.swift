import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct FinanceURLSessionTransport: FinanceHTTPTransport {
  public init() {}
  public func data(for request: URLRequest) async throws -> (Data, Int) {
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }
}
