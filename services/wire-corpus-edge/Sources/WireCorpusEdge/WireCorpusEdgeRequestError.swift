import HTTPTypes
import Hummingbird

enum WireCorpusEdgeRequestError: Error, HTTPResponseError, Sendable {
  case invalidRequest
  case unauthorized
  case notFound

  var status: HTTPResponse.Status {
    switch self {
    case .invalidRequest: .badRequest
    case .unauthorized: .unauthorized
    case .notFound: .notFound
    }
  }

  func response(
    from request: Request,
    context: some RequestContext
  ) throws -> Response {
    Response(status: status)
  }
}
