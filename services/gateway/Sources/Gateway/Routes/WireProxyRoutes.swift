import AsyncHTTPClient
import Foundation
import GatewayCore
import HTTPTypes
import Hummingbird
import Logging
import NIOCore

struct WireProxyRoutes {
  let baseURL: String
  let internalSecret: String?
  let httpClient: HTTPClient
  let limiter: WireRequestLimiter
  let logger: Logger

  func register(on group: RouterGroup<GatewayRequestContext>) {
    for path in Self.paths {
      group.get(RouterPath(path)) { request, context async throws -> Response in
        try await forward(request: request, context: context, path: path)
      }
    }
    group.post("/xrpc/app.thesocialwire.discovery.recordFinanceComposition") { request, context async throws -> Response in
      guard context.authContext != nil else { throw HTTPError(.unauthorized) }
      return try await forward(request: request, context: context,
        path: "/xrpc/app.thesocialwire.discovery.recordFinanceComposition", method: "POST")
    }
  }

  static let paths = [
    "/xrpc/app.thesocialwire.discovery.getSports",
    "/xrpc/app.thesocialwire.discovery.getSportsCatalog",
    "/xrpc/app.thesocialwire.discovery.searchSportsEntities",
    "/xrpc/app.thesocialwire.discovery.getSportsEvents",
    "/xrpc/app.thesocialwire.discovery.getFinance",
    "/xrpc/app.thesocialwire.discovery.getFinanceCatalog",
    "/xrpc/app.thesocialwire.discovery.searchFinanceInstruments",
    "/xrpc/app.thesocialwire.discovery.getFinanceSectors",
    "/xrpc/app.thesocialwire.discovery.getWire",
    "/xrpc/app.thesocialwire.discovery.getWireEdition",
    "/xrpc/app.thesocialwire.discovery.getWireItem",
    "/xrpc/app.thesocialwire.discovery.getFeedCatalog",
  ]

