import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CoinGeckoAdapter: Sendable {
  private let transport: any FinanceHTTPTransport
  public init(transport: any FinanceHTTPTransport = FinanceRetryingTransport()) { self.transport = transport }
  public func instruments() async throws -> [FinanceInstrument] {
    var request = URLRequest(url: URL(string: "https://api.coingecko.com/api/v3/coins/list")!)
    request.timeoutInterval = 30
    let (data, status) = try await transport.data(for: request)
    guard status == 200 else { throw FinanceProviderError.httpStatus(status) }
    guard data.count <= 10_000_000 else { throw FinanceProviderError.responseTooLarge }
    guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: String]] else { throw FinanceProviderError.invalidResponse }
    return rows.compactMap { row in
      guard let id = row["id"], let name = row["name"], let symbol = row["symbol"] else { return nil }
      return .init(id: FinanceIdentity.instrumentID(provider: "coingecko", nativeID: id),
        name: name, symbol: symbol.uppercased(), kind: "crypto", providerID: id)
    }
  }
}
