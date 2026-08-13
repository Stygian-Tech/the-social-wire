import AsyncHTTPClient
import Foundation
import GatewayCore
import Hummingbird
import Logging
import OperationsCore

enum OperationsRouterBuilder {
  static func router(
    config: OperationsServiceConfig,
    httpClient: HTTPClient,
    store: any OperationsStore,
    telemetry: OperationsTelemetryBuffer?,
    logger: Logger
  ) -> Router<GatewayRequestContext> {
    let router = Router(context: GatewayRequestContext.self)
    router.add(middleware: RequestTraceMiddleware(service: "operations", environment: config.operations.environment, instanceId: config.operations.instanceId, telemetry: telemetry))
    router.get("/health") { _, _ in ["status": "ok", "service": "operations"] }
    router.get("/livez") { _, _ in ["status": "live", "service": "operations"] }
    router.get("/readyz") { _, _ async throws -> [String: String] in
      try await store.ping()
      return ["status": "ready", "service": "operations"]
    }
    router.get("/freshness") { _, _ async throws -> FreshnessResponse in
      FreshnessResponse(state: try await store.fetchStreamState(source: "jetstream"), checkedAt: Date())
    }

    let internalTrust = GatewayInternalTrustAuthMiddleware(
      sharedSecret: config.gatewayOperationsInternalSecret,
      logger: logger
    )
    let auth = ATProtoAuthMiddleware(
      httpClient: httpClient,
      plcURL: config.core.atprotoPLCURL,
      gatewayClientPolicy: config.core.oauthGateway,
      supplementalJwksJSON: config.core.oauthAccessTokenSupplementalJwksJSON,
      logger: logger
    )
    let protected = router.group()
      .add(middleware: OperationsXRPCErrorMiddleware())
      .add(middleware: internalTrust)
      .add(middleware: auth)
      .add(middleware: OperatorAuthorizationMiddleware(allowedDids: config.operations.operatorDids))
    OperationsRoutes(store: store, config: config.operations).register(on: protected)
    return router
  }
}

struct FreshnessResponse: Codable, Sendable, ResponseEncodable {
  let state: IngestionStreamState?
  let checkedAt: Date
}
