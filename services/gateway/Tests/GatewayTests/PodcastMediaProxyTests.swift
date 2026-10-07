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

struct PodcastMediaProxyTests {
  @Test(arguments: ["/v1/podcasts/image", "/v1/podcasts/media", "/v1/podcasts/assets"])
  func authenticatedMediaPassesAppViewTrustMiddleware(path: String) async throws {
    let secret = String(repeating: "s", count: 32)
    let upstream = Router(context: GatewayRequestContext.self)
    upstream.add(middleware: GatewayInternalTrustAuthMiddleware(sharedSecret: secret, logger: Logger(label: "podcast-media-trust-test")))
    upstream.get(RouterPath(path)) { request, context -> Response in
      let auth = try #require(context.authContext)
      #expect(auth.did == "did:plc:viewer")
      #expect(auth.authorizationForwardingValue == "DPoP viewer-token")
      #expect(auth.dpopProof == "viewer-proof")
      #expect(auth.upstreamDpopProof == "upstream-proof")
      #expect(request.headers[.range] == "bytes=0-9")
      #expect(request.uri.query == "episodeId=private&index=0&kind=chapter")
      return Response(status: .partialContent, headers: [.contentType: "image/jpeg", .contentRange: "bytes 0-9/100"], body: .init(byteBuffer: ByteBuffer(string: "image")))
    }
    try await withProxy(upstream: upstream, secret: secret) { downstream in
      let response = try await downstream.execute(uri: path + "?episodeId=private&kind=chapter&index=0", method: .get, headers: [.range: "bytes=0-9"])
      #expect(response.status == .partialContent)
      #expect(response.headers[.contentType] == "image/jpeg")
      #expect(response.headers[.contentRange] == "bytes 0-9/100")
      #expect(response.headers[.cacheControl] == "private, no-store")
      #expect(String(buffer: response.body) == "image")
    }
  }

  @Test(arguments: ["/v1/podcasts/public/assets", "/v1/podcasts/public/clips"])
  func publicMediaDoesNotForwardViewerCredentials(path: String) async throws {
    let upstream = Router(context: GatewayRequestContext.self)
    upstream.get(RouterPath(path)) { request, _ -> Response in
      #expect(request.headers[.authorization] == nil)
      #expect(request.headers[HTTPField.Name("DPoP")!] == nil)
      #expect(request.headers[HTTPField.Name(ATProtoUpstreamDPoP.headerName)!] == nil)
      #expect(request.headers[HTTPField.Name(GatewayInternalTrust.signatureHeaderName)!] == nil)
      return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(string: "public")))
    }
    try await withProxy(upstream: upstream, secret: String(repeating: "s", count: 32)) { downstream in
      let response = try await downstream.execute(uri: path, method: .get, headers: [.authorization: "DPoP caller-token", HTTPField.Name("DPoP")!: "caller-proof"])
      #expect(response.status == .ok)
      #expect(String(buffer: response.body) == "public")
    }
  }

  private func withProxy(
    upstream: Router<GatewayRequestContext>, secret: String,
    test: @Sendable (any TestClientProtocol) async throws -> Void
  ) async throws {
    let http = HTTPClient(eventLoopGroupProvider: .singleton)
    do {
      try await Application(router: upstream).test(.live) { upstreamClient in
        let port = try #require(upstreamClient.port)
        let router = Router(context: GatewayRequestContext.self)
        let protected = router.group().add(middleware: Viewer())
        PodcastMediaProxyRoutes(baseURL: "http://localhost:\(port)", internalSecret: secret, httpClient: http).register(on: protected, router: router)
        try await Application(router: router).test(.live) { downstream in try await test(downstream) }
      }
    } catch { try? await http.shutdown(); throw error }
    try await http.shutdown()
  }

  private struct Viewer: RouterMiddleware {
    func handle(_ request: Request, context: GatewayRequestContext, next: (Request, GatewayRequestContext) async throws -> Response) async throws -> Response {
      var context = context
      context.authContext = AuthContext(did: "did:plc:viewer", authorizationForwardingValue: "DPoP viewer-token", dpopProof: "viewer-proof", upstreamDpopProof: " upstream-proof ")
      return try await next(request, context)
    }
  }
}
