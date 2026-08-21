import Foundation
import Logging
import SocialWireRedis

enum GatewayPdsCacheBackend: String {
  case sqlite
  case postgres
  case redis

  static func selected(
    from environment: [String: String],
    default fallback: GatewayPdsCacheBackend
  ) throws -> GatewayPdsCacheBackend {
    guard let raw = environment["GATEWAY_PDS_CACHE_BACKEND"]?.lowercased(), !raw.isEmpty else {
      return fallback
    }
    guard let backend = GatewayPdsCacheBackend(rawValue: raw) else {
      throw GatewayPdsCacheBackendError.unsupported(raw)
    }
    return backend
  }
}

enum GatewayPdsCacheBackendError: Error {
  case unsupported(String)
}

struct RedisPdsRepoRecordCacheRuntime: Sendable {
  let store: any PdsRepoRecordCacheStore
  let resolutionCache: any PDSResolutionCache
  let client: any RedisCommandClient

  static func make(
    environment: [String: String],
    appEnvironment: String,
    logger: Logger,
    telemetry: RedisTelemetrySink?
  ) -> RedisPdsRepoRecordCacheRuntime? {
    guard let url = environment["REDIS_URL"], !url.isEmpty else {
      logger.error("Redis PDS cache selected without REDIS_URL; continuing without cache")
      return nil
    }
    do {
      let configuration = try RedisConfiguration(
        url: url,
        minimumConnectionCount: positiveInt(environment["REDIS_POOL_MIN"], fallback: 1),
        maximumConnectionCount: positiveInt(environment["REDIS_POOL_MAX"], fallback: 8),
        commandTimeoutMilliseconds: positiveInt(
          environment["REDIS_COMMAND_TIMEOUT_MILLISECONDS"],
          fallback: 250
        )
      )
      let client = try RediStackRedisClient(
        configuration: configuration,
        logger: logger,
        telemetry: telemetry
      )
      return RedisPdsRepoRecordCacheRuntime(
        store: RedisPdsRepoRecordCacheStore(
          commands: client,
          environment: appEnvironment,
          logger: logger,
          telemetry: telemetry
        ),
        resolutionCache: RedisPDSResolutionCache(
          commands: client,
          environment: appEnvironment,
          telemetry: telemetry
        ),
        client: client
      )
    } catch {
      logger.error("Redis PDS cache initialization failed; continuing without cache", metadata: [
        "error_category": .string("configuration_or_connection")
      ])
      return nil
    }
  }

  func shutdown() async {
    await PDSResolutionCacheRegistry.shared.install(nil)
    try? await client.shutdown()
  }

  func installResolutionCache() async {
    await PDSResolutionCacheRegistry.shared.install(resolutionCache)
  }

  private static func positiveInt(_ raw: String?, fallback: Int) -> Int {
    guard let raw, let value = Int(raw), value > 0 else { return fallback }
    return value
  }
}
