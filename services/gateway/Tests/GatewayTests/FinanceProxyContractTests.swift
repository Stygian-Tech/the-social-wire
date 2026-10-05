import AsyncHTTPClient
import GatewayCore
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import Testing
@testable import Gateway

@Suite("Finance Gateway contracts")
struct FinanceProxyContractTests {
  @Test("Finance queries use the existing distributed discovery proxy surface")
  func querySurface() {
    for nsid in ["getFinance", "getFinanceCatalog", "searchFinanceInstruments", "getFinanceSectors"] {
      #expect(WireProxyRoutes.paths.contains("/xrpc/app.thesocialwire.discovery." + nsid))
    }
    #expect(!WireProxyRoutes.paths.contains("/xrpc/app.thesocialwire.discovery.recordFinanceComposition"))
  }

  @Test("composition telemetry refuses anonymous posts before reaching AppView")
  func telemetryRequiresViewer() async throws {
    let http = HTTPClient(eventLoopGroupProvider: .singleton)
    do {
      let router = Router(context: GatewayRequestContext.self)
      WireProxyRoutes(baseURL: "http://127.0.0.1:1", internalSecret: String(repeating: "f", count: 32),
        httpClient: http, limiter: WireRequestLimiter(), logger: Logger(label: "finance-proxy.test"))
        .register(on: router.group())
      let app = Application(router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)))
      try await app.test(.router) { client in
        let response = try await client.execute(uri: "/xrpc/app.thesocialwire.discovery.recordFinanceComposition", method: .post,
          headers: [.contentType: "application/json"], body: .init(string: #"{"event":"impression","suggestionCount":3}"#))
        #expect(response.status == .unauthorized)
      }
    } catch {
      try? await http.shutdown()
      throw error
    }
    try await http.shutdown()
  }
}
