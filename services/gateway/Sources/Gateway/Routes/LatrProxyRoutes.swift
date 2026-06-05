import AsyncHTTPClient
import Foundation
import GatewayCore
import HTTPTypes
import Hummingbird
import Logging
import NIOCore

/// Authenticated proxy to the external L@tr Gateway for native iOS clients. Injects iOS-proxy
/// server credentials; forwards user Authorization, upstream PDS DPoP, and L@tr-bound DPoP from the client.
struct LatrProxyRoutes {
  let config: LatrIosProxyCredentials.Config
  let httpClient: HTTPClient
  let logger: Logger

  private static let forwardedRequestHeaders: [String] = [
    "accept",
    "content-type",
  ]

  private static let forwardedResponseHeaders: [String] = [
    "content-type",
    "dpop-nonce",
  ]

  func register(on group: RouterGroup<GatewayRequestContext>) {
    group.get("/v1/latr/saves") { request, context async throws -> Response in
      try await forward(request: request, context: context, path: "/v1/latr/saves", method: "GET")
    }
    group.post("/v1/latr/saves") { request, context async throws -> Response in
      try await forward(request: request, context: context, path: "/v1/latr/saves", method: "POST")
    }
    group.patch("/v1/latr/saves/:rkey/state") { request, context async throws -> Response in
      guard let rkey = context.coreContext.parameters.get("rkey") else {
        throw HTTPError(.badRequest, message: "Missing rkey")
      }
      let encoded = rkey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rkey
      return try await forward(
        request: request,
        context: context,
        path: "/v1/latr/saves/\(encoded)/state",
        method: "PATCH"
      )
    }
    group.delete("/v1/latr/saves/:rkey") { request, context async throws -> Response in
      guard let rkey = context.coreContext.parameters.get("rkey") else {
        throw HTTPError(.badRequest, message: "Missing rkey")
      }
      let encoded = rkey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rkey
      return try await forward(
        request: request,
        context: context,
        path: "/v1/latr/saves/\(encoded)",
        method: "DELETE"
      )
    }
    group.get("/v1/latr/og-preview") { request, context async throws -> Response in
      try await forward(request: request, context: context, path: "/v1/latr/og-preview", method: "GET")
    }
  }

  private func forward(
    request: Request,
    context: GatewayRequestContext,
    path: String,
    method: String
  ) async throws -> Response {
    guard config.hasServerCredentials else {
      throw HTTPError(
        .serviceUnavailable,
        message: LatrIosProxyCredentials.Config.credentialsHelpText()
      )
    }
    guard let auth = context.authContext else { throw HTTPError(.unauthorized) }

    let latrGatewayDpop = LatrGatewayUpstreamDPoP.extract(from: request)
    guard let latrGatewayDpop, !latrGatewayDpop.isEmpty else {
      throw HTTPError(.badRequest, message: "Missing \(LatrGatewayUpstreamDPoP.headerName)")
    }

    let pathWithQuery = GatewayInternalTrust.canonicalPathWithQuery(
      path: path,
      query: request.uri.query
    )
    let url = "\(normalizeBase(config.baseURL))\(pathWithQuery)"
    var fwd = HTTPClientRequest(url: url)
    switch method {
    case "GET": fwd.method = .GET
    case "POST": fwd.method = .POST
    case "PATCH": fwd.method = .PATCH
    case "DELETE": fwd.method = .DELETE
    default: fwd.method = .GET
    }

    fwd.headers.add(name: "Accept", value: "application/json")
    fwd.headers.add(name: "Authorization", value: auth.authorizationForwardingValue)
    fwd.headers.add(name: "DPoP", value: latrGatewayDpop)
    if let upstream = auth.upstreamDpopProof?.trimmingCharacters(in: .whitespacesAndNewlines),
       !upstream.isEmpty
    {
      fwd.headers.add(name: ATProtoUpstreamDPoP.headerName, value: upstream)
    }
    for (name, value) in config.authHeaders() {
      fwd.headers.add(name: name, value: value)
    }
    applyForwardedHeaders(from: request, to: &fwd)

    if method == "POST" || method == "PATCH" || method == "DELETE" {
      let body = try await request.body.collect(upTo: 4 * 1024 * 1024)
      if body.readableBytes > 0 {
        fwd.body = .bytes(body)
        if fwd.headers["Content-Type"].first == nil {
          fwd.headers.add(name: "Content-Type", value: "application/json")
        }
      }
    }

    let reply: HTTPClientResponse
    do {
      reply = try await httpClient.execute(fwd, timeout: .seconds(60))
    } catch {
      logger.error("L@tr gateway proxy request failed", metadata: ["path": .string(path)])
      throw HTTPError(.badGateway, message: "L@tr gateway request failed.")
    }

    var headers = HTTPFields()
    if let contentType = reply.headers["content-type"].first {
      headers[.contentType] = contentType
    } else {
      headers[.contentType] = "application/json"
    }
    if let nonce = reply.headers["dpop-nonce"].first {
      headers[HTTPField.Name("DPoP-Nonce")!] = nonce
    }
    let body = try await reply.body.collect(upTo: 8 * 1024 * 1024)
    let status = HTTPResponse.Status.from(code: Int(reply.status.code)) ?? .badGateway
    return Response(status: status, headers: headers, body: .init(byteBuffer: body))
  }

  private func normalizeBase(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while s.hasSuffix("/") { s.removeLast() }
    return s
  }

  private func applyForwardedHeaders(from request: Request, to fwd: inout HTTPClientRequest) {
    for name in Self.forwardedRequestHeaders {
      guard let field = HTTPField.Name(name) else { continue }
      if let value = request.headers[field]?.trimmingCharacters(in: .whitespacesAndNewlines),
         !value.isEmpty
      {
        fwd.headers.add(name: name, value: value)
      }
    }
  }
}

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
    case 500: .internalServerError
    case 502: .badGateway
    case 503: .serviceUnavailable
    case 504: .gatewayTimeout
    default: nil
    }
  }
}
