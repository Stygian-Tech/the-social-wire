import AsyncHTTPClient
import Foundation
import GatewayCore
import Hummingbird
import NIOCore

private extension HTTPResponse.Status {
  static func from(code: Int) -> HTTPResponse.Status? {
    switch code {
    case 200: .ok
    case 201: .created
    case 204: .noContent
    case 304: .notModified
    case 400: .badRequest
    case 401: .unauthorized
    case 403: .forbidden
    case 404: .notFound
    case 502: .badGateway
    default: nil
    }
  }
}

/// Forwards AppView read routes to the AppView service during distributed deployment.
struct AppViewProxyRoutes {
  let baseURL: String
  let internalSecret: String?
  let httpClient: HTTPClient

  func register(on group: RouterGroup<GatewayRequestContext>) {
    group.get("/v1/publications/sidebar") { request, context async throws -> Response in
      try await forward(request: request, context: context, path: "/v1/publications/sidebar", method: "GET")
    }
    group.post("/v1/publications/refresh") { request, context async throws -> Response in
      try await forward(request: request, context: context, path: "/v1/publications/refresh", method: "POST")
    }
    group.post("/v1/publications/resolve") { request, context async throws -> Response in
      try await forward(request: request, context: context, path: "/v1/publications/resolve", method: "POST")
    }
    group.get("/v1/appview/entries") { request, context async throws -> Response in
      try await forward(request: request, context: context, path: "/v1/appview/entries", method: "GET")
    }
    group.get("/v1/appview/entry") { request, context async throws -> Response in
      try await forward(request: request, context: context, path: "/v1/appview/entry", method: "GET")
    }
    group.get("/v1/appview/unread-counts") { request, context async throws -> Response in
      try await forward(request: request, context: context, path: "/v1/appview/unread-counts", method: "GET")
    }
    group.post("/v1/appview/read-marks") { request, context async throws -> Response in
      try await forward(request: request, context: context, path: "/v1/appview/read-marks", method: "POST")
    }
    group.delete("/v1/appview/read-marks") { request, context async throws -> Response in
      try await forward(request: request, context: context, path: "/v1/appview/read-marks", method: "DELETE")
    }
    group.post("/v1/appview/enroll") { request, context async throws -> Response in
      try await forward(request: request, context: context, path: "/v1/appview/enroll", method: "POST")
    }
    group.delete("/v1/appview/privacy/purge") { request, context async throws -> Response in
      try await forward(request: request, context: context, path: "/v1/appview/privacy/purge", method: "DELETE")
    }
    group.post("/v1/appview/mark-all-read") { request, context async throws -> Response in
      try await forward(request: request, context: context, path: "/v1/appview/mark-all-read", method: "POST")
    }
  }

  private func forward(
    request: Request,
    context: GatewayRequestContext,
    path: String,
    method: String
  ) async throws -> Response {
    guard let auth = context.authContext else { throw HTTPError(.unauthorized) }
    let pathWithQuery = GatewayInternalTrust.canonicalPathWithQuery(
      path: path,
      query: request.uri.query
    )
    let url = try forwardURL(baseURL: baseURL, pathWithQuery: pathWithQuery)
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
    if let dpop = auth.dpopProof { fwd.headers.add(name: "DPoP", value: dpop) }

    if let internalSecret {
      let signed = try GatewayInternalTrust.signedHeaders(
        secret: internalSecret,
        did: auth.did,
        method: method,
        pathWithQuery: pathWithQuery
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
    let reply = try await httpClient.execute(fwd, timeout: .seconds(60))
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    let body = try await reply.body.collect(upTo: 8 * 1024 * 1024)
    let status = HTTPResponse.Status.from(code: Int(reply.status.code)) ?? .badGateway
    return Response(status: status, headers: headers, body: .init(byteBuffer: body))
  }

  private func normalizeBase(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while s.hasSuffix("/") { s.removeLast() }
    return s
  }

  private func forwardURL(baseURL: String, pathWithQuery: String) throws -> String {
    guard var components = URLComponents(string: normalizeBase(baseURL)) else {
      throw HTTPError(.badGateway, message: "Invalid AppView base URL")
    }

    if let questionMark = pathWithQuery.firstIndex(of: "?") {
      components.path = String(pathWithQuery[..<questionMark])
      components.percentEncodedQuery = String(pathWithQuery[pathWithQuery.index(after: questionMark)...])
    } else {
      components.path = pathWithQuery
      components.percentEncodedQuery = nil
    }

    guard let url = components.url?.absoluteString else {
      throw HTTPError(.badGateway, message: "Invalid AppView forward URL")
    }
    return url
  }
}
