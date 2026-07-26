import AsyncHTTPClient
import Foundation
import GatewayCore
import HTTPTypes
import Hummingbird
import NIOCore
import NIOHTTP1

/// Proxies the operator control plane with a secret distinct from Gateway → AppView trust.
struct OperationsProxyRoutes {
  let baseURL: String
  let internalSecret: String?
  let httpClient: HTTPClient

  func register(on group: RouterGroup<GatewayRequestContext>) {
    get("/v1/operations/overview", path: "/v1/operations/overview", on: group)
    get("/v1/operations/capabilities", path: "/v1/operations/capabilities", on: group)
    get("/v1/operations/metrics", path: "/v1/operations/metrics", on: group)
    group.get("/v1/operations/events/stream") { request, context async throws -> Response in
      try await forwardStreaming(
        request,
        context: context,
        path: "/v1/operations/events/stream"
      )
    }
    get("/v1/operations/services", path: "/v1/operations/services", on: group)
    get("/v1/operations/ingestion", path: "/v1/operations/ingestion", on: group)
    get("/v1/operations/ingestion/endpoints", path: "/v1/operations/ingestion/endpoints", on: group)
    get("/v1/operations/commands", path: "/v1/operations/commands", on: group)
    post("/v1/operations/ingestion/reconnect", path: "/v1/operations/ingestion/reconnect", on: group)
    get("/v1/operations/appview", path: "/v1/operations/appview", on: group)
    get("/v1/operations/gaps", path: "/v1/operations/gaps", on: group)
    group.get("/v1/operations/gaps/:id/investigation") { request, context async throws -> Response in
      guard let id = context.parameters.get("id") else { throw HTTPError(.badRequest) }
      return try await forward(
        request,
        context: context,
        path: "/v1/operations/gaps/\(id)/investigation",
        method: "GET"
      )
    }
    group.patch("/v1/operations/gaps/:id") { request, context async throws -> Response in
      guard let id = context.parameters.get("id") else { throw HTTPError(.badRequest) }
      return try await forward(request, context: context, path: "/v1/operations/gaps/\(id)", method: "PATCH")
    }
    get("/v1/operations/backfills", path: "/v1/operations/backfills", on: group)
    post("/v1/operations/backfills/dry-run", path: "/v1/operations/backfills/dry-run", on: group)
    post("/v1/operations/backfills", path: "/v1/operations/backfills", on: group)
    group.get("/v1/operations/backfills/:id") { request, context async throws -> Response in
      guard let id = context.parameters.get("id") else { throw HTTPError(.badRequest) }
      return try await forward(request, context: context, path: "/v1/operations/backfills/\(id)", method: "GET")
    }
    for action in ["pause", "resume", "cancel"] {
      group.post("/v1/operations/backfills/:id/\(action)") { request, context async throws -> Response in
        guard let id = context.parameters.get("id") else { throw HTTPError(.badRequest) }
        return try await forward(
          request,
          context: context,
          path: "/v1/operations/backfills/\(id)/\(action)",
          method: "POST"
        )
      }
    }
    get("/v1/operations/alerts", path: "/v1/operations/alerts", on: group)
    for action in ["acknowledge", "resolve", "retry"] {
      group.post("/v1/operations/alerts/:id/\(action)") { request, context async throws -> Response in
        guard let id = context.parameters.get("id") else { throw HTTPError(.badRequest) }
        return try await forward(
          request,
          context: context,
          path: "/v1/operations/alerts/\(id)/\(action)",
          method: "POST"
        )
      }
    }
    get("/v1/operations/traces", path: "/v1/operations/traces", on: group)
    group.get("/v1/operations/traces/:traceId") { request, context async throws -> Response in
      guard let traceId = context.parameters.get("traceId") else { throw HTTPError(.badRequest) }
      return try await forward(
        request,
        context: context,
        path: "/v1/operations/traces/\(traceId)",
        method: "GET"
      )
    }
  }

  private func get(_ route: RouterPath, path: String, on group: RouterGroup<GatewayRequestContext>) {
    group.get(route) { request, context async throws -> Response in
      try await forward(request, context: context, path: path, method: "GET")
    }
  }

  private func post(_ route: RouterPath, path: String, on group: RouterGroup<GatewayRequestContext>) {
    group.post(route) { request, context async throws -> Response in
      try await forward(request, context: context, path: path, method: "POST")
    }
  }

