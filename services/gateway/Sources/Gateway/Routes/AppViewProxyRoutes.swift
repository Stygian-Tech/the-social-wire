import AsyncHTTPClient
import Foundation
import GatewayCore
import HTTPTypes
import Hummingbird
import Logging
import NIOCore

extension HTTPResponse.Status {
  fileprivate static func from(code: Int) -> HTTPResponse.Status? {
    switch code {
    case 200: .ok
    case 201: .created
    case 204: .noContent
    case 304: .notModified
    case 400: .badRequest
    case 401: .unauthorized
    case 403: .forbidden
    case 404: .notFound
    case 500: .internalServerError
    case 502: .badGateway
    case 503: .serviceUnavailable
    case 504: .gatewayTimeout
    default: nil
    }
  }
}

/// Forwards AppView read routes to the AppView service during distributed deployment.
struct AppViewProxyRoutes {
  let baseURL: String
  let internalSecret: String?
  let httpClient: HTTPClient
  let logger: Logger

  func register(on group: RouterGroup<GatewayRequestContext>) {
    group.get("/v1/publications/sidebar") { request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/v1/publications/sidebar", method: "GET")
    }
    group.get("/xrpc/app.thesocialwire.publication.getSidebar") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/xrpc/app.thesocialwire.publication.getSidebar",
        method: "GET")
    }
    group.post("/v1/publications/refresh") { request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/v1/publications/refresh", method: "POST")
    }
    group.post("/xrpc/app.thesocialwire.publication.refreshSidebar") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context,
        path: "/xrpc/app.thesocialwire.publication.refreshSidebar", method: "POST")
    }
    group.post("/v1/publications/resolve") { request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/v1/publications/resolve", method: "POST")
    }
    group.post("/xrpc/app.thesocialwire.publication.resolvePublication") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context,
        path: "/xrpc/app.thesocialwire.publication.resolvePublication", method: "POST")
    }
    group.get("/v1/appview/entries") { request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/v1/appview/entries", method: "GET")
    }
    group.get("/xrpc/app.thesocialwire.appview.listEntries") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/xrpc/app.thesocialwire.appview.listEntries",
        method: "GET")
    }
    group.get("/v1/appview/feed") { request, context async throws -> Response in
      try await forward(request: request, context: context, path: "/v1/appview/feed", method: "GET")
    }
    group.get("/xrpc/app.thesocialwire.appview.getFeed") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/xrpc/app.thesocialwire.appview.getFeed",
        method: "GET")
    }
    group.get("/v1/appview/entry") { request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/v1/appview/entry", method: "GET")
    }
    group.get("/xrpc/app.thesocialwire.appview.getEntry") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/xrpc/app.thesocialwire.appview.getEntry",
        method: "GET")
    }
    group.get("/v1/appview/unread-counts") { request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/v1/appview/unread-counts", method: "GET")
    }
    group.get("/xrpc/app.thesocialwire.appview.getUnreadCounts") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/xrpc/app.thesocialwire.appview.getUnreadCounts",
        method: "GET")
    }
    group.get("/v1/appview/bootstrap-stream") { request, context async throws -> Response in
      try await forwardStreaming(
        request: request,
        context: context,
        path: "/v1/appview/bootstrap-stream",
        method: "GET"
      )
    }
    group.post("/v1/appview/read-marks") { request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/v1/appview/read-marks", method: "POST")
    }
    group.post("/xrpc/app.thesocialwire.appview.putReadMark") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/xrpc/app.thesocialwire.appview.putReadMark",
        method: "POST")
    }
    group.delete("/v1/appview/read-marks") { request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/v1/appview/read-marks", method: "DELETE")
    }
    group.post("/xrpc/app.thesocialwire.appview.deleteReadMark") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/xrpc/app.thesocialwire.appview.deleteReadMark",
        method: "POST")
    }
    group.post("/v1/appview/enroll") { request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/v1/appview/enroll", method: "POST")
    }
    group.post("/xrpc/app.thesocialwire.appview.enrollSources") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/xrpc/app.thesocialwire.appview.enrollSources",
        method: "POST")
    }
    group.delete("/v1/appview/privacy/purge") { request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/v1/appview/privacy/purge", method: "DELETE")
    }
    group.post("/xrpc/app.thesocialwire.appview.purgeViewerData") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/xrpc/app.thesocialwire.appview.purgeViewerData",
        method: "POST")
    }
    group.post("/v1/appview/mark-all-read") { request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/v1/appview/mark-all-read", method: "POST")
    }
    group.post("/xrpc/app.thesocialwire.appview.markAllRead") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/xrpc/app.thesocialwire.appview.markAllRead",
        method: "POST")
    }
  }

  private func forward(
    request: Request,
    context: GatewayRequestContext,
    path: String,
    method: String
  ) async throws -> Response {
    guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
    let signedPath = GatewayInternalTrust.canonicalSignedPath(path)
    let pathWithQuery = GatewayInternalTrust.canonicalPathWithQuery(
      path: path,
      query: request.uri.query
    )
    let url = "\(normalizeBase(baseURL))\(pathWithQuery)"
    var fwd = HTTPClientRequest(url: url)
    switch method {
    case "GET": fwd.method = .GET
    case "POST": fwd.method = .POST
    case "PUT": fwd.method = .PUT
    case "DELETE": fwd.method = .DELETE
    default: fwd.method = .GET
    }
    fwd.headers.add(name: "Accept", value: "application/json")
    fwd.headers.add(name: "Authorization", value: auth.authorizationForwardingValue)
    fwd.headers.add(name: "X-Request-ID", value: context.requestId)
    fwd.headers.add(name: "traceparent", value: context.traceContext.traceparent)
    if let dpop = auth.dpopProof { fwd.headers.add(name: "DPoP", value: dpop) }
    if let upstream = auth.upstreamDpopProof?.trimmingCharacters(in: .whitespacesAndNewlines),
      !upstream.isEmpty
    {
      fwd.headers.add(name: ATProtoUpstreamDPoP.headerName, value: upstream)
    }
    Self.applyForwardedHeaders(from: request, to: &fwd)

    if let internalSecret {
      let signed = try GatewayInternalTrust.signedHeaders(
        secret: internalSecret,
        did: auth.did,
        method: method,
        pathWithQuery: signedPath
      )
      for header in signed {
        fwd.headers.add(name: header.name, value: header.value)
      }
    }

    if method == "POST" || method == "PUT" || method == "DELETE" {
      let body = try await request.body.collect(upTo: 4 * 1024 * 1024)
      if body.readableBytes > 0 {
        fwd.body = .bytes(body)
        fwd.headers.add(name: "Content-Type", value: "application/json")
      }
    }
    let feedPaths = ["/v1/appview/feed", "/xrpc/app.thesocialwire.appview.getFeed"]
    let upstreamTimeout: TimeAmount = feedPaths.contains(path) ? .seconds(3) : .seconds(60)
    let reply = try await httpClient.execute(fwd, timeout: upstreamTimeout)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let requestId = reply.headers.first(name: "X-Request-ID"),
      let requestIdHeader = HTTPField.Name("X-Request-ID")
    {
      headers[requestIdHeader] = requestId
    }
    if let traceparent = reply.headers.first(name: "traceparent"),
      let traceHeader = HTTPField.Name("traceparent")
    {
      headers[traceHeader] = traceparent
    }
    for headerName in [
      "X-AppView-Feed-Source",
      "X-AppView-Membership-Updated-At",
      "Server-Timing",
    ] {
      if let value = reply.headers.first(name: headerName),
        let fieldName = HTTPField.Name(headerName)
      {
        headers[fieldName] = value
      }
    }
    let body = try await reply.body.collect(upTo: 8 * 1024 * 1024)
    let status = HTTPResponse.Status.from(code: Int(reply.status.code)) ?? .badGateway
    return Response(status: status, headers: headers, body: .init(byteBuffer: body))
  }

  private func forwardStreaming(
    request: Request,
    context: GatewayRequestContext,
    path: String,
    method: String
  ) async throws -> Response {
    guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
    let signedPath = GatewayInternalTrust.canonicalSignedPath(path)
    let pathWithQuery = GatewayInternalTrust.canonicalPathWithQuery(
      path: path,
      query: request.uri.query
    )
    let url = "\(normalizeBase(baseURL))\(pathWithQuery)"
    var fwd = HTTPClientRequest(url: url)
    fwd.method = .GET
    fwd.headers.add(name: "Accept", value: "application/x-ndjson")
    fwd.headers.add(name: "Authorization", value: auth.authorizationForwardingValue)
    fwd.headers.add(name: "X-Request-ID", value: context.requestId)
    fwd.headers.add(name: "traceparent", value: context.traceContext.traceparent)
    if let dpop = auth.dpopProof { fwd.headers.add(name: "DPoP", value: dpop) }
    if let upstream = auth.upstreamDpopProof?.trimmingCharacters(in: .whitespacesAndNewlines),
      !upstream.isEmpty
    {
      fwd.headers.add(name: ATProtoUpstreamDPoP.headerName, value: upstream)
    }
    Self.applyForwardedHeaders(from: request, to: &fwd)

    if let internalSecret {
      let signed = try GatewayInternalTrust.signedHeaders(
        secret: internalSecret,
        did: auth.did,
        method: method,
        pathWithQuery: signedPath
      )
      for header in signed {
        fwd.headers.add(name: header.name, value: header.value)
      }
    }

    let reply = try await httpClient.execute(fwd, timeout: .seconds(60))
    var headers = HTTPFields()
    headers[.contentType] = "application/x-ndjson"
    headers[.cacheControl] = "no-cache"
    let status = HTTPResponse.Status.from(code: Int(reply.status.code)) ?? .badGateway
    let streamStarted = Date()
    let byteCounter = BootstrapStreamByteCounter()
    return Response(
      status: status,
      headers: headers,
      body: ResponseBody { writer in
        for try await buffer in reply.body {
          byteCounter.record(buffer.readableBytes)
          byteCounter.logFirstByteIfNeeded(
            path: path,
            streamStarted: streamStarted,
            logger: logger,
            did: auth.did
          )
          try await writer.write(buffer)
        }
        byteCounter.logComplete(
          path: path,
          streamStarted: streamStarted,
          logger: logger,
          did: auth.did
        )
        try await writer.finish(nil)
      }
    )
  }

  private func normalizeBase(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while s.hasSuffix("/") { s.removeLast() }
    return s
  }

  private static func applyForwardedHeaders(from request: Request, to fwd: inout HTTPClientRequest)
  {
    if let host = request.head.authority?.trimmingCharacters(in: .whitespacesAndNewlines),
      !host.isEmpty
    {
      fwd.headers.add(name: "X-Forwarded-Host", value: host)
    }
    if let protoHeader = HTTPField.Name("X-Forwarded-Proto"),
      let proto = request.headers[protoHeader]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !proto.isEmpty
    {
      fwd.headers.add(name: "X-Forwarded-Proto", value: proto)
    } else {
      fwd.headers.add(name: "X-Forwarded-Proto", value: "https")
    }
  }
}

private final class BootstrapStreamByteCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var totalBytes = 0
  private var firstByteLogged = false

  func record(_ bytes: Int) {
    lock.withLock {
      totalBytes += bytes
    }
  }

  func logFirstByteIfNeeded(
    path: String,
    streamStarted: Date,
    logger: Logger,
    did: String
  ) {
    lock.withLock {
      guard !firstByteLogged else { return }
      firstByteLogged = true
      let ttfbMs = Int(Date().timeIntervalSince(streamStarted) * 1000)
      logger.info(
        "AppView bootstrap stream first byte",
        metadata: [
          "path": .string(path),
          "ttfbMs": .stringConvertible(ttfbMs),
          "did": .string(did),
        ]
      )
    }
  }

  func logComplete(
    path: String,
    streamStarted: Date,
    logger: Logger,
    did: String
  ) {
    let (totalMs, bytes) = lock.withLock {
      (
        Int(Date().timeIntervalSince(streamStarted) * 1000),
        totalBytes
      )
    }
    logger.info(
      "AppView bootstrap stream complete",
      metadata: [
        "path": .string(path),
        "totalMs": .stringConvertible(totalMs),
        "totalBytes": .stringConvertible(bytes),
        "did": .string(did),
      ]
    )
  }
}