  private func forward(
    request: Request,
    context: GatewayRequestContext,
    path: String,
    method: String = "GET"
  ) async throws -> Response {
    let authenticated = context.authContext != nil
    let audience: WireRequestLimiter.Audience = authenticated ? .authenticated : .anonymous
    let limiterKey = authenticated
      ? "did:\(context.authContext!.did)"
      : "ip:\(Self.clientAddress(request))"
    guard await limiter.consume(key: limiterKey, audience: audience) else {
      var headers = HTTPFields()
      headers[.retryAfter] = "60"
      headers[.contentType] = "application/json"
      return Response(
        status: .tooManyRequests,
        headers: headers,
        body: .init(byteBuffer: ByteBuffer(string: #"{"error":"RateLimitExceeded","message":"The Wire request limit was exceeded."}"#))
      )
    }

    let pathWithQuery: String
    if path == "/xrpc/app.thesocialwire.discovery.searchSportsEntities", let query = request.uri.query, !query.isEmpty {
      // Sports search uses form query semantics: raw '+' means space, while '%2B' is literal '+'.
      // Preserve this distinction across the proxy; internal trust already signs only the fixed route path.
      pathWithQuery = "\(path)?\(query)"
    } else {
      pathWithQuery = GatewayInternalTrust.canonicalPathWithQuery(path: path, query: request.uri.query)
    }
    var forwarded = HTTPClientRequest(url: "\(normalizeBase(baseURL))\(pathWithQuery)")
    forwarded.method = method == "POST" ? .POST : .GET
    if method == "POST" {
      forwarded.body = .bytes(try await request.body.collect(upTo: 4096))
      forwarded.headers.add(name: "Content-Type", value: "application/json")
    }
    forwarded.headers.add(name: "Accept", value: "application/json")
    forwarded.headers.add(name: "X-Request-ID", value: context.requestId)
    forwarded.headers.add(name: "traceparent", value: context.traceContext.traceparent)

    let internalDID: String
    if let auth = context.authContext {
      internalDID = auth.did
      forwarded.headers.add(name: "Authorization", value: auth.authorizationForwardingValue)
      if let proof = auth.dpopProof { forwarded.headers.add(name: "DPoP", value: proof) }
      if let name = HTTPField.Name(WireModerationDPoP.headerName),
        let proofs = request.headers[name]
      {
        forwarded.headers.add(name: WireModerationDPoP.headerName, value: proofs)
      }
    } else {
      internalDID = GatewayInternalTrustAuthMiddleware.anonymousDiscoveryDID
    }
    if let internalSecret {
      for header in try GatewayInternalTrust.signedHeaders(
        secret: internalSecret,
        did: internalDID,
        method: method,
        pathWithQuery: GatewayInternalTrust.canonicalSignedPath(path)
      ) {
        forwarded.headers.add(name: header.name, value: header.value)
      }
    }
    if !authenticated, let etag = request.headers[.ifNoneMatch] {
      forwarded.headers.add(name: "If-None-Match", value: etag)
    }

    let reply: HTTPClientResponse
    do {
      reply = try await httpClient.execute(
        forwarded,
        timeout: .seconds(WireModerationDPoP.gatewayProxyTimeoutSeconds)
      )
    } catch {
      logger.error("The Wire AppView proxy failed", metadata: ["error": .string("\(error)")])
      throw HTTPError(.badGateway, message: "The Wire is temporarily unavailable.")
    }
    let maximumBytes = Self.maximumResponseBytes(for: path)
    let body: ByteBuffer
    do {
      body = try await reply.body.collect(upTo: maximumBytes)
    } catch {
      if error is CancellationError { throw error }
      logger.warning("The Wire AppView response body failed", metadata: [
        "route": .string(path), "maximumBytes": .stringConvertible(maximumBytes),
      ])
      // A rejected upstream body is a gateway failure, not an oversized client request (413).
      throw HTTPError(.badGateway, message: "The Wire is temporarily unavailable.")
    }
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    headers[.vary] = "Authorization, Accept-Language"
    if authenticated || method == "POST" || (path.contains("Finance") || path.contains("Sports")) {
      headers[.cacheControl] = (path.contains("Finance") || path.contains("Sports")) ? "private, no-store" : "private, max-age=0"
    } else {
      headers[.cacheControl] =
        reply.headers.first(name: "Cache-Control")
        ?? "public, max-age=60, stale-while-revalidate=300"
      if let etag = reply.headers.first(name: "ETag") { headers[.eTag] = etag }
    }
    for rawName in ["X-Wire-Generation", "X-Wire-Source", "X-Request-ID", "traceparent"] {
      guard let value = reply.headers.first(name: rawName), let name = HTTPField.Name(rawName) else {
        continue
      }
      headers[name] = value
    }
    return Response(
      status: Self.status(code: Int(reply.status.code)),
      headers: headers,
      body: .init(byteBuffer: body)
    )
  }

  static func maximumResponseBytes(for path: String) -> Int {
    // Full Sports catalogs contain both entities and named feeds; combined catalogs embed them too.
    switch path {
    case "/xrpc/app.thesocialwire.discovery.getSportsCatalog", "/xrpc/app.thesocialwire.discovery.getFeedCatalog":
      return 32 * 1024 * 1024
    default:
      return 8 * 1024 * 1024
    }
  }

  private func normalizeBase(_ raw: String) -> String {
    raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  static func clientAddress(_ request: Request) -> String {
    for rawName in ["CF-Connecting-IP", "X-Forwarded-For"] {
      guard let name = HTTPField.Name(rawName), let raw = request.headers[name] else { continue }
      if let first = raw.split(separator: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines),
        !first.isEmpty
      {
        return first
      }
    }
    return "unknown"
  }

  private static func status(code: Int) -> HTTPResponse.Status {
    switch code {
    case 200: .ok
    case 304: .notModified
    case 400: .badRequest
    case 401: .unauthorized
    case 403: .forbidden
    case 404: .notFound
    case 410: .gone
    case 429: .tooManyRequests
    case 503: .serviceUnavailable
    default: .badGateway
    }
  }
}
