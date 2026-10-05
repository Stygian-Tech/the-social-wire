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

struct PodcastSearchProxyTests {
  @Test func forwardsPrivateQueryInBodyWithViewerTrustAndNoStore() async throws {
    let path = "/v1/podcasts/search"
    let secret = String(repeating: "s", count: 32)
    let payload = #"{"query":"Private Café + Science","scope":"library","limit":20}"#
    let upstream = Router()
    upstream.post(RouterPath(path)) { request, context -> Response in
      #expect(request.uri.query == nil)
      let body = try await request.body.collect(upTo: 4096)
      #expect(String(buffer: body) == payload)
      let timestamp = try #require(request.headers[HTTPField.Name(GatewayInternalTrust.timestampHeaderName)!])
      let signature = try #require(request.headers[HTTPField.Name(GatewayInternalTrust.signatureHeaderName)!])
      try GatewayInternalTrust.verify(secret: secret, did: "did:plc:viewer", method: "POST", pathWithQuery: path, timestamp: timestamp, signature: signature)
      return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: #"{"shows":[],"episodes":[],"hasMore":false}"#)))
    }
    let http = HTTPClient(eventLoopGroupProvider: .singleton)
    do {
      try await Application(router: upstream).test(.live) { upstreamClient in
        let port = try #require(upstreamClient.port)
        let router = Router(context: GatewayRequestContext.self)
        router.add(middleware: Viewer())
        AppViewProxyRoutes(baseURL: "http://localhost:\(port)", internalSecret: secret, httpClient: http, logger: Logger(label: "podcast-search-proxy-test")).register(on: router.group())
        try await Application(router: router).test(.live) { downstream in
          let response = try await downstream.execute(uri: path, method: .post, headers: [.contentType: "application/json"], body: ByteBuffer(string: payload))
          #expect(response.status == .ok)
          #expect(response.headers[.cacheControl] == "private, no-store")
          #expect(String(buffer: response.body).contains("\"hasMore\":false"))
        }
      }
    } catch {
      try? await http.shutdown()
      throw error
    }
    try await http.shutdown()
  }

  private struct Viewer: RouterMiddleware {
    func handle(_ request: Request, context: GatewayRequestContext, next: (Request, GatewayRequestContext) async throws -> Response) async throws -> Response {
      var context = context
      context.authContext = AuthContext(did: "did:plc:viewer", authorizationForwardingValue: "DPoP test", dpopProof: "test-proof")
      return try await next(request, context)
    }
  }
}
