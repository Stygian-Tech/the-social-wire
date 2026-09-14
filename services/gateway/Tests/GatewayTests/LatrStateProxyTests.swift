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

@Suite("L@tr state proxy")
struct LatrStateProxyTests {
  @Test("state transport preserves PATCH and legacy POST without rewriting proofs", arguments: ["PATCH", "POST"])
  func methodAndProofForwarding(method: String) async throws {
    let path = "/xrpc/link.latr.bookmarks.setState"
    let payload = "{\"bookmarkUri\":\"at://did:plc:viewer/community.lexicon.bookmarks.bookmark/one\",\"state\":\"archived\"}"
    let upstream = Router()
    upstream.on(RouterPath(path), method: method == "PATCH" ? .patch : .post) { request, _ -> Response in
      #expect(request.method.rawValue == method)
      #expect(request.headers[.authorization] == "DPoP viewer-token")
      #expect(request.headers[HTTPField.Name("DPoP")!] == "\(method)-latr-proof")
      #expect(request.headers[HTTPField.Name("X-ATProto-Upstream-DPoP")!] == "pds-proof")
      #expect(request.headers[HTTPField.Name("X-Latr-API-Key")!] == "test-key")
      let body = try await request.body.collect(upTo: 1024)
      #expect(String(buffer: body) == payload)
      return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "{}")))
    }
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    do {
      try await Application(router: upstream).test(.live) { upstreamClient in
        let port = try #require(upstreamClient.port)
        let router = Router(context: GatewayRequestContext.self)
        router.add(middleware: LatrStateTestViewerMiddleware())
        LatrProxyRoutes(
          config: .init(baseURL: "http://localhost:\(port)", clientId: "test-client", apiKey: "test-key", officialClientCredential: nil),
          httpClient: client, logger: Logger(label: "latr-state.test")
        ).register(on: router.group())
        try await Application(router: router).test(.live) { downstream in
          let downstreamPort = try #require(downstream.port)
          var request = HTTPClientRequest(url: "http://localhost:\(downstreamPort)\(path)")
          request.method = method == "PATCH" ? .PATCH : .POST
          request.headers.add(name: "X-Latr-Gateway-DPoP", value: "\(method)-latr-proof")
          request.headers.add(name: "Content-Type", value: "application/json")
          request.body = .bytes(ByteBuffer(string: payload))
          let response = try await client.execute(request, timeout: .seconds(5))
          #expect(response.status.code == 200)
          _ = try await response.body.collect(upTo: 1024)
        }
      }
    } catch {
      try await client.shutdown()
      throw error
    }
    try await client.shutdown()
  }
}

private struct LatrStateTestViewerMiddleware: RouterMiddleware {
  func handle(
    _ request: Request, context: GatewayRequestContext,
    next: (Request, GatewayRequestContext) async throws -> Response
  ) async throws -> Response {
    var context = context
    context.authContext = AuthContext(
      did: "did:plc:viewer", authorizationForwardingValue: "DPoP viewer-token",
      dpopProof: "gateway-proof", upstreamDpopProof: "pds-proof"
    )
    return try await next(request, context)
  }
}
