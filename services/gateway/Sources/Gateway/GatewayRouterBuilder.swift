import AsyncHTTPClient
import Foundation
import GatewayCore
import Hummingbird
import Logging

enum GatewayRouterBuilder {
  static func router(
    config: GatewayServiceConfig,
    httpClient: HTTPClient,
    cache: any CacheStore,
    logger: Logger
  ) -> Router<GatewayRequestContext> {
    let router = Router(context: GatewayRequestContext.self)
    router.add(middleware: GatewayCORSPolicy.middleware(config: config.core))
    router.get("/health") { _, _ in ["status": "ok", "service": "gateway"] }

    OAuthMetadataRoutes(
      oauthPublicOrigin: config.core.oauthPublicOrigin,
      oauthIosMetadataOrigin: config.core.oauthIosMetadataOrigin
    ).register(on: router)

    let authMiddleware = ATProtoAuthMiddleware(
      httpClient: httpClient,
      plcURL: config.core.atprotoPLCURL,
      gatewayClientPolicy: config.core.oauthGateway,
      supplementalJwksJSON: config.core.oauthAccessTokenSupplementalJwksJSON,
      allowDpopBoundStructuralFallback: config.core.gatewayAppViewInternalSecret != nil,
      logger: logger
    )
    let protected = router.group().add(middleware: authMiddleware)

    let prefs = PreferenceSyncService(
      httpClient: httpClient,
      cache: cache,
      plcURL: config.core.atprotoPLCURL,
      logger: logger
    )
    let repo = ATProtoAuthenticatedRepoClient(
      httpClient: httpClient,
      plcURL: config.core.atprotoPLCURL,
      logger: logger
    )
    SyncRoutes(preferenceService: prefs, repo: repo).register(on: protected)
    PublicationWriteRoutes(repo: repo).register(on: protected)

    if let appViewBase = config.appViewBaseURL {
      AppViewProxyRoutes(
        baseURL: appViewBase,
        internalSecret: config.core.gatewayAppViewInternalSecret,
        httpClient: httpClient,
        logger: logger
      ).register(on: protected)
    }

    return router
  }
}
