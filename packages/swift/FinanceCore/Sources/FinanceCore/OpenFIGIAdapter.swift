import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OpenFIGIAdapter: Sendable {
  private let transport: any FinanceHTTPTransport
  private let apiKey: String?
  public init(transport: any FinanceHTTPTransport = FinanceRetryingTransport(), apiKey: String? = nil) {
    self.transport = transport; self.apiKey = apiKey
  }
  public func search(query: String) async throws -> [FinanceInstrument] {
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.count <= 200 else { throw FinanceProviderError.invalidRequest }
    return try await request(path: "search", body: ["query": query])
  }
  public func map(idType: String, idValue: String, exchange: String? = nil) async throws -> [FinanceInstrument] {
    guard !idType.isEmpty, !idValue.isEmpty, idValue.count <= 200 else { throw FinanceProviderError.invalidRequest }
    var body = ["idType": idType, "idValue": idValue]
    if let exchange { body["exchCode"] = exchange }
    return try await request(path: "mapping", body: [body])
  }
  public func mapFIGIs(_ ids: [String]) async throws -> [FinanceInstrument] {
    guard !ids.isEmpty, ids.count <= (apiKey == nil ? 5 : 10), ids.allSatisfy({ !$0.isEmpty && $0.count <= 200 })
    else { throw FinanceProviderError.invalidRequest }
    return try await request(path: "mapping", body: ids.map { ["idType": "ID_BB_GLOBAL", "idValue": $0] })
  }
  private func request(path: String, body: Any) async throws -> [FinanceInstrument] {
    var request = URLRequest(url: URL(string: "https://api.openfigi.com/v3/" + path)!)
    request.httpMethod = "POST"; request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "X-OPENFIGI-APIKEY") }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, status) = try await transport.data(for: request)
    guard status == 200 else { throw FinanceProviderError.httpStatus(status) }
    guard data.count <= 5_000_000 else { throw FinanceProviderError.responseTooLarge }
    let object = try JSONSerialization.jsonObject(with: data)
    let envelopes = (object as? [[String: Any]]) ?? (object as? [String: Any]).map { [$0] } ?? []
    guard !envelopes.isEmpty, !envelopes.contains(where: { $0["error"] != nil }) else { throw FinanceProviderError.invalidResponse }
    return envelopes.flatMap { $0["data"] as? [[String: Any]] ?? [] }.compactMap { row in
      guard let figi = row["figi"] as? String, let name = row["name"] as? String, let ticker = row["ticker"] as? String else { return nil }
      return FinanceInstrument(id: FinanceIdentity.instrumentID(provider: "openfigi", nativeID: figi),
        name: name, symbol: ticker, kind: row["securityType2"] as? String ?? "security", providerID: figi,
        exchange: row["exchCode"] as? String, currency: row["currency"] as? String, mic: row["micCode"] as? String,
        shareClassFIGI: row["shareClassFIGI"] as? String, compositeFIGI: row["compositeFIGI"] as? String)
    }
  }
}
