import GatewayCore
import Foundation
import HTTPTypes
import Hummingbird

/// Normalizes locally generated failures to the XRPC `{ error, message }` contract.
struct OperationsXRPCErrorMiddleware: RouterMiddleware {
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
      let message = status.code >= 500
        ? "The request could not be completed."
        : "The request is invalid."
      let envelope = OperationsXRPCErrorEnvelope(
        error: Self.errorName(for: status),
        message: message
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
    case 409: "InvalidRequest"
    case 429: "RateLimitExceeded"
    case 503: "ServiceUnavailable"
    default: "InternalServerError"
    }
  }
}

private struct OperationsXRPCErrorEnvelope: Codable, Sendable {
  let error: String
  let message: String
}
