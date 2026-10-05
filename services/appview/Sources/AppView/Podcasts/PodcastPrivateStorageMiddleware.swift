import GatewayCore
import Hummingbird
import ThinAppViewCore

struct PodcastPrivateStorageMiddleware: RouterMiddleware {
  typealias Context = GatewayRequestContext
  func handle(_ request: Request, context: Context,
    next: (Request, Context) async throws -> Response) async throws -> Response {
    do { return try await next(request, context) }
    catch PodcastStoreError.privateStorageUnavailable {
      throw HTTPError(.serviceUnavailable, message: "Private Podcast Storage Is Unavailable")
    }
  }
}
