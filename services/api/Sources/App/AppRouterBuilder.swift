import AsyncHTTPClient
import Foundation
import Hummingbird
import Logging

enum AppRouterBuilder {
  /// Builds the HTTP router wired like production (`App.swift`).
  ///
  /// - Parameter cache: Local SQLite (`APP_ENV=local`) or Postgres (`APP_ENV!=local`) cache implementation.
  static func router(
    config: AppConfig,
    httpClient: HTTPClient,
    cache: any CacheStore,
    logger: Logger,
    thinAppViewStore: (any ThinAppViewStore)? = nil
  ) -> Router<AppRequestContext> {
    let router = Router(context: AppRequestContext.self)
    router.get("/health") { _, _ in ["status": "ok"] }
    OAuthMetadataRoutes(
      oauthPublicOrigin: config.oauthPublicOrigin,
      oauthIosMetadataOrigin: config.oauthIosMetadataOrigin
    ).register(on: router)

    let authMiddleware = ATProtoAuthMiddleware(
      httpClient: httpClient,
      plcURL: config.atprotoPLCURL,
      gatewayClientPolicy: config.oauthGateway,
      logger: logger
    )
    let protected = router.group().add(middleware: authMiddleware)

    Self.mountSyncAndOptionalLegacy(
      for: cache,
      config: config,
      httpClient: httpClient,
      logger: logger,
      onto: protected,
      thinAppViewStore: thinAppViewStore
    )

    return router
  }

  private static func mountSyncAndOptionalLegacy(
    for cache: any CacheStore,
    config: AppConfig,
    httpClient: HTTPClient,
    logger: Logger,
    onto protected: RouterGroup<AppRequestContext>,
    thinAppViewStore: (any ThinAppViewStore)?
  ) {
    let prefs = PreferenceSyncService(httpClient: httpClient, cache: cache, plcURL: config.atprotoPLCURL, logger: logger)
    SyncRoutes(preferenceService: prefs).register(on: protected)

    if let thinAppViewStore, config.thinAppView.enabled {
      let thinConfig = config.thinAppView
      let indexer = ThinAppViewIndexer(store: thinAppViewStore, config: thinConfig, logger: logger)
      let readService = ThinAppViewReadService(store: thinAppViewStore, logger: logger)
      let enrollService = ThinAppViewEnrollService(
        store: thinAppViewStore,
        indexer: indexer,
        httpClient: httpClient,
        plcURL: config.atprotoPLCURL,
        config: thinConfig,
        logger: logger
      )
      ThinAppViewRoutes(readService: readService, enrollService: enrollService).register(on: protected)
    }

    guard config.enableLegacyContentAPI else { return }

    let discoveryService = DiscoveryService(
      httpClient: httpClient,
      cache: cache,
      plcURL: config.atprotoPLCURL,
      logger: logger
    )
    let contentService = ContentService(httpClient: httpClient, cache: cache, logger: logger, plcURL: config.atprotoPLCURL)

    DiscoveryRoutes(discoveryService: discoveryService).register(on: protected)
    ContentRoutes(contentService: contentService).register(on: protected)
  }
}
