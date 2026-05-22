import AsyncHTTPClient
import Foundation
import GatewayCore
import Hummingbird
import Logging
import ThinAppViewCore

enum AppViewRouterBuilder {
  static func router(
    config: AppViewServiceConfig,
    httpClient: HTTPClient,
    thinAppViewStore: any ThinAppViewStore,
    logger: Logger
  ) -> Router<GatewayRequestContext> {
    let router = Router(context: GatewayRequestContext.self)
    router.get("/health") { _, _ in ["status": "ok", "service": "appview"] }

    let internalTrustMiddleware = GatewayInternalTrustAuthMiddleware(
      sharedSecret: config.core.gatewayAppViewInternalSecret,
      logger: logger
    )
    let authMiddleware = ATProtoAuthMiddleware(
      httpClient: httpClient,
      plcURL: config.core.atprotoPLCURL,
      gatewayClientPolicy: config.core.oauthGateway,
      supplementalJwksJSON: config.core.oauthAccessTokenSupplementalJwksJSON,
      logger: logger
    )
    let protected = router.group()
      .add(middleware: internalTrustMiddleware)
      .add(middleware: authMiddleware)

    guard config.thinAppView.enabled else { return router }

    let projection = PublicationProjectionService(
      httpClient: httpClient,
      plcURL: config.core.atprotoPLCURL,
      logger: logger,
      thinStore: thinAppViewStore
    )
    let resolve = PublicationResolveService(
      httpClient: httpClient,
      plcURL: config.core.atprotoPLCURL,
      logger: logger
    )
    PublicationRoutes(projectionService: projection, resolveService: resolve).register(on: protected)

    let indexer = ThinAppViewIndexer(store: thinAppViewStore, config: config.thinAppView, logger: logger)
    let readService = ThinAppViewReadService(store: thinAppViewStore, logger: logger)
    let enrollService = ThinAppViewEnrollService(
      store: thinAppViewStore,
      indexer: indexer,
      httpClient: httpClient,
      plcURL: config.core.atprotoPLCURL,
      config: config.thinAppView,
      logger: logger
    )
    ThinAppViewRoutes(readService: readService, enrollService: enrollService).register(on: protected)

    let repo = ATProtoAuthenticatedRepoClient(
      httpClient: httpClient,
      plcURL: config.core.atprotoPLCURL,
      logger: logger
    )
    AppViewExtendedRoutes(
      readService: readService,
      projectionService: projection,
      repo: repo
    ).register(on: protected)

    return router
  }
}
