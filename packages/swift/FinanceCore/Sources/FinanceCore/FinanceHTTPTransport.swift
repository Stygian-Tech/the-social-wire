import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol FinanceHTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, Int)
}