  private func forward(
    _ request: Request,
    context: GatewayRequestContext,
    path: String,
    method: String
  ) async throws -> Response {
    guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
    let pathWithQuery = GatewayInternalTrust.canonicalPathWithQuery(path: path, query: request.uri.query)
    var outbound = HTTPClientRequest(url: "\(normalizedBase)\(pathWithQuery)")
    outbound.method = method == "GET" ? .GET : method == "PATCH" ? .PATCH : .POST
    outbound.headers.add(name: "Accept", value: "application/json")
    outbound.headers.add(name: "Authorization", value: auth.authorizationForwardingValue)
    outbound.headers.add(name: "X-Request-ID", value: context.requestId)
    outbound.headers.add(name: "traceparent", value: context.traceContext.traceparent)
    if let dpop = auth.dpopProof { outbound.headers.add(name: "DPoP", value: dpop) }
    if method != "GET", let idempotencyKey = Self.idempotencyKey(from: request.headers) {
      outbound.headers.add(name: "Idempotency-Key", value: idempotencyKey)
    }
    if let internalSecret {
      let signed = try GatewayInternalTrust.signedHeaders(
        secret: internalSecret,
        did: auth.did,
        method: method,
        pathWithQuery: GatewayInternalTrust.canonicalSignedPath(path)
      )
      for header in signed { outbound.headers.add(name: header.name, value: header.value) }
    }
    if method != "GET" {
      let body = try await request.body.collect(upTo: 2 * 1024 * 1024)
      if body.readableBytes > 0 {
        outbound.body = .bytes(body)
        outbound.headers.add(name: "Content-Type", value: "application/json")
      }
    }
    let reply = try await httpClient.execute(outbound, timeout: .seconds(60))
    let body = try await reply.body.collect(upTo: 8 * 1024 * 1024)
    let headers = Self.responseHeaders(from: reply.headers)
    let status = Self.status(Int(reply.status.code))
    return Response(status: status, headers: headers, body: .init(byteBuffer: body))
  }

  private func forwardStreaming(
    _ request: Request,
    context: GatewayRequestContext,
    path: String
  ) async throws -> Response {
    guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
    let pathWithQuery = GatewayInternalTrust.canonicalPathWithQuery(path: path, query: request.uri.query)
    var outbound = HTTPClientRequest(url: "\(normalizedBase)\(pathWithQuery)")
    outbound.method = .GET
    outbound.headers.add(name: "Accept", value: "text/event-stream")
    outbound.headers.add(name: "Authorization", value: auth.authorizationForwardingValue)
    outbound.headers.add(name: "X-Request-ID", value: context.requestId)
    outbound.headers.add(name: "traceparent", value: context.traceContext.traceparent)
    if let dpop = auth.dpopProof { outbound.headers.add(name: "DPoP", value: dpop) }
    if
      let lastEventIdName = HTTPField.Name("Last-Event-ID"),
      let lastEventId = request.headers[lastEventIdName]
    {
      outbound.headers.add(name: "Last-Event-ID", value: lastEventId)
    }
    if let internalSecret {
      let signed = try GatewayInternalTrust.signedHeaders(
        secret: internalSecret,
        did: auth.did,
        method: "GET",
        pathWithQuery: GatewayInternalTrust.canonicalSignedPath(path)
      )
      for header in signed { outbound.headers.add(name: header.name, value: header.value) }
    }

    let reply = try await httpClient.execute(outbound, timeout: .seconds(300))
    var headers = Self.responseHeaders(from: reply.headers)
    headers[.contentType] = reply.headers["content-type"].first ?? "text/event-stream"
    headers[.cacheControl] = "no-cache"
    return Response(
      status: Self.status(Int(reply.status.code)),
      headers: headers,
      body: ResponseBody { writer in
        for try await buffer in reply.body {
          try await writer.write(buffer)
        }
        try await writer.finish(nil)
      }
    )
  }

  private var normalizedBase: String {
    var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.hasSuffix("/") { value.removeLast() }
    return value
  }

  static func status(_ code: Int) -> HTTPResponse.Status {
    guard (100...599).contains(code) else { return .badGateway }
    return HTTPResponse.Status(code: code)
  }

  static func idempotencyKey(from headers: HTTPFields) -> String? {
    guard let name = HTTPField.Name("Idempotency-Key") else { return nil }
    return headers[name]
  }

  /// Preserve operational response metadata without forwarding hop-by-hop headers.
  /// These values are part of the operator contract: retry timing, request/trace
  /// correlation, DPoP nonce challenges, caching, and redirect targets must not be
  /// erased by the Gateway hop.
  static func responseHeaders(from upstream: HTTPHeaders) -> HTTPFields {
    var response = HTTPFields()
    let names = [
      "content-type",
      "retry-after",
      "x-request-id",
      "traceparent",
      "dpop-nonce",
      "cache-control",
      "etag",
      "last-modified",
      "location",
      "x-accel-buffering",
    ]
    for name in names {
      guard
        let value = upstream[name].first,
        let fieldName = HTTPField.Name(name)
      else { continue }
      response[fieldName] = value
    }
    if response[.contentType] == nil {
      response[.contentType] = "application/json"
    }
    return response
  }
}
