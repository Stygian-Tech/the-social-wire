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
    cache: any PdsRepoRecordCacheStore,
    wireLimiter: WireRequestLimiter = WireRequestLimiter(),
    ingestionHealth: GatewayIngestionHealth? = nil,
    operationsStore: (any OperationsStore)? = nil,
    telemetry: OperationsTelemetryBuffer? = nil,
    telemetryEnvironment: String = "unknown",
    telemetryInstanceId: String = "unknown",
    logger: Logger
  ) -> Router<GatewayRequestContext> {
    let router = Router(context: GatewayRequestContext.self)
    router.add(
      middleware: RequestTraceMiddleware(
        service: "gateway", environment: telemetryEnvironment, instanceId: telemetryInstanceId,
        telemetry: telemetry))
    router.add(middleware: GatewayCORSPolicy.middleware(config: config.core))
    router.get("/health") { _, _ in ["status": "ok", "service": "gateway"] }
    router.get("/livez") { _, _ in ["status": "live", "service": "gateway"] }
    router.get("/readyz") { _, _ async throws -> [String: String] in
      do {
        try await GatewayReadinessProbe(
          operationsStore: operationsStore,
          appViewBaseURL: config.appViewBaseURL,
          httpClient: httpClient,
          recordFailure: { dependency in
            logger.error(
              "Gateway readiness required dependency failed",
              metadata: ["dependency": .string(dependency.rawValue)]
            )
          }
        ).run()
      } catch {
        try Task.checkCancellation()
        if error is CancellationError { throw error }
        throw HTTPError(.serviceUnavailable, message: "Gateway serving dependency unavailable")
      }
      let ingestion = await ingestionHealth?.snapshot() ?? .unknown
      return ingestion.dependencyState.merging(["status": "ready", "service": "gateway"]) { _, new in new }
    }
    router.get("/freshness") { _, _ async -> GatewayIngestionHealthSnapshot in
      await ingestionHealth?.snapshot() ?? .unknown
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
      attestationReceipt: config.pdsAttestationReceipt,
      supplementalJwksJSON: config.core.oauthAccessTokenSupplementalJwksJSON,
      logger: logger
    )
    let protected = router.group()
      .add(middleware: XRPCErrorMiddleware())
      .add(middleware: authMiddleware)
    let optionalAuthentication = router.group()
      .add(middleware: XRPCErrorMiddleware())
      .add(middleware: OptionalATProtoAuthMiddleware(strict: authMiddleware))

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
    ClientPerformanceTelemetryRoutes(
      telemetry: telemetry,
      environment: telemetryEnvironment
    ).register(on: protected)

    if let appViewBase = config.appViewBaseURL {
      AppViewProxyRoutes(
        baseURL: appViewBase,
        internalSecret: config.core.gatewayAppViewInternalSecret,
        httpClient: httpClient,
        logger: logger
      ).register(on: protected)
      if config.wireFeedMode.servesAPI {
        WireProxyRoutes(
          baseURL: appViewBase,
          internalSecret: config.core.gatewayAppViewInternalSecret,
          httpClient: httpClient,
          limiter: wireLimiter,
          logger: logger
        ).register(on: optionalAuthentication)
      }
      if config.circleFeedMode.servesAPI {
        CircleProxyRoutes(
          baseURL: appViewBase,
          internalSecret: config.core.gatewayAppViewInternalSecret,
          httpClient: httpClient,
          limiter: wireLimiter,
          logger: logger
        ).register(on: protected)
      }
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
