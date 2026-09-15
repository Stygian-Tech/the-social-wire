import GatewayCore
import Hummingbird
import Logging
import ThinAppViewCore

struct AppViewFeedErrorMiddleware: RouterMiddleware {
  typealias Context = GatewayRequestContext

  func handle(
    _ request: Request,
    context: GatewayRequestContext,
    next: (Request, GatewayRequestContext) async throws -> Response
  ) async throws -> Response {
    guard
      request.uri.path == "/v1/appview/feed"
        || request.uri.path == "/v1/appview/entries"
        || request.uri.path == "/xrpc/app.thesocialwire.appview.getFeed"
        || request.uri.path == "/xrpc/app.thesocialwire.appview.listEntries"
    else {
      return try await next(request, context)
    }
    let timings = AppViewFeedRequestTimings()
    return try await AppViewFeedRequestTimings.$current.withValue(timings) {
      let started = ContinuousClock.now
      do {
        let response = try await next(request, context)
        logCompletion(context: context, route: request.uri.path, started: started,
          status: response.status.code, errorCode: nil)
        return response
      } catch {
        let classified = AppViewFeedErrorClassifier.classify(
          error,
          requestId: context.requestId
        )
        logCompletion(context: context, route: request.uri.path, started: started,
          status: classified.status.code, errorCode: classified.code)
        return try classified.response(from: request, context: context)
      }
    }
  }

  private func logCompletion(context: GatewayRequestContext, route: String,
    started: ContinuousClock.Instant, status: Int, errorCode: String?) {
    let elapsed = started.duration(to: .now).components
    let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
    // Only the four allowlisted route paths above reach this logger. Never include
    // viewer identities, query parameters, SQL, or dependency exception messages.
    var metadata: Logger.Metadata = [
      "request_id": .string(context.requestId), "route": .string(route),
      "duration_ms": .stringConvertible(milliseconds), "status": .stringConvertible(status),
      "error_code": .string(errorCode ?? "none"),
    ]
    for (key, value) in AppViewFeedRequestTimings.current?.finish() ?? [:] {
      metadata[key] = .stringConvertible(value)
    }
    if status >= 500 {
      context.logger.warning("AppView feed request failed", metadata: metadata)
    } else if milliseconds >= 500 {
      context.logger.info("AppView feed request completed slowly", metadata: metadata)
    }
  }
}
