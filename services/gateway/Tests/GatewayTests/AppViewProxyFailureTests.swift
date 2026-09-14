import AsyncHTTPClient
import Foundation
import GatewayCore
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

@testable import Gateway

@Suite("AppView proxy failure boundaries")
struct AppViewProxyFailureTests {
  @Test("typed transport failures map to safe gateway errors and preserve cancellation")
  func classification() throws {
    let timeouts: [HTTPClientError] = [
      .deadlineExceeded, .readTimeout, .writeTimeout, .connectTimeout,
      .getConnectionFromPoolTimeout, .tlsHandshakeTimeout, .httpProxyHandshakeTimeout,
      .socksHandshakeTimeout,
    ]
    for error in timeouts {
      let failure = AppViewProxyFailure(error)
      #expect(failure == .timeout)
      #expect(try #require(failure.responseError as? HTTPError).status == .gatewayTimeout)
    }
    for error: any Error in [CancellationError(), HTTPClientError.cancelled, HTTPClientError.requestStreamCancelled] {
      let failure = AppViewProxyFailure(error)
      #expect(failure == .cancelled)
      #expect(failure.responseError is CancellationError)
    }
    let failure = AppViewProxyFailure(NSError(
      domain: "https://private-host/?credential=secret", code: 1))
    #expect(failure == .unavailable)
    let response = try #require(failure.responseError as? HTTPError)
    #expect(response.status == .badGateway)
    #expect(response.body == "AppView is temporarily unavailable.")
  }

  @Test("XRPC translates transport failures without swallowing cancellation")
  func xrpcFailureEnvelopes() async throws {
    let router = Router(context: GatewayRequestContext.self)
    let errors = router.group().add(middleware: XRPCErrorMiddleware())
    errors.get("/xrpc/test.timeout") { _, _ -> Response in
      throw AppViewProxyFailure(HTTPClientError.deadlineExceeded).responseError
    }
    errors.get("/xrpc/test.unavailable") { _, _ -> Response in
      throw AppViewProxyFailure(NSError(domain: "private-fixture", code: 1)).responseError
    }
    router.get("/xrpc/test.cancelled") { request, context -> Response in
      do {
        _ = try await XRPCErrorMiddleware().handle(request, context: context) { _, _ in
          throw AppViewProxyFailure(HTTPClientError.cancelled).responseError
        }
        Issue.record("The middleware converted cancellation into an HTTP response")
      } catch is CancellationError {
        return Response(status: .noContent)
      }
      return Response(status: .internalServerError)
    }
    try await Application(router: router).test(.router) { client in
      let timeout = try await client.execute(uri: "/xrpc/test.timeout", method: .get)
      #expect(timeout.status == .gatewayTimeout)
      #expect(String(buffer: timeout.body).contains("\"error\":\"UpstreamTimeout\""))
      let unavailable = try await client.execute(uri: "/xrpc/test.unavailable", method: .get)
      #expect(unavailable.status == .badGateway)
      #expect(String(buffer: unavailable.body).contains("\"error\":\"UpstreamUnavailable\""))
      #expect(!String(buffer: unavailable.body).contains("private-fixture"))
      let cancelled = try await client.execute(uri: "/xrpc/test.cancelled", method: .get)
      #expect(cancelled.status == .noContent)
    }
  }

  @Test("the feed deadline covers both response headers and body without retry", arguments: [false, true])
  func completeResponseDeadline(stallBody: Bool) async throws {
    let capture = AppViewProxyLogCapture()
    let upstream = Router()
    upstream.get("/xrpc/app.thesocialwire.appview.getFeed") { _, _ -> Response in
      capture.recordRequest()
      if !stallBody { try await Task.sleep(for: .seconds(6)) }
      return Response(status: .ok, body: ResponseBody { writer in
        if stallBody {
          try await writer.write(ByteBuffer(string: "{\"items\":"))
          try await Task.sleep(for: .seconds(6))
        }
        try await writer.write(ByteBuffer(string: "[]}"))
        try await writer.finish(nil)
      })
    }
    try await withProxy(upstream: upstream, capture: capture) { downstream in
      let start = ContinuousClock.now
      let response = try await downstream.execute(uri: "/v1/appview/feed", method: .get)
      #expect(response.status == .gatewayTimeout)
      #expect(start.duration(to: .now) < .milliseconds(4_500))
      #expect(capture.requestCount == 1)
      let record = try #require(capture.records.last)
      #expect(record["outcome"]?.description == "timeout")
      #expect((record["headers_ms"] != nil) == stallBody)
    }
  }

