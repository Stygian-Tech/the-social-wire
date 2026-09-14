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
    group.get("/v1/semble/collections") { request, context async throws -> Response in
      try await forward(
        request: request, context: context,
        path: "/v1/semble/collections", method: "GET")
    }
    group.get("/v1/semble/collection") { request, context async throws -> Response in
      try await forward(
        request: request, context: context,
        path: "/v1/semble/collection", method: "GET")
    }
    group.get("/v1/semble/connections") { request, context async throws -> Response in
      try await forward(
        request: request, context: context,
        path: "/v1/semble/connections", method: "GET")
    }
    group.get("/v1/publications/sidebar") { request, context async throws -> Response in
      try await forward(
        request: request, context: context,
        path: "/xrpc/app.thesocialwire.publication.getSidebar", method: "GET")
    }
    group.get("/xrpc/app.thesocialwire.publication.getSidebar") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/xrpc/app.thesocialwire.publication.getSidebar",
        method: "GET")
    }
    group.post("/v1/publications/refresh") { request, context async throws -> Response in
      try await forward(
        request: request, context: context,
        path: "/xrpc/app.thesocialwire.publication.refreshSidebar", method: "POST")
    }
    group.post("/xrpc/app.thesocialwire.publication.refreshSidebar") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context,
        path: "/xrpc/app.thesocialwire.publication.refreshSidebar", method: "POST")
    }
    group.post("/v1/publications/resolve") { request, context async throws -> Response in
      try await forward(
        request: request, context: context,
        path: "/xrpc/app.thesocialwire.publication.resolvePublication", method: "POST")
    }
    group.post("/xrpc/app.thesocialwire.publication.resolvePublication") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context,
        path: "/xrpc/app.thesocialwire.publication.resolvePublication", method: "POST")
    }
    group.get("/v1/appview/entries") { request, context async throws -> Response in
      try await forward(
        request: request, context: context,
        path: "/xrpc/app.thesocialwire.appview.listEntries", method: "GET")
    }
    group.get("/xrpc/app.thesocialwire.appview.listEntries") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/xrpc/app.thesocialwire.appview.listEntries",
        method: "GET")
    }
    group.get("/v1/appview/feed") { request, context async throws -> Response in
      try await forward(
        request: request, context: context,
        path: "/xrpc/app.thesocialwire.appview.getFeed", method: "GET")
    }
    group.get("/xrpc/app.thesocialwire.appview.getFeed") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/xrpc/app.thesocialwire.appview.getFeed",
        method: "GET")
    }
    group.get("/v1/appview/entry") { request, context async throws -> Response in
      try await forward(
        request: request, context: context,
        path: "/xrpc/app.thesocialwire.appview.getEntry", method: "GET")
    }
    group.get("/xrpc/app.thesocialwire.appview.getEntry") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/xrpc/app.thesocialwire.appview.getEntry",
        method: "GET")
    }
    group.get("/v1/appview/unread-counts") { request, context async throws -> Response in
      try await forward(
        request: request, context: context,
        path: "/xrpc/app.thesocialwire.appview.getUnreadCounts", method: "GET")
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
        request: request, context: context,
        path: "/xrpc/app.thesocialwire.appview.putReadMark", method: "POST")
    }
    group.post("/xrpc/app.thesocialwire.appview.putReadMark") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/xrpc/app.thesocialwire.appview.putReadMark",
        method: "POST")
    }
    group.delete("/v1/appview/read-marks") { request, context async throws -> Response in
      try await forward(
        request: request, context: context,
        path: "/xrpc/app.thesocialwire.appview.deleteReadMark", method: "POST")
    }
    group.post("/xrpc/app.thesocialwire.appview.deleteReadMark") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/xrpc/app.thesocialwire.appview.deleteReadMark",
        method: "POST")
    }
    group.post("/v1/appview/enroll") { request, context async throws -> Response in
      try await forward(
        request: request, context: context,
        path: "/xrpc/app.thesocialwire.appview.enrollSources", method: "POST")
    }
    group.post("/xrpc/app.thesocialwire.appview.enrollSources") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/xrpc/app.thesocialwire.appview.enrollSources",
        method: "POST")
    }
    group.delete("/v1/appview/privacy/purge") { request, context async throws -> Response in
      try await forward(
        request: request, context: context,
        path: "/xrpc/app.thesocialwire.appview.purgeViewerData", method: "POST")
    }
    group.post("/xrpc/app.thesocialwire.appview.purgeViewerData") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/xrpc/app.thesocialwire.appview.purgeViewerData",
        method: "POST")
    }
    group.post("/v1/appview/mark-all-read") { request, context async throws -> Response in
      try await forward(
        request: request, context: context,
        path: "/xrpc/app.thesocialwire.appview.markAllRead", method: "POST")
    }
    group.post("/xrpc/app.thesocialwire.appview.markAllRead") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/xrpc/app.thesocialwire.appview.markAllRead",
        method: "POST")
    }
    group.get("/xrpc/app.thesocialwire.appview.getReadAgeOptions") {
      request, context async throws -> Response in
      if request.headers[.accept]?.contains("application/x-ndjson") == true {
        return try await forwardStreaming(
          request: request, context: context, path: "/xrpc/app.thesocialwire.appview.getReadAgeOptions",
          method: "GET")
      }
      return try await forward(
        request: request, context: context, path: "/xrpc/app.thesocialwire.appview.getReadAgeOptions",
        method: "GET")
    }
    group.post("/xrpc/app.thesocialwire.appview.markReadBefore") {
      request, context async throws -> Response in
      try await forward(
        request: request, context: context, path: "/xrpc/app.thesocialwire.appview.markReadBefore",
        method: "POST")
    }
  }

  private func forward(
    request: Request,
    context: GatewayRequestContext,
    path: String,
    method: String
  ) async throws -> Response {
    let feedPaths = ["/v1/appview/feed", "/xrpc/app.thesocialwire.appview.getFeed"]
    let duration: Duration = feedPaths.contains(path) ? .seconds(3) : .seconds(60)
    let deadline = ContinuousClock.now.advanced(by: duration)
    let trace = AppViewProxyRequestTrace(path: path, requestID: context.requestId, logger: logger)
    // HTTPClient.execute's timeout does not cover consuming a response body.
    // Keep the entire buffered exchange within one budget and await cancellation.
    return try await withThrowingTaskGroup(of: Response.self) { group in
      defer { group.cancelAll() }
      group.addTask {
        try await forwardBuffered(request: request, context: context, path: path,
          method: method, trace: trace)
      }
      group.addTask {
        try await ContinuousClock().sleep(until: deadline)
        trace.finish(failure: .timeout)
        throw AppViewProxyFailure.timeout.responseError
      }
      guard let response = try await group.next() else { throw CancellationError() }
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else {
        trace.finish(failure: .timeout)
        throw AppViewProxyFailure.timeout.responseError
      }
      trace.finish()
      return response
    }
  }

  private func forwardBuffered(
    request: Request,
    context: GatewayRequestContext,
    path: String,
    method: String,
    trace: AppViewProxyRequestTrace
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
    let reply: HTTPClientResponse
    do {
      reply = try await httpClient.execute(fwd, timeout: upstreamTimeout)
      trace.receivedHeaders(status: Int(reply.status.code))
    } catch {
      let failure = AppViewProxyFailure(error)
      trace.finish(failure: failure)
      throw failure.responseError
    }
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
    let body: ByteBuffer
    do {
      let maximumBytes = 8 * 1024 * 1024
      var collected = ByteBuffer()
      for try await chunk in reply.body {
        trace.receivedBytes(chunk.readableBytes)
        guard chunk.readableBytes <= maximumBytes - collected.readableBytes else {
          throw NIOTooManyBytesError(maxBytes: maximumBytes)
        }
        collected.writeImmutableBuffer(chunk)
      }
      body = collected
    } catch {
      let failure = AppViewProxyFailure(error)
      trace.finish(failure: failure)
      throw failure.responseError
    }
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

    let trace = AppViewProxyRequestTrace(path: path, requestID: context.requestId, logger: logger)
    let reply: HTTPClientResponse
    do {
      reply = try await httpClient.execute(fwd, timeout: .seconds(60))
      trace.receivedHeaders(status: Int(reply.status.code))
    } catch {
      let failure = AppViewProxyFailure(error)
      trace.finish(failure: failure)
      throw failure.responseError
    }
    var headers = HTTPFields()
    headers[.contentType] = reply.headers.first(name: "Content-Type") ?? "application/x-ndjson"
    headers[.cacheControl] = "no-cache"
    let status = HTTPResponse.Status.from(code: Int(reply.status.code)) ?? .badGateway
    return Response(
      status: status,
      headers: headers,
      body: ResponseBody { writer in
        do {
          for try await buffer in reply.body {
            trace.receivedBytes(buffer.readableBytes)
            try await writer.write(buffer)
          }
          try await writer.finish(nil)
          trace.finish()
        } catch {
          trace.finish(failure: AppViewProxyFailure(error))
          // Headers are already committed; terminate the stream rather than
          // pretending a partial response is complete or attempting a retry.
          throw error
        }
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
