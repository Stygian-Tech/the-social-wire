import Foundation
import GatewayCore

enum GatewayServiceConfigError: Error, Equatable {
  case missingPDSAttestationReceiptSecret
  case invalidPDSAttestationReceiptSecret
  case invalidWireFeedMode(String)
  case invalidCircleFeedMode(String)
}

/// Gateway-specific configuration (PDS write-through, sync cache, optional AppView read proxy).
struct GatewayServiceConfig: Sendable {
  enum WireFeedMode: String, Sendable {
    case off
    case shadow
    case api
    case visible

    var servesAPI: Bool { self == .api || self == .visible }
  }

  let core: GatewayConfig
  let cacheBackend: CacheBackend
  /// When set, publication/AppView XRPC and their compatibility aliases are proxied to this AppView base URL.
  let appViewBaseURL: String?
  /// Dedicated control-plane origin for `/v1/operations/*`.
  let operationsBaseURL: String?
  /// Projection Pool health origin used by the public readiness aggregation endpoint.
  let projectionPoolBaseURL: String?
  /// When set, `link.latr.bookmarks.*` XRPC is proxied to L@tr using iOS server credentials.
  let latrIosProxy: LatrIosProxyCredentials.Config?
  /// Shared across Gateway replicas so short-lived PDS attestations remain portable.
  let pdsAttestationReceipt: ATProtoSessionAttestationReceipt
  let wireFeedMode: WireFeedMode
  let circleFeedMode: WireFeedMode

  enum CacheBackend: Sendable {
    case sqlite(path: String)
    case postgres(url: String)
  }

  static func fromEnvironment(
    _ env: [String: String] = AppEnvironmentLoader.mergeProcessWithDotenv()
  ) throws -> GatewayServiceConfig {
    let core = GatewayConfig.fromEnvironment(env)
    let receiptSecret = try pdsAttestationReceiptSecret(env: env, appEnv: core.appEnv)
    let pdsAttestationReceipt: ATProtoSessionAttestationReceipt
    do {
      pdsAttestationReceipt = try ATProtoSessionAttestationReceipt(secret: receiptSecret)
    } catch {
      throw GatewayServiceConfigError.invalidPDSAttestationReceiptSecret
    }
    let backend: CacheBackend
    switch core.appEnv {
    case .local:
      backend = .sqlite(path: env["SQLITE_DB_PATH"] ?? "./social-wire.sqlite")
    case .dev, .prod:
      guard let dbURL = env["DATABASE_URL"], !dbURL.isEmpty else {
        fatalError("DATABASE_URL is required for APP_ENV=\(core.appEnv.rawValue)")
      }
      backend = .postgres(url: dbURL)
    }
    let appViewRaw = env["APPVIEW_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let appViewBaseURL = (appViewRaw?.isEmpty == false) ? appViewRaw : nil
    let operationsRaw = env["OPERATIONS_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let operationsBaseURL = (operationsRaw?.isEmpty == false) ? operationsRaw : nil
    let projectionPoolRaw = (
      env["PROJECTION_POOL_BASE_URL"] ?? env["CHARYBDIS_BASE_URL"]
    )?.trimmingCharacters(in: .whitespacesAndNewlines)
    let projectionPoolBaseURL =
      (projectionPoolRaw?.isEmpty == false) ? projectionPoolRaw : nil
    let latrIosProxy = LatrIosProxyCredentials.Config.fromEnvironment(env)
    let rawWireFeedMode = env["WIRE_FEED_MODE"]?.lowercased() ?? WireFeedMode.off.rawValue
    guard let wireFeedMode = WireFeedMode(rawValue: rawWireFeedMode) else {
      throw GatewayServiceConfigError.invalidWireFeedMode(rawWireFeedMode)
    }
    let rawCircleFeedMode = env["CIRCLE_FEED_MODE"]?.lowercased() ?? WireFeedMode.off.rawValue
    guard let circleFeedMode = WireFeedMode(rawValue: rawCircleFeedMode) else {
      throw GatewayServiceConfigError.invalidCircleFeedMode(rawCircleFeedMode)
    }
    return GatewayServiceConfig(
      core: core,
      cacheBackend: backend,
      appViewBaseURL: appViewBaseURL,
      operationsBaseURL: operationsBaseURL,
      projectionPoolBaseURL: projectionPoolBaseURL,
      latrIosProxy: latrIosProxy,
      pdsAttestationReceipt: pdsAttestationReceipt,
      wireFeedMode: wireFeedMode,
      circleFeedMode: circleFeedMode
    )
  }

  private static func pdsAttestationReceiptSecret(
    env: [String: String],
    appEnv: GatewayConfig.AppEnvironment
  ) throws -> String {
    if let value = env["PDS_ATTESTATION_RECEIPT_SECRET"]?
      .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    {
      return value
    }
    guard appEnv == .local else {
      throw GatewayServiceConfigError.missingPDSAttestationReceiptSecret
    }
    return "local-only-pds-attestation-receipt-secret"
  }
}
