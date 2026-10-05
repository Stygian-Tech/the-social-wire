import AsyncHTTPClient
import Foundation
import GatewayCore
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing
@testable import Gateway
@Suite("Sports Gateway contracts")
struct SportsProxyContractTests {
  @Test func distributedQuerySurface() {
    for nsid in ["getSports", "getSportsCatalog", "searchSportsEntities", "getSportsEvents"] {
      #expect(WireProxyRoutes.paths.contains("/xrpc/app.thesocialwire.discovery." + nsid))
    }
  }

  @Test("Sports search proxy preserves spaces and literal plus signs", arguments: [
    ("q=Red+Bull", "Red Bull"),
    ("q=Red%20Bull", "Red Bull"),
    ("q=A%2BB", "A+B"),
    ("q=A%252BB", "A%2BB"),
  ])
  func searchQueryEncoding(query: String, expected: String) async throws {
    let path = "/xrpc/app.thesocialwire.discovery.searchSportsEntities"
    let secret = String(repeating: "s", count: 32)
    let upstream = Router()
    upstream.get(RouterPath(path)) { request, _ -> Response in
      #expect(request.uri.query == query)
      let rawValue = try #require(request.uri.query?.split(separator: "=", maxSplits: 1).last)
      #expect(String(rawValue).replacingOccurrences(of: "+", with: " ").removingPercentEncoding == expected)
      let timestamp = try #require(request.headers[HTTPField.Name(GatewayInternalTrust.timestampHeaderName)!])
      let signature = try #require(request.headers[HTTPField.Name(GatewayInternalTrust.signatureHeaderName)!])
      try GatewayInternalTrust.verify(secret: secret, did: GatewayInternalTrustAuthMiddleware.anonymousDiscoveryDID,
        method: "GET", pathWithQuery: GatewayInternalTrust.canonicalSignedPath(path), timestamp: timestamp, signature: signature)
      return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "{}")))
    }
    let http = HTTPClient(eventLoopGroupProvider: .singleton)
    do {
      try await Application(router: upstream).test(.live) { upstreamClient in
        let port = try #require(upstreamClient.port)
        let router = Router(context: GatewayRequestContext.self)
        WireProxyRoutes(baseURL: "http://localhost:\(port)", internalSecret: secret,
          httpClient: http, limiter: WireRequestLimiter(), logger: Logger(label: "sports-query-proxy.test"))
          .register(on: router.group())
        try await Application(router: router).test(.live) { downstream in
          let response = try await downstream.execute(uri: "\(path)?\(query)", method: .get)
          #expect(response.status == .ok)
        }
      }
    } catch {
      try? await http.shutdown()
      throw error
    }
    try await http.shutdown()
  }
}
