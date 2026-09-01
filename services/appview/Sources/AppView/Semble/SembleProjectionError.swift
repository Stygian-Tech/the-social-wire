import Foundation
import HTTPTypes
import Hummingbird

struct SembleProjectionErrorEnvelope: Codable, Sendable {
  let error: String
  let message: String
  let retryable: Bool
}

struct SembleProjectionError: HTTPResponseError {
  let status: HTTPResponse.Status
  let code: String
  let message: String
  let retryable: Bool

  func response(from request: Request, context: some RequestContext) throws -> Response {
    let data = try JSONEncoder().encode(
      SembleProjectionErrorEnvelope(error: code, message: message, retryable: retryable)
    )
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    return Response(status: status, headers: headers, body: .init(byteBuffer: .init(data: data)))
  }

  static func invalid(_ message: String) -> SembleProjectionError {
    SembleProjectionError(status: .badRequest, code: "invalid_request", message: message, retryable: false)
  }

  static let forbidden = SembleProjectionError(
    status: .forbidden,
    code: "collection_owner_mismatch",
    message: "The configured Semble collection must be owned by the authenticated viewer.",
    retryable: false
  )

  static let notFound = SembleProjectionError(
    status: .notFound,
    code: "semble_collection_not_found",
    message: "The configured Semble collection was not found.",
    retryable: false
  )

  static func upstream(_ message: String) -> SembleProjectionError {
    SembleProjectionError(
      status: .badGateway,
      code: "semble_projection_failed",
      message: message,
      retryable: true
    )
  }
}
