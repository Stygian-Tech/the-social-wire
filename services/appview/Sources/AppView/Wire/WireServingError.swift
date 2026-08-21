import HTTPTypes
import Hummingbird

enum WireServingError: Error, HTTPResponseError, Sendable {
  case unavailable
  case invalidCursor
  case cursorExpired
  case itemNotFound
  case moderationUnavailable

  var status: HTTPResponse.Status {
    switch self {
    case .invalidCursor: .badRequest
    case .cursorExpired: .gone
    case .itemNotFound: .notFound
    case .unavailable, .moderationUnavailable: .serviceUnavailable
    }
  }

  var xrpcErrorName: String {
    switch self {
    case .unavailable: "FeedUnavailable"
    case .invalidCursor: "InvalidRequest"
    case .cursorExpired: "CursorExpired"
    case .itemNotFound: "NotFound"
    case .moderationUnavailable: "ModerationUnavailable"
    }
  }

  func response(
    from request: Request,
    context: some RequestContext
  ) throws -> Response {
    Response(status: status)
  }
}
