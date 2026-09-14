import AsyncHTTPClient
import Foundation
import GatewayCore
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Testing

@testable import Gateway

@Suite("Read age streaming proxy")
struct ReadAgeStreamingProxyTests {
  @Test("forwards the first options event before the upstream scan completes and preserves JSON")
  func progressiveBodyAndJSONCompatibility() async throws {
    let path = "/xrpc/app.thesocialwire.appview.getReadAgeOptions"
    let firstLine = "{\"type\":\"options\",\"referenceDay\":\"2026-09-02T00:00:00Z\",\"options\":[]}\n"
    let doneLine = "{\"type\":\"done\"}\n"
    let receivedFirst = AsyncStream<Void>.makeStream()
    defer { receivedFirst.continuation.finish() }
    let upstream = Router()
    upstream.get(RouterPath(path)) { request, _ -> Response in
      #expect(request.uri.queryParameters.get("timeZone") == "America/Chicago")
      guard request.headers[.accept] == "application/x-ndjson",
            request.uri.queryParameters.get("legacy") != "true" else {
        return Response(
          status: .ok, headers: [.contentType: "application/json"],
          body: .init(byteBuffer: ByteBuffer(string: "{\"referenceDay\":\"2026-09-02T00:00:00Z\",\"options\":[]}"))
        )
      }
      return Response(
        status: .ok, headers: [.contentType: "application/x-ndjson"],
        body: ResponseBody { writer in
          try await writer.write(ByteBuffer(string: firstLine))
          // This cannot finish until the downstream client observes the first event.
          for await _ in receivedFirst.stream { break }
          try await writer.write(ByteBuffer(string: doneLine))
          try await writer.finish(nil)
        }
      )
    }
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    do {
      try await Application(router: upstream).test(.live) { upstreamClient in
        let upstreamPort = try #require(upstreamClient.port)
        let router = Router(context: GatewayRequestContext.self)
        router.add(middleware: ReadAgeTestViewerMiddleware())
        AppViewProxyRoutes(
          baseURL: "http://localhost:\(upstreamPort)", internalSecret: nil,
          httpClient: client, logger: Logger(label: "read-age-proxy.test")
        ).register(on: router.group())
        try await Application(router: router).test(.live) { downstream in
          defer { receivedFirst.continuation.finish() }
          let port = try #require(downstream.port)
          var request = HTTPClientRequest(
            url: "http://localhost:\(port)\(path)?kind=subscribed&timeZone=America%2FChicago"
          )
          request.headers.add(name: "Accept", value: "application/x-ndjson")
          let response = try await client.execute(request, timeout: .seconds(5))
          #expect(response.status.code == 200)
          #expect(response.headers.first(name: "Content-Type") == "application/x-ndjson")
          var body = ""
          for try await chunk in response.body {
            body += String(buffer: chunk)
            if body.contains(firstLine) { receivedFirst.continuation.yield(()) }
          }
          #expect(body == firstLine + doneLine)
          let json = try await downstream.execute(
            uri: "\(path)?kind=subscribed&timeZone=America%2FChicago", method: .get
          )
          #expect(json.headers[.contentType] == "application/json")
          #expect(String(buffer: json.body).contains("\"options\":[]"))
          var legacyRequest = HTTPClientRequest(
            url: "http://localhost:\(port)\(path)?kind=subscribed&timeZone=America%2FChicago&legacy=true"
          )
          legacyRequest.headers.add(name: "Accept", value: "application/x-ndjson")
          let legacy = try await client.execute(legacyRequest, timeout: .seconds(5))
          #expect(legacy.headers.first(name: "Content-Type") == "application/json")
          let legacyBody = try await legacy.body.collect(upTo: 1024)
          #expect(String(buffer: legacyBody).contains("\"options\":[]"))
        }
      }
    } catch {
      receivedFirst.continuation.finish()
      try await client.shutdown()
      throw error
    }
    try await client.shutdown()
  }
}

private struct ReadAgeTestViewerMiddleware: RouterMiddleware {
  func handle(
    _ request: Request, context: GatewayRequestContext,
    next: (Request, GatewayRequestContext) async throws -> Response
  ) async throws -> Response {
    var context = context
    context.authContext = AuthContext(
      did: "did:plc:viewer", authorizationForwardingValue: "DPoP test", dpopProof: "test-proof"
    )
    return try await next(request, context)
  }
}
