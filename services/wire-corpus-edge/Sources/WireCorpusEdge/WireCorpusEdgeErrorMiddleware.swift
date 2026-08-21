import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

struct WireCorpusEdgeErrorMiddleware: RouterMiddleware {
  typealias Context = WireCorpusEdgeRequestContext

  func handle(
    _ request: Request,
    context: WireCorpusEdgeRequestContext,
    next: (Request, WireCorpusEdgeRequestContext) async throws -> Response
  ) async throws -> Response {
    do {
      return try await next(request, context)
    } catch {
      let status = (error as? any HTTPResponseError)?.status ?? .internalServerError
      let errorName: String
      switch status.code {
      case 400: errorName = "invalid_request"
      case 401: errorName = "unauthorized"
      case 404: errorName = "not_found"
      case 410: errorName = "cursor_expired"
      case 503: errorName = "corpus_unavailable"
      default: errorName = "internal_error"
      }
      let body = try JSONEncoder().encode(["error": errorName])
      var headers = HTTPFields()
      headers[.contentType] = "application/json"
      headers[.cacheControl] = "no-store"
      return Response(
        status: status,
        headers: headers,
        body: .init(byteBuffer: ByteBuffer(data: body))
      )
    }
  }
}
