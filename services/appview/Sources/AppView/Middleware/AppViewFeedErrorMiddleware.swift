import GatewayCore
import Hummingbird

struct AppViewFeedErrorMiddleware: RouterMiddleware {
  typealias Context = GatewayRequestContext

  func handle(
    _ request: Request,
    context: GatewayRequestContext,
    next: (Request, GatewayRequestContext) async throws -> Response
  ) async throws -> Response {
    guard request.uri.path == "/v1/appview/feed"
      || request.uri.path == "/v1/appview/entries"
    else {
      return try await next(request, context)
    }
    do {
      return try await next(request, context)
    } catch {
      let classified = AppViewFeedErrorClassifier.classify(
        error,
        requestId: context.requestId
      )
      return try classified.response(from: request, context: context)
    }
  }
}
