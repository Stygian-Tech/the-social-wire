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

    let rssIngestion = ThinAppViewRssIngestion(
      store: thinAppViewStore,
      httpClient: httpClient,
      config: config.thinAppView,
      logger: logger
    )
    let indexer = ThinAppViewIndexer(
      store: thinAppViewStore,
      config: config.thinAppView,
      logger: logger,
      httpClient: httpClient,
      plcURL: config.core.atprotoPLCURL,
      rssIngestion: rssIngestion
    )
    let repo = ATProtoAuthenticatedRepoClient(
      httpClient: httpClient,
      plcURL: config.core.atprotoPLCURL,
      logger: logger
    )
    let skyreaderIngestionService = ThinAppViewSkyreaderIngestionService(
      repo: repo,
      rssIngestion: rssIngestion,
      logger: logger
    )
    let readService = ThinAppViewReadService(store: thinAppViewStore, logger: logger)
    let enrollService = ThinAppViewEnrollService(
      store: thinAppViewStore,
      indexer: indexer,
      httpClient: httpClient,
      plcURL: config.core.atprotoPLCURL,
      config: config.thinAppView,
      logger: logger,
      skyreaderIngestion: skyreaderIngestionService
    )
    ThinAppViewRoutes(readService: readService, enrollService: enrollService).register(on: protected)

    AppViewExtendedRoutes(
      readService: readService,
      projectionService: projection,
      repo: repo
    ).register(on: protected)

    let bootstrapStream = BootstrapStreamService(
      projectionService: projection,
      readService: readService,
      enrollService: enrollService,
      skyreaderIngestionService: skyreaderIngestionService,
      logger: logger
    )
    BootstrapStreamRoutes(bootstrapStreamService: bootstrapStream).register(on: protected)

    return router
  }
}