  @Test("slow responses and upstream 503 pass through once with distinct timing", arguments: [false, true])
  func passthroughAndTiming(upstreamFailure: Bool) async throws {
    let capture = AppViewProxyLogCapture()
    let upstream = Router()
    upstream.get("/xrpc/app.thesocialwire.appview.getFeed") { _, _ -> Response in
      capture.recordRequest()
      try await Task.sleep(for: .milliseconds(75))
      return Response(status: upstreamFailure ? .serviceUnavailable : .ok, body: ResponseBody { writer in
        try await writer.write(ByteBuffer(string: "{\"error\":"))
        try await Task.sleep(for: .milliseconds(650))
        try await writer.write(ByteBuffer(string: "\"FixtureUnavailable\"}"))
        try await writer.finish(nil)
      })
    }
    try await withProxy(upstream: upstream, capture: capture) { downstream in
      let response = try await downstream.execute(uri: "/v1/appview/feed", method: .get)
      #expect(response.status == (upstreamFailure ? .serviceUnavailable : .ok))
      #expect(String(buffer: response.body) == "{\"error\":\"FixtureUnavailable\"}")
      #expect(capture.requestCount == 1)
      #expect(capture.records.count == 1)
      let record = try #require(capture.records.first)
      #expect(record["status"]?.description == (upstreamFailure ? "503" : "200"))
      #expect(record["outcome"]?.description == "response")
      let headers = try #require(Int(record["headers_ms"]?.description ?? ""))
      let firstByte = try #require(Int(record["first_byte_ms"]?.description ?? ""))
      let total = try #require(Int(record["total_ms"]?.description ?? ""))
      #expect(headers >= 50)
      #expect(firstByte >= headers)
      #expect(total - firstByte >= 100)
      #expect(record["response_bytes"]?.description == String(response.body.readableBytes))
    }
  }

  @Test("fast successful requests do not add per-request diagnostic logs")
  func fastSuccessDoesNotLog() {
    let capture = AppViewProxyLogCapture()
    let trace = AppViewProxyRequestTrace(
      path: "/xrpc/app.thesocialwire.appview.getFeed", requestID: "fixture", logger: capture.logger())
    trace.receivedHeaders(status: 200)
    trace.receivedBytes(32)
    trace.finish()
    #expect(capture.records.isEmpty)
  }

  @Test("buffered responses preserve the eight MiB limit")
  func oversizedResponse() async throws {
    let capture = AppViewProxyLogCapture()
    let upstream = Router()
    upstream.get("/xrpc/app.thesocialwire.appview.getFeed") { _, _ -> Response in
      capture.recordRequest()
      return Response(status: .ok, body: ResponseBody { writer in
        let chunk = ByteBuffer(repeating: 65, count: 1024 * 1024)
        for _ in 0..<8 { try await writer.write(chunk) }
        try await writer.write(ByteBuffer(string: "x"))
        try await writer.finish(nil)
      })
    }
    try await withProxy(upstream: upstream, capture: capture) { downstream in
      let response = try await downstream.execute(uri: "/v1/appview/feed", method: .get)
      #expect(response.status == .badGateway)
      #expect(response.body.readableBytes < 1024)
      #expect(capture.requestCount == 1)
      #expect(capture.records.last?["outcome"]?.description == "unavailable")
    }
  }

  @Test("successful request diagnostics stay quiet unless slow and finish only once")
  func boundedSuccessDiagnostics() async throws {
    let capture = AppViewProxyLogCapture()
    let fast = AppViewProxyRequestTrace(
      path: "/v1/appview/feed", requestID: "fast-fixture", logger: capture.logger())
    fast.receivedHeaders(status: 200)
    fast.receivedBytes(2)
    fast.finish()
    #expect(capture.records.isEmpty)

    let slow = AppViewProxyRequestTrace(
      path: "/v1/appview/feed", requestID: "slow-fixture", logger: capture.logger())
    try await Task.sleep(for: .milliseconds(550))
    slow.receivedHeaders(status: 200)
    slow.receivedBytes(2)
    slow.finish()
    slow.finish(failure: .timeout)
    #expect(capture.records.count == 1)
    let record = try #require(capture.records.first)
    #expect(record["request_id"]?.description == "slow-fixture")
    #expect(record["outcome"]?.description == "response")
    #expect(try #require(Int(record["headers_ms"]?.description ?? "")) >= 500)
  }

  private func withProxy(
    upstream: Router<BasicRequestContext>, capture: AppViewProxyLogCapture,
    body: @escaping @Sendable (any TestClientProtocol) async throws -> Void
  ) async throws {
    let client = HTTPClient(eventLoopGroupProvider: .singleton)
    do {
      try await Application(router: upstream).test(.live) { upstreamClient in
        let port = try #require(upstreamClient.port)
        let router = Router(context: GatewayRequestContext.self)
        router.add(middleware: ViewerMiddleware())
        AppViewProxyRoutes(
          baseURL: "http://localhost:\(port)", internalSecret: nil,
          httpClient: client, logger: capture.logger()
        ).register(on: router.group())
        try await Application(router: router).test(.live) { downstream in
          try await body(downstream)
        }
      }
    } catch {
      try await client.shutdown()
      throw error
    }
    try await client.shutdown()
  }

  private struct ViewerMiddleware: RouterMiddleware {
    func handle(
      _ request: Request, context: GatewayRequestContext,
      next: (Request, GatewayRequestContext) async throws -> Response
    ) async throws -> Response {
      var context = context
      context.authContext = AuthContext(
        did: "did:plc:viewer", authorizationForwardingValue: "DPoP test", dpopProof: "test-proof")
      return try await next(request, context)
    }
  }
}
