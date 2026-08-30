import AsyncHTTPClient
import Foundation
import GatewayCore
import HTTPTypes
import Hummingbird
import Logging
import NIOCore
import NIOHTTP1

struct CircleProxyRoutes {
  let baseURL: String
  let internalSecret: String?
  let httpClient: HTTPClient
  let limiter: WireRequestLimiter
  let logger: Logger

  func register(on group: RouterGroup<GatewayRequestContext>) {
    for path in Self.queryPaths {
      group.get(RouterPath(path)) { request, context async throws -> Response in
        try await forward(request: request, context: context, path: path, method: .GET)
      }
    }
    group.post("/xrpc/app.thesocialwire.discovery.setCircleItemHidden") {
      request, context async throws -> Response in
      try await forward(
        request: request,
        context: context,
        path: "/xrpc/app.thesocialwire.discovery.setCircleItemHidden",
        method: .POST
      )
    }
  }

  static let queryPaths = [
    "/xrpc/app.thesocialwire.discovery.getCircleCatalog",
    "/xrpc/app.thesocialwire.discovery.getCircleEdition",
  ]

  private func forward(
    request: Request,
    context: GatewayRequestContext,
    path: String,
    method: HTTPMethod
  ) async throws -> Response {
    guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
    guard await limiter.consume(key: "did:\(auth.did)", audience: .authenticated) else {
      var headers = HTTPFields()
      headers[.retryAfter] = "60"
      return Response(status: .tooManyRequests, headers: headers)
    }
    let pathWithQuery = GatewayInternalTrust.canonicalPathWithQuery(
      path: path,
      query: request.uri.query
    )
    var forwarded = HTTPClientRequest(url: "\(normalizeBase(baseURL))\(pathWithQuery)")
    forwarded.method = method
    forwarded.headers.add(name: "Accept", value: "application/json")
    forwarded.headers.add(name: "Authorization", value: auth.authorizationForwardingValue)
    forwarded.headers.add(name: "X-Request-ID", value: context.requestId)
    forwarded.headers.add(name: "traceparent", value: context.traceContext.traceparent)
    if let proof = auth.dpopProof { forwarded.headers.add(name: "DPoP", value: proof) }
    if let name = HTTPField.Name(CircleGraphDPoP.headerName),
      let proofs = request.headers[name]
    {
      forwarded.headers.add(name: CircleGraphDPoP.headerName, value: proofs)
    }
    if method == .POST {
      forwarded.headers.add(name: "Content-Type", value: "application/json")
      forwarded.body = .bytes(try await request.body.collect(upTo: 64 * 1_024))
    }
    if let internalSecret {
      for header in try GatewayInternalTrust.signedHeaders(
        secret: internalSecret,
        did: auth.did,
        method: method.rawValue,
        pathWithQuery: GatewayInternalTrust.canonicalSignedPath(path)
      ) {
        forwarded.headers.add(name: header.name, value: header.value)
      }
    }
    let reply: HTTPClientResponse
    do {
      reply = try await httpClient.execute(forwarded, timeout: .seconds(35))
    } catch {
      logger.error("Your Circle AppView proxy failed")
      throw HTTPError(.badGateway, message: "Your Circle is temporarily unavailable.")
    }
    let body = try await reply.body.collect(upTo: 8 * 1_024 * 1_024)
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    headers[.cacheControl] = "private, no-store"
    headers[.vary] = "Authorization, Accept-Language"
    return Response(
      status: Self.status(code: Int(reply.status.code)),
      headers: headers,
      body: .init(byteBuffer: body)
    )
  }

  private func normalizeBase(_ raw: String) -> String {
    raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private static func status(code: Int) -> HTTPResponse.Status {
    switch code {
    case 200: .ok
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
