import GatewayCore
import Hummingbird
import ThinAppViewCore

/// Runs after authentication and before cached bootstrap/feed responses begin.
struct PDSReadStateReadinessMiddleware: RouterMiddleware {
  typealias Context = GatewayRequestContext
  let store: (any PDSReadStateLifecycleStoring)?
  let recovery: PDSReadStateRecoveryCoordinator?

  func handle(_ request: Request, context: GatewayRequestContext,
    next: (Request, GatewayRequestContext) async throws -> Response
  ) async throws -> Response {
    // Status exposes readiness while scheduling recovery; confirmation waits
    // behind the same global rebuild limit for an evicted projection.
    let ungated: Set<String> = [
      "/xrpc/app.thesocialwire.appview.exportReadState",
    ]
    let path = request.uri.path
    let readsProjection = path.hasPrefix("/v1/appview/") || path.hasPrefix("/xrpc/app.thesocialwire.appview.")
      || ["/v1/publications/sidebar", "/v1/publications/refresh",
          "/xrpc/app.thesocialwire.publication.getSidebar",
          "/xrpc/app.thesocialwire.publication.refreshSidebar"].contains(path)
    if readsProjection, let viewer = context.authContext?.did, !ungated.contains(path) {
      do {
        if let recovery { try await recovery.requireReady(viewerDid: viewer) }
        else if let store {
          try await store.touchPDSReadStateAccess(viewerDid: viewer, at: .now)
          if try await !store.pdsReadStateStatus(viewerDid: viewer).projectionReady {
            throw PDSReadStateStorageError.projectionNotReady
          }
        }
      }
      catch {
        if path == "/xrpc/app.thesocialwire.appview.getReadStateStatus" {
          return try await next(request, context)
        }
        return try AppViewFeedError(status: .serviceUnavailable, code: "ReadStateNotReady",
          message: "Read state is syncing. Please retry shortly.", requestId: context.requestId,
          retryable: true).response(from: request, context: context)
      }
    }
    return try await next(request, context)
  }
}
