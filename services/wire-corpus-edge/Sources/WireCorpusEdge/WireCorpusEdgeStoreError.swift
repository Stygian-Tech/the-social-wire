import HTTPTypes
import Hummingbird

enum WireCorpusEdgeStoreError: Error, Equatable, HTTPResponseError, Sendable {
  case contractMismatch
  case moderationUnavailable
  case cursorExpired

  var status: HTTPResponse.Status {
    switch self {
    case .cursorExpired: .gone
    case .contractMismatch, .moderationUnavailable: .serviceUnavailable
    }
  }

  func response(
    from request: Request,
    context: some RequestContext
  ) throws -> Response {
    Response(status: status)
  }
}
