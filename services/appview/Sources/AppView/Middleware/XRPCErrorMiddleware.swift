import Foundation
import GatewayCore
import HTTPTypes
import Hummingbird

/// Ensures first-party XRPC methods use the AT Protocol JSON error shape.
struct XRPCErrorMiddleware: RouterMiddleware {
  typealias Context = GatewayRequestContext

  func handle(
    _ request: Request,
    context: GatewayRequestContext,
    next: (Request, GatewayRequestContext) async throws -> Response
  ) async throws -> Response {
    guard request.uri.path.hasPrefix("/xrpc/") else {
      return try await next(request, context)
    }
    do {
      return try await next(request, context)
    } catch {
      let status = (error as? any HTTPResponseError)?.status ?? .internalServerError
      let envelope = XRPCErrorEnvelope(
        error: (error as? WireServingError)?.xrpcErrorName ?? Self.errorName(for: status),
        message: status.code >= 500
          ? "The request could not be completed." : String(describing: error)
      )
      let data = try JSONEncoder().encode(envelope)
      var headers = HTTPFields()
      headers[.contentType] = "application/json"
      return Response(status: status, headers: headers, body: .init(byteBuffer: .init(data: data)))
    }
  }

  private static func errorName(for status: HTTPResponse.Status) -> String {
    switch status.code {
    case 400: "InvalidRequest"
    case 401: "AuthRequired"
    case 403: "Forbidden"
    case 404: "NotFound"
    case 410: "CursorExpired"
    case 429: "RateLimitExceeded"
    case 503: "ServiceUnavailable"
    case 504: "UpstreamTimeout"
    default: "InternalServerError"
    }
  }
}

private struct XRPCErrorEnvelope: Codable, Sendable {
  let error: String
  let message: String
}
