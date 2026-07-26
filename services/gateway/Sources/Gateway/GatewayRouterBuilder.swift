import AsyncHTTPClient
import Foundation
import GatewayCore
import Hummingbird
import Logging
import OperationsCore

enum GatewayRouterBuilder {
  static func router(
    config: GatewayServiceConfig,
    httpClient: HTTPClient,
    cache: any CacheStore,
    operationsStore: (any OperationsStore)? = nil,
    telemetry: OperationsTelemetryBuffer? = nil,
    telemetryEnvironment: String = "unknown",
    telemetryInstanceId: String = "unknown",
    logger: Logger
  ) -> Router<GatewayRequestContext> {
    let router = Router(context: GatewayRequestContext.self)
    router.add(middleware: RequestTraceMiddleware(service: "gateway", environment: telemetryEnvironment, instanceId: telemetryInstanceId, telemetry: telemetry))
    router.add(middleware: GatewayCORSPolicy.middleware(config: config.core))
    router.get("/health") { _, _ in ["status": "ok", "service": "gateway"] }
    router.get("/livez") { _, _ in ["status": "live", "service": "gateway"] }
    router.get("/readyz") { _, _ async throws -> [String: String] in
      try await operationsStore?.ping()
      return ["status": "ready", "service": "gateway"]
    }
    router.get("/freshness") { _, _ async throws -> ServiceFreshnessResponse in
      try await ServiceFreshnessResponse.evaluate(service: "gateway", store: operationsStore)
    }

    OAuthMetadataRoutes(
      oauthPublicOrigin: config.core.oauthPublicOrigin,
      oauthIosMetadataOrigin: config.core.oauthIosMetadataOrigin,
      oauthOperationsOrigin: config.core.oauthOperationsOrigin
    ).register(on: router)

    let authMiddleware = ATProtoAuthMiddleware(
      httpClient: httpClient,
      plcURL: config.core.atprotoPLCURL,
      gatewayClientPolicy: config.core.oauthGateway,
      supplementalJwksJSON: config.core.oauthAccessTokenSupplementalJwksJSON,
      allowDpopBoundStructuralFallback:
        config.core.gatewayAppViewInternalSecret != nil || config.core.gatewayOperationsInternalSecret != nil,
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

    if let operationsBase = config.operationsBaseURL {
      OperationsProxyRoutes(
        baseURL: operationsBase,
        internalSecret: config.core.gatewayOperationsInternalSecret,
        httpClient: httpClient
      ).register(on: protected)
    }

    if let latrIosProxy = config.latrIosProxy {
      LatrProxyRoutes(
        config: latrIosProxy,
        httpClient: httpClient,
        logger: logger
      ).register(on: protected)
    }

    return router
  }
}
